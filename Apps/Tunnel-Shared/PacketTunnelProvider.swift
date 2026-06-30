// PacketTunnelProvider —— iOS + macOS 公用。
//
// 流程（NetworkExtension 子进程内）：
// 1. NEPacketTunnelProvider.startTunnel(options:) 被系统调起
// 2. 从 protocolConfiguration.providerConfiguration 读出主 App 写好的 xrayJSON
//    （不走 App Group —— 避免 macOS 隐私弹窗）
// 3. 调 setTunnelNetworkSettings 让系统配置 TUN 接口（IP / DNS / 路由）
// 4. 建一对 socketpair(AF_UNIX, SOCK_DGRAM)，一端给 libXray 当 TUN fd。
//    iOS ≤ 25 上历史方案是 KVC 读 `packetFlow.socket.fileDescriptor` 拿真 utun fd；
//    iOS 26 上 Apple 改了底层：`_socket` ivar 永远不被 populate（实测调了 readPackets 也是 nil），
//    真实 packet 流走 `_interface: NEVirtualInterface_s` 这个不透明 C 结构。
//    所以放弃 KVC，改成 socketpair shim —— Swift 当 packetFlow 和 libXray 之间的搬运工。
// 5. Swift 端起两个方向的拷贝循环：
//    - packetFlow.readPackets → 4 字节大端 protocol + IP packet → write(swiftFd)
//    - read(swiftFd) → 拆 4 字节头 → packetFlow.writePackets
// 6. XrayCore.run() 启动 xray-core，它在 socketpair 另一端读写，跟操作 utun 一样
//
// xray 用的 geoip.dat / geosite.dat 打包在 Extension bundle 的 Resources 里，
// 不需要从 AppGroup 读 —— 一次部署，路由数据库自带。

