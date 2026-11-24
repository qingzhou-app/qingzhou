import Foundation
import Network
import Darwin

/// 活着的 SOCKS5 客户端会话登记表（保证会话在连接期间不被提前释放）。
public final class SessionRegistry<Session: AnyObject>: @unchecked Sendable {
    private var sessions: [ObjectIdentifier: Session] = [:]
    private let lock = NSLock()

    public init() {}

    public func add(_ session: Session) {
        lock.lock()
        sessions[ObjectIdentifier(session)] = session
        lock.unlock()
    }

    public func remove(_ session: Session) {
        lock.lock()
        sessions.removeValue(forKey: ObjectIdentifier(session))
        lock.unlock()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }
}

/// 单个 SOCKS5 CONNECT 转发会话。
///
/// 并发不变量：
/// - 每会话拥有独立的串行 `queue`，`connection`、`upstream` 回调与 DNS 完成回调都在该 `queue` 上运行；
/// - 所有可变状态（`buffer`、`stage`、`upstream`、`authed`）仅在 `queue` 内读写；
/// - `close()` 幂等（检查 `stage != .closed`）。
public final class ClientSession: @unchecked Sendable {
    private static let maxHandshakeBufferBytes = 16 * 1024

    private let connection: NWConnection
    private let creds: CredentialPair
    private let registry: SessionRegistry<ClientSession>
    private let dns: RelayDNS
    private let egressProvider: @Sendable () -> NWInterface?
    private let requirePhysicalInterface: Bool
    private let logger: RelayLogger?
    private let queue: DispatchQueue

    private var buffer = Data()
    private var stage: Stage = .greeting
    private var upstream: NWConnection?
    private var authed = false
    private var clientToUpstreamEOF = false
    private var upstreamToClientEOF = false

    private enum Stage { case greeting, auth, request, connecting, piping, closed }

    public init(
        _ connection: NWConnection,
        creds: CredentialPair,
        registry: SessionRegistry<ClientSession>,
        dns: RelayDNS,
        egressProvider: @escaping @Sendable () -> NWInterface?,
        requirePhysicalInterface: Bool = true,
        logger: RelayLogger? = nil
    ) {
        self.connection = connection
        self.creds = creds
        self.registry = registry
        self.dns = dns
        self.egressProvider = egressProvider
        self.requirePhysicalInterface = requirePhysicalInterface
        self.logger = logger
        self.queue = DispatchQueue(label: "com.sbraveyoung.qingzhou.relay.client.\(UUID().uuidString)")
    }

