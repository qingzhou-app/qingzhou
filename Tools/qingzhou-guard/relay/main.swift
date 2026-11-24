// qingzhou-relay —— 供 pf 断网开关使用的「root 出口」。
//
// 为什么需要它（实测结论，不是推测）：
//   轻舟的 xray 跑在 NEPacketTunnelProvider 扩展里，实测 uid = 501（与普通程序同一个
//   用户身份）。macOS 的 pf 只能按 uid 匹配，不能按进程名匹配。所以「拦掉除 root 以外
//   的所有出站」这条规则会把代理自己的出站也一起拦死 → 整机断网。
//
//   解法：让代理的所有出站都先连到本进程（root 身份、只听 127.0.0.1），由本进程去真正
//   拨号。这样 pf 就可以写成静态规则：
//       pass  out quick on lo0 all
//       pass  out quick to <局域网/保留段>
//       pass  out quick user root
//       block out quick all              ← 其余（含 uid 501）一律拒绝
//   隧道在跑时：uid 501 的包只去 127.0.0.1（放行），真正出网由 root 完成。
//   隧道挂了：uid 501 的包没有出口可用，直接丢弃 —— 没有检测窗口、无需看门狗。
//
// 安全边界（必须有，否则 loopback 上的任何进程都能借它绕过断网开关）：
//   * 只监听 127.0.0.1；
//   * 强制 SOCKS5 用户名/密码认证（RFC 1929），凭据放在仅 root 可读的文件里；
//   * 只支持 CONNECT（TCP），拒绝 BIND / UDP ASSOCIATE；
//   * 认证文件读不到就**拒绝启动**（fail closed），绝不以开放代理的形态跑起来。

import Foundation
import Network
import Darwin

// MARK: - 配置

struct RelayConfig {
    var port: UInt16 = 10808
    /// 控制端口：App（沙箱、无 root）通过它请求 root 侧动作（目前只有改时区）。
    /// 为什么不用文件：App Group 受 TCC 保护，launchd 起的 guard 进程没有 FDA 读不到
    /// （实测：guard-run.sh 在「完全磁盘访问权限」列表里是灰的，无法授权）。
    /// 网络连接不受 TCC 限制，所以这里用回环 TCP 当控制通道。
    var controlPort: UInt16 = 10809
    var authFile: String = "/Library/Application Support/qingzhou-guard/relay-auth"
    var logPath: String = "/var/log/qingzhou-relay.log"
}

func parseArgs() -> RelayConfig {
    var cfg = RelayConfig()
    var args = Array(CommandLine.arguments.dropFirst())
    while let key = args.first {
        args.removeFirst()
        func next() -> String? { args.isEmpty ? nil : args.removeFirst() }
        switch key {
        case "--port":     if let v = next(), let p = UInt16(v) { cfg.port = p }
        case "--control-port": if let v = next(), let p = UInt16(v) { cfg.controlPort = p }
        case "--auth-file": if let v = next() { cfg.authFile = v }
        case "--log":      if let v = next() { cfg.logPath = v }
        default: break
        }
    }
    return cfg
}

let cfg = parseArgs()

// MARK: - 日志（带时间戳，追加写；root 才有权写 /var/log）

let logHandle: FileHandle? = {
    if !FileManager.default.fileExists(atPath: cfg.logPath) {
        FileManager.default.createFile(atPath: cfg.logPath, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
    }
    guard let h = FileHandle(forWritingAtPath: cfg.logPath) else { return nil }
    h.seekToEndOfFile()
    return h
}()

func log(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts) [relay] \(message)\n"
    if let h = logHandle {
        h.write(Data(line.utf8))
    } else {
        FileHandle.standardError.write(Data(line.utf8))
    }
}

// MARK: - 凭据