import Darwin
import NetworkExtension
import os.log
import VPNCore
import XrayConfig
import XrayCore

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.sbraveyoung.vpn.tunnel", category: "PacketTunnel")

    /// (Swift 持的一端, libXray 持的一端)。stopTunnel 时只 close swift 端；
    /// xray 端由 XrayCore.stop() 内部 close。
    private var tunPair: (swift: Int32, xray: Int32)?
    private let bridgeQueue = DispatchQueue(label: "com.sbraveyoung.vpn.tunnel.bridge", qos: .userInitiated)

    /// 控制两个方向拷贝循环是否继续。stopTunnel 时设 false。读写竞争一两个 packet 无所谓。
    private var bridgeActive = false

    /// 调试：两个方向各打第一个 packet 的 log，方便确认流量真的在流。
    private var loggedFirstApplePacket = false
    private var loggedFirstXrayPacket = false

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        os_log("startTunnel begin", log: log, type: .default)

        // 1) 从 providerConfiguration 读启动信息
        //    新路径：nodeJSON → 纯 Swift NodeConverter（XrayConfig 模块）→ xray outbounds
        //    fallback：shareLink → libXray.ConvertShareLinksToXrayJson
        //    fallback 留着是为了万一 NodeConverter 有覆盖不到的字段映射，至少能切回原路径，
        //    稳定一段时间后会移除 libXray.convertShareLinks 调用。
        let providerConfig = (self.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let nodeJSON = providerConfig?["nodeJSON"] as? String ?? ""
        let shareLink = providerConfig?["shareLink"] as? String ?? ""
        guard !nodeJSON.isEmpty || !shareLink.isEmpty else {
            let err = NSError(
                domain: "com.sbraveyoung.vpn.tunnel",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey:
                    "providerConfiguration 里既没有 nodeJSON 也没有 shareLink。主 App 需要先用 VPNTunnelManager.configure(...) 保存配置。"]
            )
            os_log("missing nodeJSON/shareLink in providerConfiguration", log: log, type: .error)
            completionHandler(err)
            return
        }
        let nodeName = (providerConfig?["nodeName"] as? String) ?? "node"
        let modeRaw = (providerConfig?["proxyMode"] as? String) ?? ProxyMode.global.rawValue
        let mode = ProxyMode(rawValue: modeRaw) ?? .global

        // 本地代理端口：仅 macOS 会塞这两个值（iOS 用不上 loopback 代理 + 省内存）。
        // 关键：逐个探端口占用，被占的跳过 —— 附属的本地代理绝不能拖垮 TUN 主通道。
        // Extension 有 network.server entitlement，所以这里 bind 探测是有效的（主 App 沙箱里则不行）。
        var localHTTP: Int?
        var localSOCKS: Int?
        if let http = (providerConfig?["localProxyHttpPort"] as? NSNumber)?.intValue {
            if Self.portIsBindable(http) {
                localHTTP = http
            } else {
                os_log("⚠️ 本地 HTTP 端口 %d 被占用，跳过该 inbound（TUN 不受影响）",
                       log: log, type: .error, http)
            }
        }
        if let socks = (providerConfig?["localProxySocksPort"] as? NSNumber)?.intValue {
            if Self.portIsBindable(socks) {
                localSOCKS = socks
            } else {
                os_log("⚠️ 本地 SOCKS 端口 %d 被占用，跳过该 inbound（TUN 不受影响）",
                       log: log, type: .error, socks)
            }
        }
        os_log("local proxy inbounds: http=%{public}@ socks=%{public}@",
               log: log, type: .default,
               localHTTP.map(String.init) ?? "skip",
               localSOCKS.map(String.init) ?? "skip")

        os_log("starting tunnel for node: %{public}@ mode=%{public}@",
               log: log, type: .default, nodeName, mode.rawValue)

        // 转换 Node → outbounds JSON
        let xrayJSON: String
        do {
            let outboundsJSON = try resolveOutboundsJSON(nodeJSON: nodeJSON, shareLink: shareLink)
            xrayJSON = try XrayConfigComposer.compose(
                outboundsJSON: outboundsJSON, mode: mode,
                localHTTPPort: localHTTP, localSOCKSPort: localSOCKS)
        } catch {
            os_log("share link → xray config 转换失败: %{public}@",
                   log: log, type: .error, error.localizedDescription)
            completionHandler(error)
            return
        }

        // 2) 设置 TUN 网络参数
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.0.10.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        let dns = NEDNSSettings(servers: ["8.8.8.8", "1.1.1.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = NSNumber(value: 1500)

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                os_log("setTunnelNetworkSettings failed: %{public}@", log: self.log, type: .error, error.localizedDescription)
                completionHandler(error)
                return
            }
            self.bringUpXray(configJSON: xrayJSON, completionHandler: completionHandler)
        }
    }

    private func bringUpXray(configJSON: String, completionHandler: @escaping (Error?) -> Void) {
        os_log("bringUpXray: config bytes=%d", log: log, type: .default, configJSON.utf8.count)

        // 3) 建 socketpair —— xray 端当 TUN fd 给 libXray
        guard let pair = makeSocketPair() else {
            let err = NSError(
                domain: "com.sbraveyoung.vpn.tunnel",
                code: 1003,
                userInfo: [NSLocalizedDescriptionKey: "socketpair() 失败：errno=\(errno)"]
            )
            os_log("socketpair failed: errno=%d", log: log, type: .error, errno)
            completionHandler(err)
            return
        }
        self.tunPair = pair
        os_log("socketpair ready: swift_fd=%d xray_fd=%d", log: log, type: .default, pair.swift, pair.xray)

        // 4) 起两个方向的拷贝循环（在 xray-core 启动前就 arm 好，免得初始 packet 丢）
        self.bridgeActive = true
        self.loggedFirstApplePacket = false
        self.loggedFirstXrayPacket = false
        self.startReadPacketsToFd(swiftFd: pair.swift)
        self.bridgeQueue.async { [weak self] in
            self?.runFdToWritePacketsLoop(swiftFd: pair.swift)
        }

        // 5) 准备 xray 工作路径
        let geoDir = Bundle.main.resourceURL?.path ?? NSTemporaryDirectory()
        let cachesURL = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let mphCache = cachesURL.appendingPathComponent("xray-mph.cache").path

        let fm = FileManager.default
        let geoipPath = geoDir + "/geoip.dat"
        let geositePath = geoDir + "/geosite.dat"
        let hasGeoip = fm.fileExists(atPath: geoipPath)
        let hasGeosite = fm.fileExists(atPath: geositePath)
        os_log("geoDir=%{public}@ geoip=%{public}@ geosite=%{public}@",
               log: log, type: .default,
               geoDir,
               hasGeoip ? "OK" : "MISSING",
               hasGeosite ? "OK" : "MISSING")
        if !hasGeoip || !hasGeosite {
            os_log("WARNING: geo files missing — rule mode 会失败，global mode 应当还能跑（已不依赖 geoip）", log: log, type: .error)
        }

        // 6) 启动 xray-core，给 socketpair 的另一端当 TUN fd
        os_log("calling XrayCore.setTunFd + run …", log: log, type: .default)
        XrayCore.setTunFd(pair.xray)
        do {
            try XrayCore.run(configJSON: configJSON, geoDir: geoDir, mphCachePath: mphCache)
            os_log("✅ xray-core started OK (version %{public}@)", log: log, type: .default, XrayCore.version)
            completionHandler(nil)
        } catch {
            os_log("❌ XrayCore.run failed: %{public}@", log: log, type: .error, error.localizedDescription)
            let dumpURL = cachesURL.appendingPathComponent("xray-config-dump.json")
            try? configJSON.write(to: dumpURL, atomically: true, encoding: .utf8)
            os_log("dumped failing config to %{public}@", log: log, type: .default, dumpURL.path)
            self.tearDownBridge()
            completionHandler(Self.friendlyError(from: error))
        }
    }

    /// 探测一个本地端口能否绑定（Extension 有 network.server，bind 在这里是有效的）。
    /// 用 bind() 测试：能绑上=空闲（随即 close 释放），EADDRINUSE=被占。
    /// 加 SO_REUSEADDR=0 的语义靠默认，确保探测真实占用。
    private static func portIsBindable(_ port: Int, host: String = "127.0.0.1") -> Bool {
        guard (1...65535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        let r = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }

    /// 把 xray-core 的底层错误翻译成用户能看懂的提示。
    /// 端口被占用时 xray 报 "address already in use" —— 这是本地 SOCKS/HTTP 代理端口冲突，
    /// 给出明确的"哪个程序占了、去哪改端口"指引，而不是把 Go 的原始错误甩给用户。
    private static func friendlyError(from error: Error) -> Error {
        let msg = error.localizedDescription.lowercased()
        if msg.contains("address already in use") || msg.contains("bind:") || msg.contains("eaddrinuse") {
            return NSError(
                domain: "com.sbraveyoung.vpn.tunnel",
                code: 1005,
                userInfo: [NSLocalizedDescriptionKey:
                    "本地代理端口已被其它程序占用（多半是另一个 VPN / 代理软件，如 Clash / Surge）。"
                    + "请在「设置 → 端口」里把 HTTP / SOCKS 端口改成没被占用的值，或退出占用端口的程序后重试。"]
            )
        }
        return error
    }

    // MARK: - Node → xray outbounds JSON 双路径

    /// 优先走纯 Swift `NodeConverter`，失败时（解码 / 转换出错或本来就没 nodeJSON）退回 libXray。
    /// 当前是 S3 Phase 2 的过渡期 —— 稳定一段时间后会移除 libXray 那条路径。
    private func resolveOutboundsJSON(nodeJSON: String, shareLink: String) throws -> String {
        // Path A: Swift NodeConverter
        if !nodeJSON.isEmpty,
           let data = nodeJSON.data(using: .utf8) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let node = try decoder.decode(Node.self, from: data)
                let result = try NodeConverter.toOutboundsJSON(node)
                os_log("✅ outbounds via Swift NodeConverter (protocol=%{public}@)",
                       log: log, type: .default, node.protocolType.rawValue)
                return result
            } catch {
                os_log("⚠️ NodeConverter 失败 (%{public}@)，退回 libXray.convertShareLinks",
                       log: log, type: .error, error.localizedDescription)
                // fall through
            }
        }
        // Path B: libXray.convertShareLinks
        if !shareLink.isEmpty {
            let result = try XrayCore.convertShareLinks(shareLink)
            os_log("✅ outbounds via libXray.convertShareLinks (fallback)",
                   log: log, type: .default)
            return result
        }
        throw NSError(
            domain: "com.sbraveyoung.vpn.tunnel",
            code: 1004,
            userInfo: [NSLocalizedDescriptionKey:
                "两条路径都失败：nodeJSON 解析失败且 shareLink 为空"]
        )
    }

    // MARK: - socketpair TUN bridge (iOS 26 必备)

    /// 建一对 AF_UNIX SOCK_DGRAM socket fd。SOCK_DGRAM 保消息边界 —— 每次 write 一个 packet，
    /// 对端每次 read 拿到完整一个 packet，不用自己做 length-prefix 之类的 framing。
    private func makeSocketPair() -> (swift: Int32, xray: Int32)? {
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
    private func startReadPacketsToFd(swiftFd: Int32) {
        self.packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            for i in 0..<packets.count {
                let proto = UInt32(truncating: protocols[i])
                var frame = Data(capacity: 4 + packets[i].count)
                var protoBE = proto.bigEndian
                withUnsafeBytes(of: &protoBE) { frame.append(contentsOf: $0) }
                frame.append(packets[i])
                _ = frame.withUnsafeBytes { ptr -> Int in
                    write(swiftFd, ptr.baseAddress, ptr.count)
                }
            }
            if !self.loggedFirstApplePacket && !packets.isEmpty {
                self.loggedFirstApplePacket = true
                os_log("✅ first Apple→Xray batch: %d packets, first %d bytes, proto=%d",
                       log: self.log, type: .default,
                       packets.count, packets[0].count, Int(truncating: protocols[0]))
            }
            if self.bridgeActive {
                self.startReadPacketsToFd(swiftFd: swiftFd)
            }
        }
    }

    /// swiftFd → packetFlow 方向。在 bridgeQueue 上跑阻塞 read 循环，
    /// 把 xray 写来的 utun 帧（4 字节大端 protocol + IP packet）拆开后调 writePackets。
    private func runFdToWritePacketsLoop(swiftFd: Int32) {
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
            let proto: UInt32 =
                (UInt32(buf[0]) << 24) |
                (UInt32(buf[1]) << 16) |
                (UInt32(buf[2]) << 8) |
                 UInt32(buf[3])
            let packet = Data(buf[4..<Int(n)])

            if !loggedFirstXrayPacket {
                loggedFirstXrayPacket = true
                os_log("✅ first Xray→Apple packet: total=%d proto=%d ip_first_byte=0x%02x",
                       log: log, type: .default,
                       Int32(n), proto, buf[4])
            }

            self.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: proto)])
        }
    }

    private func tearDownBridge() {
        bridgeActive = false
        if let pair = tunPair {
            close(pair.swift)
            // xray 端由 XrayCore.stop() 关，避免双 close
            tunPair = nil
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("stopTunnel reason=%d", log: log, type: .default, reason.rawValue)
        _ = XrayCore.stop()
        tearDownBridge()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // S7 才用：主 App 通过 sendProviderMessage 拉连接列表 / 流量统计。
        completionHandler?(nil)
    }

    override func sleep(completionHandler: @escaping () -> Void) { completionHandler() }
    override func wake() { }
}
