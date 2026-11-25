import Darwin
import Foundation
import os.log

extension PacketTunnelProvider {
    // MARK: - socketpair TUN bridge (iOS 26 必备)

    /// 建一对 AF_UNIX SOCK_DGRAM socket fd。SOCK_DGRAM 保消息边界 —— 每次 write 一个 packet，
    /// 对端每次 read 拿到完整一个 packet，不用自己做 length-prefix 之类的 framing。
    func makeSocketPair() -> (swift: Int32, xray: Int32)? {
        var fds: [Int32] = [-1, -1]
        let r = fds.withUnsafeMutableBufferPointer { bp -> Int32 in
            socketpair(AF_UNIX, SOCK_DGRAM, 0, bp.baseAddress)
        }
        guard r == 0 else { return nil }

        // 默认 socketpair buffer 比较小（几 KB），跑流量时容易 drop。设到 256 KB 给点余量，
        // 又不至于在 NE 50 MB 内存限制下吃太多。
        var size: Int32 = 256 * 1024
        let sz = socklen_t(MemoryLayout<Int32>.size)
        for fd in fds {
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sz)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sz)
        }
        return (swift: fds[0], xray: fds[1])
    }

    /// packetFlow → swiftFd 方向。Apple 的 readPackets handler 每次给一批 packet：
    /// 加 4 字节大端 protocol family 头（utun 格式），write 到 swift 端，handler 末尾重新 arm。
    func startReadPacketsToFd(swiftFd: Int32) {
        self.packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            var batchUp = 0
            for i in 0..<packets.count {
                let proto = UInt32(truncating: protocols[i])
                var frame = Data(capacity: 4 + packets[i].count)
                var protoBE = proto.bigEndian
                withUnsafeBytes(of: &protoBE) { frame.append(contentsOf: $0) }
                frame.append(packets[i])
                _ = frame.withUnsafeBytes { ptr -> Int in
                    write(swiftFd, ptr.baseAddress, ptr.count)
                }
                batchUp += packets[i].count
            }
            let total = Int64(batchUp)   // 固化成 let，withLock 闭包不能捕获可变的 batchUp
            self.byteCounters.withLock { $0.up += total }
            if !self.loggedFirstApplePacket && !packets.isEmpty {
                self.loggedFirstApplePacket = true
                os_log("✅ first Apple→Xray batch: %d packets, first %d bytes, proto=%d",
                       log: self.log, type: .default,
                       packets.count, packets[0].count, Int(truncating: protocols[0]))
            }
            // 仅当仍是**当前**那对 socketpair 时才重挂 —— 原地重配换了新 fd 后，
            // 上一代 readPackets 的残留回调不会误挂到旧 fd（否则会出现两条 readPackets 链）。
            if self.bridgeActive, self.tunPair?.swift == swiftFd {
                self.startReadPacketsToFd(swiftFd: swiftFd)
            }
        }
    }

    /// swiftFd → packetFlow 方向。在 bridgeQueue 上跑阻塞 read 循环，
    /// 把 xray 写来的 utun 帧（4 字节大端 protocol + IP packet）拆开后调 writePackets。
    func runFdToWritePacketsLoop(swiftFd: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while self.bridgeActive {
            let n = buf.withUnsafeMutableBufferPointer { bp -> Int in
                read(swiftFd, bp.baseAddress, bp.count)
            }
            if n <= 0 {
                os_log("Xray→Apple loop exit: read=%d errno=%d",
                       log: log, type: .default, Int32(n), errno)
                break
            }
            if n < 5 {
                continue
            }
            // ⚠️ 必须显式 autoreleasepool：本循环在 GCD 队列上永不返回，队列只在
            // block 结束时才 drain 池 —— writePackets 每个包桥接出的 NSData/NSNumber
            // 会全部滞留（实测 macOS 扩展 footprint 堆到 ≈ 会话总流量；iOS 同源代码
            // 会顶穿 NE 50MB jetsam 线）。NE 长驻循环里凡碰 ObjC 桥接 API
            //（packetFlow 读写）都要套这一层。
            autoreleasepool {
                let proto: UInt32 =
                    (UInt32(buf[0]) << 24) |
                    (UInt32(buf[1]) << 16) |
                    (UInt32(buf[2]) << 8) |
                     UInt32(buf[3])
                let packet = Data(buf[4..<Int(n)])
                self.byteCounters.withLock { $0.down += Int64(n - 4) }
                self.captureFakeDNS(packet)

                if !loggedFirstXrayPacket {
                    loggedFirstXrayPacket = true
                    os_log("✅ first Xray→Apple packet: total=%d proto=%d ip_first_byte=0x%02x",
                           log: log, type: .default,
                           Int32(n), proto, buf[4])
                }

                self.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: proto)])
            }
        }
    }

    func tearDownBridge() {
        bridgeActive = false
        statsTimer?.cancel()
        statsTimer = nil
        if let pair = tunPair {
            close(pair.swift)
            // xray 端由 XrayCore.stop() 关，避免双 close
            tunPair = nil
        }
    }
}
