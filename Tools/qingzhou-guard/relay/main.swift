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
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: port) ?? 0)
        let params = NWParameters.tcp
        // 出站不做 Happy Eyeballs 的特殊处理，交给系统默认
        let up = NWConnection(to: endpoint, using: params)
        upstream = up
        up.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.send([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
                log("CONNECT \(host):\(port)")
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
listener.start(queue: .global(qos: .userInitiated))
dispatchMain()