func loadCredentials(_ path: String) -> (user: String, pass: String)? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    for raw in text.split(whereSeparator: { $0.isNewline }) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let sep = line.firstIndex(of: ":") else { continue }
        let user = String(line[..<sep])
        let pass = String(line[line.index(after: sep)...])
        if !user.isEmpty, !pass.isEmpty { return (user, pass) }
    }
    return nil
}

guard let creds = loadCredentials(cfg.authFile) else {
    // fail closed：没有凭据就不启动，绝不退化成无认证代理
    log("FATAL: 无法从 \(cfg.authFile) 读取凭据，拒绝以无认证方式启动")
    exit(2)
}

// MARK: - SOCKS5 服务

// MARK: - 会话登记
//
// 必须强引用活着的会话：NWConnection 的回调里只 hold 了 weak self，
// 若 listener 的 newConnectionHandler 里直接 `ClientSession(...).start()`，
// 对象会在 start 返回后立刻释放，所有回调变 no-op —— 表现为"连上了但什么都不发生"。
final class SessionRegistry {
    private var sessions: [ObjectIdentifier: ClientSession] = [:]
    private let lock = NSLock()

    func add(_ session: ClientSession) {
        lock.lock(); defer { lock.unlock() }
        sessions[ObjectIdentifier(session)] = session
    }

    func remove(_ session: ClientSession) {
        lock.lock(); defer { lock.unlock() }
        sessions.removeValue(forKey: ObjectIdentifier(session))
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.count
    }
}

// MARK: - 域名解析（绕开 TUN）
//
// 为什么不交给 NWConnection／系统解析：VPN 的默认路由在 TUN 上，系统 DNS 也是
// TUN 里的服务器 —— 系统解析海外域名返回 **fakedns 假 IP**，连假 IP 会跟着默认
// 路由绕回 TUN（实测：经中继查出口 IP 得到的是 VPN 出口）。所以中继必须自己解析：
// 直查公网国内 DNS（UDP 223.5.5.5 / 119.29.29.29），socket 绑定物理网卡，
// 拿到真实 IP 后再拨（裸 IP + requiredInterface 已实测有效）。
enum RelayDNS {
    private static let servers: [String] = ["223.5.5.5", "119.29.29.29"]
    private static let cacheLock = NSLock()
    private static var cache: [String: (ip: String, at: Date)] = [:]
    private static let ttl: TimeInterval = 60

