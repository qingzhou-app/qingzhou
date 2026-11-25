import Foundation
import Network

/// 控制端口单条 TCP 会话（仅接受已分离的控制凭据，执行时区切换与还原）。
///
/// 并发与边界不变量：
/// - 专用串行 `queue` 保护 `buffer`、`authed`、`closed`；
/// - 幂等 `close()`；
/// - `\n` 前行缓冲上限 `maxLineBytes`（默认 1024 字节），超限回 `ERR too-long\n` 并关闭。
public final class ControlSession: @unchecked Sendable {
    public static let defaultMaxLineBytes = 1024

    private let connection: NWConnection
    private let creds: CredentialPair
    private let timeZoneController: TimeZoneController
    private let registry: SessionRegistry<ControlSession>
    private let maxLineBytes: Int
    private let drainTimeout: TimeInterval
    private let queue: DispatchQueue

    private var buffer = Data()
    private var authed = false
    private var draining = false
    private var pendingSends = 0
    private var closed = false

    public init(
        _ connection: NWConnection,
        creds: CredentialPair,
        timeZoneController: TimeZoneController,
        registry: SessionRegistry<ControlSession>,
        maxLineBytes: Int = ControlSession.defaultMaxLineBytes,
        drainTimeout: TimeInterval = 2.0
    ) {
        self.connection = connection
        self.creds = creds
        self.timeZoneController = timeZoneController
        self.registry = registry
        self.maxLineBytes = max(16, maxLineBytes)
        self.drainTimeout = max(0.05, drainTimeout)
        self.queue = DispatchQueue(label: "com.sbraveyoung.qingzhou.relay.control.\(UUID().uuidString)")
    }

    public func start() {
        queue.async { [self] in
            guard !closed else { return }
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
        guard !closed, !draining else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed, !self.draining else { return }

            if let data, !data.isEmpty {
                self.buffer.append(data)
            }

            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let lineBytes = self.buffer.distance(from: self.buffer.startIndex, to: nl)
                var rawLine = self.buffer[self.buffer.startIndex..<nl]
                if rawLine.last == 0x0D {
                    rawLine = rawLine.dropLast()
                }
                if rawLine.count > self.maxLineBytes {
                    self.buffer.removeAll()
                    self.sendLineOnQueue("ERR too-long") { [weak self] in self?.closeOnQueue() }
                    return
                }
                let line = String(decoding: rawLine, as: UTF8.self)
                self.buffer.removeFirst(lineBytes + 1)
                if !self.handleOnQueue(line) {
                    return
                }
            }

            let pendingBytes = self.buffer.last == 0x0D ? self.buffer.count - 1 : self.buffer.count
            if pendingBytes > self.maxLineBytes {
                self.buffer.removeAll()
                self.sendLineOnQueue("ERR too-long") { [weak self] in self?.closeOnQueue() }
                return
            }

            if error != nil {
                self.closeOnQueue()
                return
            }

            if isComplete {
                if self.pendingSends > 0 {
                    self.enterDrainingOnQueue()
                } else {
                    self.closeOnQueue()
                }
                return
            }

            self.pumpOnQueue()
        }
    }

    /// 返回 false 表示会话已终止并安排关闭（不再回 pump）。
    private func handleOnQueue(_ line: String) -> Bool {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard let cmd = parts.first?.uppercased() else { return true }

        if cmd == "AUTH" {
            guard parts.count == 3, parts[1] == creds.user, parts[2] == creds.pass else {
                sendLineOnQueue("ERR auth") { [weak self] in self?.closeOnQueue() }
                return false
            }
            authed = true
            sendLineOnQueue("OK")
            return true
        }

        guard authed else {
            sendLineOnQueue("ERR auth") { [weak self] in self?.closeOnQueue() }
            return false
        }

        switch cmd {
        case "SET-TZ":
            guard parts.count == 2 else {
                sendLineOnQueue("ERR zone")
                return true
            }
            switch timeZoneController.setTimeZone(parts[1]) {
            case .ok:
                sendLineOnQueue("OK")
            case .invalidZone, .noOriginal:
                sendLineOnQueue("ERR zone")
            case .setFailed:
                sendLineOnQueue("ERR set")
            }
            return true

        case "GET-TZ":
            sendLineOnQueue(timeZoneController.currentTimeZone())
            return true

        case "RESTORE":
            switch timeZoneController.restore() {
            case .ok:
                sendLineOnQueue("OK")
            case .noOriginal:
                sendLineOnQueue("ERR no-orig")
            case .invalidZone:
                sendLineOnQueue("ERR zone")
            case .setFailed:
                sendLineOnQueue("ERR set")
            }
            return true

        default:
            sendLineOnQueue("ERR cmd")
            return true
        }
    }

    private func sendLineOnQueue(_ text: String, completion: (@Sendable () -> Void)? = nil) {
        guard !closed else { return }
        pendingSends += 1
        connection.send(content: Data((text + "\n").utf8),
                        completion: .contentProcessed { [weak self] sendError in
            guard let self, !self.closed else { return }
            self.pendingSends = max(0, self.pendingSends - 1)
            completion?()
            if sendError != nil || (self.draining && self.pendingSends == 0) {
                self.closeOnQueue()
            }
        })
    }

    private func enterDrainingOnQueue() {
        guard !draining, !closed else { return }
        draining = true
        queue.asyncAfter(deadline: .now() + drainTimeout) { [weak self] in
            guard let self, !self.closed else { return }
            self.closeOnQueue()
        }
    }

    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        buffer.removeAll()
        connection.cancel()
        queue.async { [self] in
            registry.remove(self)
        }
    }
}