    public func start() {
        queue.async { [self] in
            guard stage != .closed else { return }
            registry.add(self)
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .failed = state { self.closeOnQueue() }
                if case .cancelled = state { self.closeOnQueue() }
            }
            connection.start(queue: queue)
            pumpOnQueue()
        }
    }

    public func close() {
        queue.async { [weak self] in
            self?.closeOnQueue()
        }
    }

    private func pumpOnQueue() {
        guard stage != .piping && stage != .connecting && stage != .closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard self.stage != .closed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if self.buffer.count > Self.maxHandshakeBufferBytes {
                    self.closeOnQueue()
                    return
                }
            }
            self.drainOnQueue()
            if error != nil || isComplete {
                if self.stage != .connecting && self.stage != .piping {
                    self.closeOnQueue()
                }
                return
            }
            if self.stage != .piping && self.stage != .connecting && self.stage != .closed {
                self.pumpOnQueue()
            }
        }
    }

    private func drainOnQueue() {
        while true {
            switch stage {
            case .greeting:
                guard buffer.count >= 2 else { return }
                let version = buffer[buffer.startIndex]
                guard version == 0x05 else {
                    closeOnQueue()
                    return
                }
                let n = Int(buffer[buffer.index(buffer.startIndex, offsetBy: 1)])
                guard buffer.count >= 2 + n else { return }
                let methods = [UInt8](buffer[(buffer.startIndex + 2)..<(buffer.startIndex + 2 + n)])
                buffer.removeFirst(2 + n)
                guard methods.contains(0x02) else {
                    sendOnQueue([0x05, 0xFF]) { [weak self] in self?.closeOnQueue() }
                    logger?.log("拒绝：客户端不支持用户名/密码认证")
                    stage = .closed
                    return
                }
                sendOnQueue([0x05, 0x02])
                stage = .auth

            case .auth:
                guard buffer.count >= 2 else { return }
                let subVer = buffer[buffer.startIndex]
                guard subVer == 0x01 else {
                    sendOnQueue([0x01, 0x01]) { [weak self] in self?.closeOnQueue() }
                    stage = .closed
                    return
                }
                let ulen = Int(buffer[buffer.index(buffer.startIndex, offsetBy: 1)])
                guard buffer.count >= 2 + ulen + 1 else { return }
                let plenIndex = buffer.startIndex + 2 + ulen
                let plen = Int(buffer[plenIndex])
                guard buffer.count >= 2 + ulen + 1 + plen else { return }
                let user = String(decoding: buffer[(buffer.startIndex + 2)..<(buffer.startIndex + 2 + ulen)], as: UTF8.self)
                let pass = String(decoding: buffer[(plenIndex + 1)..<(plenIndex + 1 + plen)], as: UTF8.self)
                buffer.removeFirst(2 + ulen + 1 + plen)
                guard user == creds.user, pass == creds.pass else {
                    sendOnQueue([0x01, 0x01]) { [weak self] in self?.closeOnQueue() }
                    logger?.log("拒绝：认证失败")
                    stage = .closed
                    return
                }
                sendOnQueue([0x01, 0x00])
                authed = true
                stage = .request

            case .request:
                guard buffer.count >= 5 else { return }
                let bytes = [UInt8](buffer.prefix(5))
                guard bytes[0] == 0x05 else {
                    replyFailureOnQueue(0x01)
                    return
                }
                guard bytes[1] == 0x01 else {
                    logger?.log("拒绝：不支持的 CMD=\(bytes[1])（只做 CONNECT）")
                    replyFailureOnQueue(0x07)
                    return
                }
                guard authed else {
                    replyFailureOnQueue(0x02)
                    return
                }
                switch parseAddress(buffer) {
                case .parsed(let host, let port, let consumed):
                    guard port > 0 else {
                        replyFailureOnQueue(0x01)
                        return
                    }
                    buffer.removeFirst(consumed)
                    stage = .connecting
                    connectOnQueue(host: host, port: port)
                    return
                case .incomplete:
                    return
                case .invalidATYP:
                    replyFailureOnQueue(0x08)
                    return
                }

            case .connecting, .piping, .closed:
                return
            }
        }
    }

    private enum AddressParseResult {
        case parsed(host: String, port: UInt16, consumed: Int)
        case incomplete
        case invalidATYP
    }

    private func parseAddress(_ data: Data) -> AddressParseResult {
        guard data.count >= 4 else { return .incomplete }
        let atyp = data[data.startIndex + 3]
        switch atyp {
        case 0x01:
            guard data.count >= 10 else { return .incomplete }
            let b = [UInt8](data[(data.startIndex + 4)..<(data.startIndex + 8)])
            let host = b.map(String.init).joined(separator: ".")
            let port = UInt16(data[data.startIndex + 8]) << 8 | UInt16(data[data.startIndex + 9])
            return .parsed(host: host, port: port, consumed: 10)
        case 0x03:
            guard data.count >= 5 else { return .incomplete }
            let len = Int(data[data.startIndex + 4])
            guard len > 0 else { return .invalidATYP }
            guard data.count >= 5 + len + 2 else { return .incomplete }
            let host = String(decoding: data[(data.startIndex + 5)..<(data.startIndex + 5 + len)], as: UTF8.self)
            let portIndex = data.startIndex + 5 + len
            let port = UInt16(data[portIndex]) << 8 | UInt16(data[portIndex + 1])
            return .parsed(host: host, port: port, consumed: 5 + len + 2)
        case 0x04:
            guard data.count >= 22 else { return .incomplete }
            let raw = [UInt8](data[(data.startIndex + 4)..<(data.startIndex + 20)])
            var addr = in6_addr()
            withUnsafeMutableBytes(of: &addr) { dst in
                for i in 0..<16 { dst[i] = raw[i] }
            }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var a = addr
            inet_ntop(AF_INET6, &a, &buf, socklen_t(INET6_ADDRSTRLEN))
            let nulIdx = buf.firstIndex(of: 0) ?? buf.count
            let host = String(decoding: buf[0..<nulIdx].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let portIndex = data.startIndex + 20
            let port = UInt16(data[portIndex]) << 8 | UInt16(data[portIndex + 1])
            return .parsed(host: host, port: port, consumed: 22)
        default:
            return .invalidATYP
        }
    }

    private func connectOnQueue(host: String, port: UInt16) {
        let iface = egressProvider()
        if requirePhysicalInterface && iface == nil {
            logger?.log("无物理出口接口，拒绝拨号 \(host):\(port)")
            replyFailureOnQueue(0x01)
            return
        }

        if RelayDNS.isName(host) {
            dns.resolveAsync(host, interface: iface, callbackQueue: queue) { [weak self] ip in
                guard let self, self.stage == .connecting else { return }
                guard let ip else {
                    self.logger?.log("DNS 解析失败：\(host)")
                    self.replyFailureOnQueue(0x04)
                    return
                }
                self.dialUpstreamOnQueue(originalHost: host, dialTarget: ip, port: port, resolvedNote: " → \(ip)", interface: iface)
            }
        } else {
            dialUpstreamOnQueue(originalHost: host, dialTarget: host, port: port, resolvedNote: "", interface: iface)
        }
    }

    private func dialUpstreamOnQueue(
        originalHost: String,
        dialTarget: String,
        port: UInt16,
        resolvedNote: String,
        interface: NWInterface?
    ) {
        guard stage == .connecting else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            replyFailureOnQueue(0x01)
            return
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(dialTarget), port: nwPort)
        let params = NWParameters.tcp
        if requirePhysicalInterface {
            guard let iface = interface ?? egressProvider() else {
                logger?.log("无物理出口接口，拒绝拨号 \(originalHost):\(port)")
                replyFailureOnQueue(0x01)
                return
            }
            params.requiredInterface = iface
        }

        let up = NWConnection(to: endpoint, using: params)
        upstream = up
        up.stateUpdateHandler = { [weak self] state in
            guard let self, self.stage != .closed else { return }
            switch state {
            case .ready:
                self.stage = .piping
                self.sendOnQueue([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
                self.logger?.log("CONNECT \(originalHost):\(port)\(resolvedNote)")
                self.pipeUpstreamToClientOnQueue()
                if !self.buffer.isEmpty {
                    let pending = self.buffer
                    self.buffer.removeAll()
                    up.send(content: pending, completion: .contentProcessed { _ in })
                }
                self.pipeClientToUpstreamOnQueue()
            case .failed(let error):
                self.logger?.log("上游连接失败 \(originalHost):\(port) — \(error)")
                if self.stage == .connecting {
                    self.replyFailureOnQueue(0x05)
                } else {
                    self.closeOnQueue()
                }
            case .cancelled:
                self.closeOnQueue()
            default:
                break
            }
        }
        up.start(queue: queue)
    }

    private func pipeClientToUpstreamOnQueue() {
        guard stage == .piping, !clientToUpstreamEOF else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, self.stage == .piping, let up = self.upstream else { return }
            if let data, !data.isEmpty {
                up.send(content: data, completion: .contentProcessed { _ in })
            }
            if error != nil {
                self.closeOnQueue()
                return
            }
            if isComplete {
                self.clientToUpstreamEOF = true
                up.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] sendError in
                    guard let self, self.stage == .piping else { return }
                    if sendError != nil || self.upstreamToClientEOF {
                        self.closeOnQueue()
                    }
                })
                return
            }
            self.pipeClientToUpstreamOnQueue()
        }
    }

    private func pipeUpstreamToClientOnQueue() {
        guard stage == .piping, !upstreamToClientEOF, let up = upstream else { return }
        up.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, self.stage == .piping else { return }
            if let data, !data.isEmpty {
                self.connection.send(content: data, completion: .contentProcessed { _ in })
            }
            if error != nil {
                self.closeOnQueue()
                return
            }
            if isComplete {
                self.upstreamToClientEOF = true
                self.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] sendError in
                    guard let self, self.stage == .piping else { return }
                    if sendError != nil || self.clientToUpstreamEOF {
                        self.closeOnQueue()
                    }
                })
                return
            }
            self.pipeUpstreamToClientOnQueue()
        }
    }

    private func sendOnQueue(_ bytes: [UInt8], completion: (@Sendable () -> Void)? = nil) {
        connection.send(content: Data(bytes), completion: .contentProcessed { _ in completion?() })
    }

    private func replyFailureOnQueue(_ code: UInt8) {
        guard stage != .closed else { return }
        stage = .closed
        buffer.removeAll()
        upstream?.cancel()
        upstream = nil
        sendOnQueue([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) { [weak self] in
            self?.connection.cancel()
            self?.scheduleUnregister()
        }
    }

    private func closeOnQueue() {
        guard stage != .closed else { return }
        stage = .closed
        buffer.removeAll()
        upstream?.cancel()
        upstream = nil
        connection.cancel()
        scheduleUnregister()
    }

    private func scheduleUnregister() {
        queue.async { [self] in
            registry.remove(self)
        }
    }
}