    /// 是域名（不是 IP 字面量）就返回 true。
    static func isName(_ host: String) -> Bool {
        var v4 = in_addr(); var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) != 1 && inet_pton(AF_INET6, host, &v6) != 1
    }

    static func resolve(_ host: String, interface: NWInterface?) -> String? {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return host }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 { return host }

        cacheLock.lock()
        if let hit = cache[host], Date().timeIntervalSince(hit.at) < ttl {
            cacheLock.unlock()
            return hit.ip
        }
        cacheLock.unlock()

        for server in servers {
            if let ip = query(host, server: server, interface: interface) {
                cacheLock.lock()
                cache[host] = (ip, Date())
                cacheLock.unlock()
                return ip
            }
        }
        return nil
    }

    /// 一次 UDP A 查询。失败返回 nil（换下一个服务器）。
    private static func query(_ host: String, server: String, interface: NWInterface?) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // 绑定物理网卡：查询包绝不能进 TUN
        if let iface = interface {
            let idx = if_nametoindex(iface.name)
            if idx > 0 {
            var index = idx
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
            }
        }
        // 3 秒收不到就换下一个
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(53).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr(server))
        var q = Data()
        let id = UInt16.random(in: 1...UInt16.max)
        q.append(contentsOf: [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00,
                              0, 1, 0, 0, 0, 0, 0, 0])
        for label in host.split(separator: ".") where !label.isEmpty {
            q.append(UInt8(label.utf8.count))
            q.append(contentsOf: Array(label.utf8))
        }
        q.append(0)
        q.append(contentsOf: [0, 1, 0, 1])   // QTYPE=A, QCLASS=IN

        var sa = addr
        let sent = q.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &sa) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                    sendto(fd, raw.baseAddress, raw.count, 0, sap,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == q.count else { return nil }

        var buf = [UInt8](repeating: 0, count: 1500)
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            recv(fd, ptr.baseAddress, ptr.count, 0)
        }
        guard n > 12 else { return nil }
        let resp = buf[0..<n]
        guard resp[3] & 0x0F == 0 else { return nil }   // RCODE 在 flags 低字节
        guard resp.count >= 12 + 6 else { return nil }

        // 跳过 Question 段（名字可能是压缩指针）
        var i = 12
        while i < resp.count, resp[i] > 0 {
            if resp[i] & 0xC0 == 0xC0 { i += 2; break }
            i += Int(resp[i]) + 1
        }
        if i < resp.count, resp[i] == 0 { i += 1 }
        i += 4

        var answers = 0
        while i + 12 <= resp.count, answers < 8 {
            if resp[i] & 0xC0 == 0xC0 {
                i += 2
            } else {
                var j = i
                while j < resp.count, resp[j] > 0 { j += Int(resp[j]) + 1 }
                i = (j < resp.count && resp[j] == 0) ? j + 1 : j
            }
            guard i + 10 <= resp.count else { break }
            let rtype = Int(resp[i]) << 8 | Int(resp[i + 1])
            let rdlen = Int(resp[i + 8]) << 8 | Int(resp[i + 9])
            let rdataStart = i + 10
            if rtype == 1, rdlen == 4, rdataStart + 4 <= resp.count {
                return (0..<4).map { String(resp[rdataStart + $0]) }.joined(separator: ".")
            }
            i = rdataStart + rdlen
            answers += 1
        }
        return nil
    }
}

// MARK: - 物理出口接口
//
// 中继自己的拨号**绝不能走默认路由**：分流模式下默认路由指向轻舟的 TUN，
// 绕进去的包会回到 xray，xray 的 direct 出站又经 dialerProxy 交回中继 ——
// 无限递归（线上实测：微信 1 秒重连 17 次、整机断网）。
//
// xray 自己没有这个问题：它跑在 NE 扩展进程里，系统豁免它进自己开的 TUN；
// 中继是独立的 root 进程，没有豁免，必须显式绑定物理网卡（IP_BOUND_IF 语义，
// Network.framework 里是 NWParameters.requiredInterface）。
enum PhysicalEgress {
    private static let lock = NSLock()
    private static var iface: NWInterface?
    private static var logged = false

    static func start() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            // VPN 生效时 path 经 utun，但 availableInterfaces 会带出底层物理口
            let physical = path.availableInterfaces.first {
                $0.type == .wifi || $0.type == .wiredEthernet || $0.type == .cellular
            }
            lock.lock()
            let old = iface?.name
            iface = physical
            let first = !logged
            logged = true
            lock.unlock()
            if first {
                log("物理出口接口：\(physical?.name ?? "未知 —— 拿不到就拒绝拨号")")
            } else if old != physical?.name {
                log("物理出口接口切换：\(old ?? "?") → \(physical?.name ?? "?")（旧连接会断，新连接用新口）")
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    static func current() -> NWInterface? {
        lock.lock(); defer { lock.unlock() }
        return iface
    }
}

let registry = SessionRegistry()

final class ClientSession {
    /// 会话登记表（放在类型里而不是顶层 `let`：顶层值不能被类型捕获）。
    static let registry = SessionRegistry()

    private let connection: NWConnection
    /// 由调用方注入而不是读全局：顶层脚本里的 `let` 不能被类型捕获。
    private let creds: (user: String, pass: String)
    private var buffer = Data()
    private var stage: Stage = .greeting
    private var upstream: NWConnection?
    private var authed = false

    private enum Stage { case greeting, auth, request, piping, closed }

