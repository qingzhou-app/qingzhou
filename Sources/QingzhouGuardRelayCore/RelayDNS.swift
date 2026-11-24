import Foundation
import Network
import Darwin

/// 绕开 TUN 的直连 DNS 解析器（UDP A 查询，绑定物理网卡）。
///
/// 安全与并发加固：
/// - 阻塞 `recv()` 在独立 `dnsQueue` 上执行，结束后切回调用方指定的 `callbackQueue`；
/// - 使用 `connect()` 绑定对端 IP/端口的 UDP socket，由内核过滤来源；
/// - 严格校验 TXID、QR 标志位、RCODE 与 DNS label 长度 (`<= 63`)；
/// - 有界缓存：先清理过期条目，超出 `maxEntries` 时淘汰最早条目。
public final class RelayDNS: @unchecked Sendable {
    public struct Server: Sendable, Equatable {
        public let host: String
        public let port: UInt16

        public init(host: String, port: UInt16 = 53) {
            self.host = host
            self.port = port
        }
    }

    public static let defaultServers: [Server] = [
        Server(host: "223.5.5.5", port: 53),
        Server(host: "119.29.29.29", port: 53)
    ]

    private let servers: [Server]
    private let ttl: TimeInterval
    private let maxEntries: Int
    private let timeoutSeconds: Int
    private let nowProvider: @Sendable () -> Date

    private let cacheLock = NSLock()
    private var cache: [String: (ip: String, at: Date)] = [:]
    private let dnsQueue = DispatchQueue(label: "com.sbraveyoung.qingzhou.relay.dns", attributes: .concurrent)

    public init(
        servers: [Server] = RelayDNS.defaultServers,
        ttl: TimeInterval = 60,
        maxEntries: Int = 1024,
        timeoutSeconds: Int = 3,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.servers = servers
        self.ttl = max(0, ttl)
        self.maxEntries = max(1, maxEntries)
        self.timeoutSeconds = max(1, timeoutSeconds)
        self.nowProvider = nowProvider
    }