    init(_ connection: NWConnection, creds: (user: String, pass: String)) {
        self.connection = connection
        self.creds = creds
    }

    func start() {
        Self.registry.add(self)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.close() }
        }
        connection.start(queue: .global(qos: .userInitiated))
        pump()
    }

    private func pump() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if error != nil || isComplete { self.close(); return }
            self.drain()
            if self.stage != .piping && self.stage != .closed { self.pump() }
        }
    }

    private func drain() {
        while true {
            switch stage {
            case .greeting:
                guard buffer.count >= 2 else { return }
                let n = Int(buffer[buffer.index(buffer.startIndex, offsetBy: 1)])
                guard buffer.count >= 2 + n else { return }
                let methods = [UInt8](buffer[(buffer.startIndex + 2)..<(buffer.startIndex + 2 + n)])
                buffer.removeFirst(2 + n)
                // 只要用户名/密码认证（0x02）
                guard methods.contains(0x02) else {
                    send([0x05, 0xFF]); log("拒绝：客户端不支持用户名/密码认证"); close(); return
                }
                send([0x05, 0x02])
                stage = .auth

            case .auth:
                guard buffer.count >= 2 else { return }
                let ulen = Int(buffer[buffer.index(buffer.startIndex, offsetBy: 1)])
                guard buffer.count >= 2 + ulen + 1 else { return }
                let plenIndex = buffer.startIndex + 2 + ulen
                let plen = Int(buffer[plenIndex])
                guard buffer.count >= 2 + ulen + 1 + plen else { return }
                let user = String(decoding: buffer[(buffer.startIndex + 2)..<(buffer.startIndex + 2 + ulen)], as: UTF8.self)
                let pass = String(decoding: buffer[(plenIndex + 1)..<(plenIndex + 1 + plen)], as: UTF8.self)
                buffer.removeFirst(2 + ulen + 1 + plen)
                guard user == creds.user, pass == creds.pass else {
                    send([0x01, 0x01]); log("拒绝：认证失败"); close(); return
                }
                send([0x01, 0x00])
                authed = true
                stage = .request

            case .request:
                guard buffer.count >= 5 else { return }
                let bytes = [UInt8](buffer.prefix(5))
                guard bytes[0] == 0x05 else { replyFailure(0x01); return }
                guard bytes[1] == 0x01 else {   // 只允许 CONNECT
                    log("拒绝：不支持的 CMD=\(bytes[1])（只做 CONNECT）")
                    replyFailure(0x07); return
                }
                guard authed else { replyFailure(0x02); return }
                if let (host, port, consumed) = parseAddress(buffer) {
                    buffer.removeFirst(consumed)
                    stage = .piping
                    connect(host: host, port: port)
                    return
                }
                return   // 地址还没收全，等下一次 receive

            case .piping, .closed:
                return
            }
        }
    }

    /// 解析 ATYP + 地址 + 端口。返回 (host, port, 消耗字节数)。
    private func parseAddress(_ data: Data) -> (String, UInt16, Int)? {
        guard data.count >= 4 else { return nil }
        let atyp = data[data.startIndex + 3]
        switch atyp {
        case 0x01:   // IPv4
            guard data.count >= 4 + 4 + 2 else { return nil }
            let b = [UInt8](data[(data.startIndex + 4)..<(data.startIndex + 8)])
            let host = b.map(String.init).joined(separator: ".")
            let port = UInt16(data[data.startIndex + 8]) << 8 | UInt16(data[data.startIndex + 9])
            return (host, port, 10)
        case 0x03:   // 域名
            guard data.count >= 5 else { return nil }
            let len = Int(data[data.startIndex + 4])
            guard data.count >= 5 + len + 2 else { return nil }
            let host = String(decoding: data[(data.startIndex + 5)..<(data.startIndex + 5 + len)], as: UTF8.self)
            let portIndex = data.startIndex + 5 + len
            let port = UInt16(data[portIndex]) << 8 | UInt16(data[portIndex + 1])
            return (host, port, 5 + len + 2)
        case 0x04:   // IPv6
            guard data.count >= 4 + 16 + 2 else { return nil }
            let raw = [UInt8](data[(data.startIndex + 4)..<(data.startIndex + 20)])
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { dst in
                for i in 0..<16 { dst[i] = raw[i] }
            }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var a = addr
            inet_ntop(AF_INET6, &a, &buf, socklen_t(INET6_ADDRSTRLEN))
            let host = String(cString: buf)
            let portIndex = data.startIndex + 20
            let port = UInt16(data[portIndex]) << 8 | UInt16(data[portIndex + 1])
            return (host, port, 22)
        default:
            replyFailure(0x08)
            return nil
        }
    }

    private func connect(host: String, port: UInt16) {
        // 域名必须先自解析：系统解析走 TUN 里的 DNS，海外域名会拿到 fakedns 假 IP，
        // 连假 IP 跟着默认路由绕回 TUN（实测经中继查出口 IP 得到的是 VPN 出口）。
        // 自解析用绑物理口的 UDP 直查公网 DNS，拿到真实 IP 后裸连接（已实测绕开 TUN）。
        var dialTarget = host
        var resolvedNote = ""
        if RelayDNS.isName(host) {
            guard let ip = RelayDNS.resolve(host, interface: PhysicalEgress.current()) else {
                log("DNS 解析失败：\(host)")
                replyFailure(0x04)   // host unreachable
                return
            }
            dialTarget = ip
            resolvedNote = " → \(ip)"
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(dialTarget),
                                           port: NWEndpoint.Port(rawValue: port) ?? 0)
        let params = NWParameters.tcp
        // 绑定物理网卡：不绑的拨号会跟着默认路由绕回 TUN（见 PhysicalEgress 注释）
        if let iface = PhysicalEgress.current() {
            params.requiredInterface = iface
        } else {
            // 宁可失败也不能不绑：不绑的拨号在分流模式下是无限递归
            log("无物理出口接口，拒绝拨号 \(host):\(port)")
            replyFailure(0x01)
            return
        }
        let up = NWConnection(to: endpoint, using: params)
        upstream = up
        up.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.send([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
                log("CONNECT \(host):\(port)\(resolvedNote)")
                self.pipeUpstreamToClient()
                // 客户端可能在上游 ready 之前就发了数据
                if !self.buffer.isEmpty {
                    let pending = self.buffer
                    self.buffer.removeAll()
                    up.send(content: pending, completion: .contentProcessed { _ in })
                }
                self.pipeClientToUpstream()
            case .failed(let error):
                log("上游连接失败 \(host):\(port) — \(error)")
                self.replyFailure(0x05)
            default:
                break
            }
        }
        up.start(queue: .global(qos: .userInitiated))
    }

    private func pipeClientToUpstream() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let up = self.upstream else { return }
            if let data, !data.isEmpty {
                up.send(content: data, completion: .contentProcessed { _ in })
            }
            if error != nil || isComplete { self.close(); return }
            self.pipeClientToUpstream()
        }
    }

    private func pipeUpstreamToClient() {
        upstream?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.connection.send(content: data, completion: .contentProcessed { _ in })
            }
            if error != nil || isComplete { self.close(); return }
            self.pipeUpstreamToClient()
        }
    }

    private func send(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    private func replyFailure(_ code: UInt8) {
        send([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        close()
    }

    private func close() {
        guard stage != .closed else { return }
        stage = .closed
        buffer.removeAll()
        upstream?.cancel()
        upstream = nil
        connection.cancel()
        // 延后从登记表摘除：直接 remove 会在本方法执行中把 self 释放掉（use-after-free）。
        // 闭包强引用 self，等 remove 返回、闭包结束才真正析构。
        DispatchQueue.global().async { [self] in
            Self.registry.remove(self)
        }
    }
}

// MARK: - 监听

guard let port = NWEndpoint.Port(rawValue: cfg.port) else {
    log("FATAL: 非法端口 \(cfg.port)")
    exit(2)
}
let params = NWParameters.tcp
params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
params.allowLocalEndpointReuse = true

let listener: NWListener
do {
    listener = try NWListener(using: params)
} catch {
    log("FATAL: 无法监听 127.0.0.1:\(cfg.port) — \(error)")
    exit(2)
}

listener.stateUpdateHandler = { state in
    switch state {
    case .ready: log("listening on 127.0.0.1:\(cfg.port)（仅 CONNECT + 用户名密码认证）")
    case .failed(let error):
        log("FATAL: listener failed — \(error)")
        exit(1)
    default: break
    }
}

listener.newConnectionHandler = { connection in
    ClientSession(connection, creds: creds).start()
}

PhysicalEgress.start()
listener.start(queue: .global(qos: .userInitiated))

// MARK: - 控制端口（root 侧动作）
//
// App 是沙箱进程、无 root，而改系统时区必须 root。App Group 又被 TCC 保护、
// launchd 起的本进程读不到（FDA 在系统设置里是灰的、无法授权）。
// 所以开一个只听回环的控制端口：App 连上来发一行文本，本进程以 root 执行。
//
// 协议（纯文本，一行一条，认证先行）：
//   AUTH <user> <pass>   -> OK / ERR auth
//   SET-TZ <IANA 时区>    -> OK / ERR zone / ERR set
//   GET-TZ               -> <当前时区>
//   RESTORE              -> OK / ERR no-orig
//
// 安全边界与转发端口一致：只听 127.0.0.1、强制用户名密码认证（同一份 relay-auth）、
// 只认白名单命令、时区值必须能在 /usr/share/zoneinfo 下找到（防注入路径）。

func currentTimeZone() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/systemsetup")
    p.arguments = ["-gettimezone"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let out = String(decoding: data, as: UTF8.self)
    // "Time Zone: America/New_York"
    if let range = out.range(of: "Time Zone: ") {
        return String(out[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return ""
}

@discardableResult
func setSystemTimeZone(_ id: String) -> Bool {
    // 防注入：必须是 /usr/share/zoneinfo 下真实存在的时区（不接受 ../ 之类）
    guard !id.isEmpty, !id.contains(".."), !id.contains(" "),
          FileManager.default.fileExists(atPath: "/usr/share/zoneinfo/" + id) else {
        return false
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/systemsetup")
    p.arguments = ["-settimezone", id]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

/// 原始时区记录：首次切换前存一份，RESTORE 用它还原。
let tzOrigPath = "/Library/Application Support/qingzhou-guard/timezone-orig"

/// 控制会话登记表：ControlSession 必须被强引用，否则 newConnectionHandler 返回后
/// 会被 ARC 立刻回收，receive 回调永远不触发（实测踩过：连接建了但收不到数据）。
final class ControlRegistry {
    private var sessions: [ObjectIdentifier: ControlSession] = [:]
    private let lock = NSLock()
    func add(_ s: ControlSession) { lock.lock(); sessions[ObjectIdentifier(s)] = s; lock.unlock() }
    func remove(_ s: ControlSession) { lock.lock(); sessions.removeValue(forKey: ObjectIdentifier(s)); lock.unlock() }
}
let controlRegistry = ControlRegistry()

final class ControlSession {
    private let connection: NWConnection
    private let creds: (user: String, pass: String)
    private var buffer = Data()
    private var authed = false

    init(_ connection: NWConnection, creds: (user: String, pass: String)) {
        self.connection = connection
        self.creds = creds
    }

    func start() {
        controlRegistry.add(self)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.close() }
        }
        connection.start(queue: .global(qos: .userInitiated))
        pump()
    }

    private func pump() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if error != nil || isComplete { self.close(); return }
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: self.buffer[self.buffer.startIndex..<nl], as: UTF8.self)
                self.buffer.removeFirst(self.buffer.distance(from: self.buffer.startIndex, to: nl) + 1)
                if !self.handle(line) { return }
            }
            self.pump()
        }
    }

    /// 返回 false 表示会话结束（不回 pump）。
    private func handle(_ line: String) -> Bool {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard let cmd = parts.first?.uppercased() else { return true }

        if cmd == "AUTH" {
            guard parts.count == 3, parts[1] == creds.user, parts[2] == creds.pass else {
                // 先让 ERR 真正发出去再关：send 是异步的，立刻 cancel 会丢掉响应
                sendLine("ERR auth") { [weak self] in self?.close() }
                return false
            }
            authed = true
            sendLine("OK")
            return true
        }
        guard authed else { sendLine("ERR auth") { [weak self] in self?.close() }; return false }

        switch cmd {
        case "SET-TZ":
            guard parts.count == 2 else { sendLine("ERR zone"); return true }
            let tz = parts[1].trimmingCharacters(in: .whitespaces)
            // 首次切换前记录原时区（只记一次），供 RESTORE 用
            if !FileManager.default.fileExists(atPath: tzOrigPath) {
                let orig = currentTimeZone()
                if !orig.isEmpty {
                    try? orig.write(toFile: tzOrigPath, atomically: true, encoding: .utf8)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tzOrigPath)
                    log("记录原时区：\(orig)")
                }
            }
            if let existing = try? String(contentsOfFile: tzOrigPath, encoding: .utf8),
               existing.trimmingCharacters(in: .whitespacesAndNewlines) == tz {
                sendLine("OK")   // 已经是目标值，不重复执行
                return true
            }
            if setSystemTimeZone(tz) {
                log("系统时区 → \(tz)")
                sendLine("OK")
            } else {
                log("设置时区失败：\(tz)")
                sendLine("ERR set")
            }
            return true

        case "GET-TZ":
            sendLine(currentTimeZone())
            return true

        case "RESTORE":
            guard let orig = try? String(contentsOfFile: tzOrigPath, encoding: .utf8),
                  !orig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                sendLine("ERR no-orig"); return true
            }
            let target = orig.trimmingCharacters(in: .whitespacesAndNewlines)
            if setSystemTimeZone(target) {
                log("还原时区 → \(target)")
                sendLine("OK")
            } else {
                sendLine("ERR set")
            }
            return true

        default:
            sendLine("ERR cmd")
            return true
        }
    }

    private func sendLine(_ text: String, completion: (() -> Void)? = nil) {
        connection.send(content: Data((text + "\n").utf8),
                        completion: .contentProcessed { _ in completion?() })
    }

    private func close() {
        connection.cancel()
        controlRegistry.remove(self)
    }
}

// 控制端口必须用独立参数：全局 params 的 requiredLocalEndpoint 钉死在转发端口上，
// 复用会导致 listen 报 Invalid argument（实测）。
let controlParams = NWParameters.tcp
controlParams.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                port: NWEndpoint.Port(rawValue: cfg.controlPort)!)
controlParams.allowLocalEndpointReuse = true

let controlListener: NWListener?
do {
    controlListener = try NWListener(using: controlParams)
} catch {
    log("警告：控制端口 \(cfg.controlPort) 无法监听（\(error)）—— 时区跟随不可用，代理不受影响")
    controlListener = nil
}

controlListener?.stateUpdateHandler = { state in
    switch state {
    case .ready: log("controller listening on 127.0.0.1:\(cfg.controlPort)（时区指令，需认证）")
    case .failed(let error): log("控制端口失败：\(error)")
    default: break
    }
}
controlListener?.newConnectionHandler = { connection in
    ControlSession(connection, creds: creds).start()
}
controlListener?.start(queue: .global(qos: .userInitiated))

dispatchMain()