    /// 是域名（不是 IPv4/IPv6 字面量）就返回 true。
    public static func isName(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) != 1 && inet_pton(AF_INET6, host, &v6) != 1
    }

    public static func buildQuery(host: String, id: UInt16) -> Data? {
        var normalized = host
        if normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        guard !normalized.isEmpty else { return nil }

        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return nil }

        var qname = Data()
        for label in labels {
            let utf8 = Array(label.utf8)
            guard !utf8.isEmpty, utf8.count <= 63 else { return nil }
            qname.append(UInt8(utf8.count))
            qname.append(contentsOf: utf8)
        }
        qname.append(0)
        // RFC 1035: QNAME total wire length <= 255
        guard qname.count <= 255 else { return nil }

        var q = Data()
        q.append(contentsOf: [
            UInt8(id >> 8), UInt8(id & 0xFF),
            0x01, 0x00, // RD=1
            0x00, 0x01, // QDCOUNT=1
            0x00, 0x00, // ANCOUNT=0
            0x00, 0x00, // NSCOUNT=0
            0x00, 0x00  // ARCOUNT=0
        ])
        q.append(qname)
        q.append(contentsOf: [0x00, 0x01, 0x00, 0x01]) // QTYPE=A, QCLASS=IN
        return q
    }

    public static func parseResponse(_ data: Data, expectedID: UInt16) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count > 12 else { return nil }

        // 校验 Transaction ID
        guard bytes[0] == UInt8(expectedID >> 8),
              bytes[1] == UInt8(expectedID & 0xFF) else {
            return nil
        }
        // 校验 QR=1（必须是响应报文）
        guard (bytes[2] & 0x80) != 0 else {
            return nil
        }
        // 校验 RCODE=0（NOERROR）
        guard (bytes[3] & 0x0F) == 0 else {
            return nil
        }

        let qdcount = Int(bytes[4]) << 8 | Int(bytes[5])
        let ancount = Int(bytes[6]) << 8 | Int(bytes[7])
        guard qdcount <= 16 else { return nil }
        guard ancount > 0 else { return nil }

        var offset = 12
        for _ in 0..<qdcount {
            guard let next = skipName(in: bytes, from: offset), next + 4 <= bytes.count else {
                return nil
            }
            offset = next + 4
        }

        for _ in 0..<min(ancount, 16) {
            guard let next = skipName(in: bytes, from: offset), next + 10 <= bytes.count else {
                break
            }
            let rtype = Int(bytes[next]) << 8 | Int(bytes[next + 1])
            let rclass = Int(bytes[next + 2]) << 8 | Int(bytes[next + 3])
            let rdlen = Int(bytes[next + 8]) << 8 | Int(bytes[next + 9])
            let rdataStart = next + 10
            guard rdataStart + rdlen <= bytes.count else { break }
            if rtype == 1, rclass == 1, rdlen == 4 {
                return (0..<4).map { String(bytes[rdataStart + $0]) }.joined(separator: ".")
            }
            offset = rdataStart + rdlen
        }
        return nil
    }

    private static func skipName(in bytes: [UInt8], from start: Int) -> Int? {
        var i = start
        var steps = 0
        while i < bytes.count, steps < 128 {
            steps += 1
            let len = bytes[i]
            if len == 0 {
                return i + 1
            }
            if (len & 0xC0) == 0xC0 {
                guard i + 1 < bytes.count else { return nil }
                return i + 2
            }
            // 仅允许标准标签（<= 63），拒绝保留标志位 0x40 / 0x80
            guard (len & 0xC0) == 0, len <= 63 else { return nil }
            let next = i + 1 + Int(len)
            guard next <= bytes.count else { return nil }
            i = next
        }
        return nil
    }

    public var cacheCount: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache.count
    }

    public func cachedIP(for host: String) -> String? {
        let now = nowProvider()
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let hit = cache[host] else { return nil }
        if now.timeIntervalSince(hit.at) < ttl {
            return hit.ip
        }
        cache.removeValue(forKey: host)
        return nil
    }

    public func storeCachedIP(_ ip: String, for host: String) {
        let now = nowProvider()
        cacheLock.lock()
        defer { cacheLock.unlock() }

        cache[host] = (ip, now)
        if cache.count > maxEntries {
            // 先清过期条目
            let expiredKeys = cache.compactMap { key, value in
                now.timeIntervalSince(value.at) >= ttl ? key : nil
            }
            for key in expiredKeys {
                cache.removeValue(forKey: key)
            }
            // 仍超上限则按插入时间淘汰最早条目
            while cache.count > maxEntries {
                guard let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key else { break }
                cache.removeValue(forKey: oldest)
            }
        }
    }

    /// 异步解析域名，在独立 DNS 工作队列执行 UDP 查询，完成后切回 `callbackQueue`。
    public func resolveAsync(
        _ host: String,
        interface: NWInterface?,
        callbackQueue: DispatchQueue,
        completion: @escaping @Sendable (String?) -> Void
    ) {
        if !Self.isName(host) {
            callbackQueue.async { completion(host) }
            return
        }
        if let hit = cachedIP(for: host) {
            callbackQueue.async { completion(hit) }
            return
        }
        dnsQueue.async { [self] in
            let resolved = self.resolveRemote(host, interface: interface)
            callbackQueue.async { completion(resolved) }
        }
    }

    public func resolveSync(_ host: String, interface: NWInterface?) -> String? {
        if !Self.isName(host) { return host }
        if let hit = cachedIP(for: host) { return hit }
        return resolveRemote(host, interface: interface)
    }

    private func resolveRemote(_ host: String, interface: NWInterface?) -> String? {
        for server in servers {
            if let ip = query(host, server: server, interface: interface) {
                storeCachedIP(ip, for: host)
                return ip
            }
        }
        return nil
    }

    /// 一次 connected UDP A 查询。失败返回 nil（换下一个服务器）。
    private func query(_ host: String, server: Server, interface: NWInterface?) -> String? {
        let id = UInt16.random(in: 1...UInt16.max)
        guard let q = Self.buildQuery(host: host, id: id) else { return nil }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        if let iface = interface {
            let idx = if_nametoindex(iface.name)
            if idx > 0 {
                var index = idx
                setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
            }
        }

        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = server.port.bigEndian
        guard inet_pton(AF_INET, server.host, &addr.sin_addr) == 1 else { return nil }

        var sa = addr
        let connResult = withUnsafePointer(to: &sa) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                Darwin.connect(fd, sap, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connResult == 0 else { return nil }

        let sent = q.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.send(fd, base, raw.count, 0)
        }
        guard sent == q.count else { return nil }

        let timeoutNs = UInt64(timeoutSeconds) * 1_000_000_000
        let deadlineNs = DispatchTime.now().uptimeNanoseconds &+ timeoutNs

        var buf = [UInt8](repeating: 0, count: 1500)
        while true {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            guard nowNs < deadlineNs else { return nil }
            let remainingUs = max(UInt64(1), (deadlineNs - nowNs) / 1_000)
            var rcvTv = timeval(
                tv_sec: Int(remainingUs / 1_000_000),
                tv_usec: Int32(remainingUs % 1_000_000)
            )
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcvTv, socklen_t(MemoryLayout<timeval>.size))

            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.recv(fd, ptr.baseAddress, ptr.count, 0)
            }
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                return nil
            }
            if n == 0 {
                return nil
            }
            if n > 12, let ip = Self.parseResponse(Data(buf[0..<n]), expectedID: id) {
                return ip
            }
            // 错误 TXID、QR=0 或畸形响应报文：丢弃并继续在总截止时间内等待合法响应
        }
    }
}
