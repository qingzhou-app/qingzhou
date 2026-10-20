import Foundation
import Network

/// TCP 尝试失败不等于代理不可用；解析/接口/取消连尝试结果都不能作为节点质量样本。
public enum DirectProbeFailure: String, Sendable, Equatable, Error {
    case invalidEndpoint, noPhysicalInterface, dnsFailed, syntheticAddress, timeout, refused, networkUnavailable, cancelled, connectionFailed
    public var isNodeObservation: Bool {
        switch self {
        case .timeout, .refused, .connectionFailed: return true
        default: return false
        }
    }
}

public struct LatencyResult: Sendable, Equatable {
    public let url: URL
    public let latencyMs: Int?     // nil 表示失败
    public let errorDescription: String?
    /// 丢包率（0–1）：仅节点 burst 探测的聚合结果携带（`NodeSelector.measure`，
    /// 失败次数/burst 次数）；单次探测、网站测速为 nil。
    public let lossFraction: Double?
    public let failure: DirectProbeFailure?
    public var isNodeObservation: Bool { failure?.isNodeObservation ?? true }

    public init(url: URL, latencyMs: Int?, errorDescription: String? = nil, lossFraction: Double? = nil, failure: DirectProbeFailure? = nil) {
        self.url = url
        self.latencyMs = latencyMs
        self.errorDescription = errorDescription
        self.lossFraction = lossFraction
        self.failure = failure
    }
}

/// 抽象延迟探针，便于单测注入假实现。
public protocol LatencyProber: Sendable {
    func probe(_ url: URL, timeout: TimeInterval) async -> LatencyResult
}

/// 默认实现：用 `NWConnection` 直接做 TCP 三次握手，测 host:port 的 RTT。
///
/// 比起 URLSession HEAD：
/// - 不做 TLS handshake、不发 HTTP 请求 —— 对 trojan/vmess/ss/vless 这类非 HTTP 服务来说，
///   TLS+HTTP 那部分都是噪声，TCP 握手时间才是真实可用延迟的近似值
/// - 单次探针开销小一个数量级，不易被 URLSession 的 per-host 连接池排队
public struct TCPConnectLatencyProber: LatencyProber {
    public init() {}

    public func probe(_ url: URL, timeout: TimeInterval = 5) async -> LatencyResult {
        guard !Task.isCancelled else { return .init(url: url, latencyMs: nil, failure: .cancelled) }
        guard let host = url.host(percentEncoded: false), !host.isEmpty,
              let rawPort = url.port, (1...65535).contains(rawPort),
              let port = NWEndpoint.Port(rawValue: UInt16(rawPort)) else {
            return .init(url: url, latencyMs: nil, failure: .invalidEndpoint)
        }
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !DirectDNSResolver.isSynthetic(normalizedHost) else {
            return .init(url: url, latencyMs: nil, failure: .syntheticAddress)
        }
        // 没有物理接口时不允许无绑定回退：经 VPN 的假 RTT 不能用于直连排名。
        guard let iface = await DirectInterfaceResolver.shared.currentPhysicalInterface() else {
            return .init(url: url, latencyMs: nil, failure: .noPhysicalInterface)
        }
        let started = Date()
        let resolved = await DirectDNSResolver().resolve(normalizedHost, interfaceIndex: UInt32(iface.index), timeout: timeout)
        guard !Task.isCancelled else { return .init(url: url, latencyMs: nil, failure: .cancelled) }
        switch resolved {
        case .failure(let failure): return .init(url: url, latencyMs: nil, failure: failure)
        case .success(let addresses):
            let remaining = timeout - Date().timeIntervalSince(started)
            guard remaining > 0 else { return .init(url: url, latencyMs: nil, failure: .dnsFailed) }
            let parameters = NWParameters.tcp
            parameters.requiredInterface = iface
            return await Self.connectAddresses(addresses, url: url, timeout: remaining) { address, budget in
                await Self.tcpConnect(host: address, port: port, url: url, timeout: budget, parameters: parameters)
            }
        }
    }

    /// 同一解析批次最多四个地址，分享总预算，首地址失败仍可尝试备选。
    static func connectAddresses(_ addresses: [String], url: URL, timeout: TimeInterval,
        attempt: (String, TimeInterval) async -> LatencyResult) async -> LatencyResult {
        let start = ContinuousClock.now
        let candidates = Array(addresses.prefix(4))
        var last = LatencyResult(url: url, latencyMs: nil, failure: .dnsFailed)
        for (index, address) in candidates.enumerated() {
            guard !Task.isCancelled else { return .init(url: url, latencyMs: nil, failure: .cancelled) }
            let elapsed = start.duration(to: .now).components
            let remaining = timeout - Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18
            guard remaining > 0 else { break }
            let budget = remaining / Double(candidates.count - index)
            last = await attempt(address, budget)
            if last.latencyMs != nil || !last.isNodeObservation { return last }
        }
        return last
    }

    /// NWConnection 异步 + completion 风格的 callback —— 包成 async：用一个 box 守 didResume 避免
    /// 双 resume（连接 ready / failed / timeout 三路都可能触发 cont.resume）。
    /// 所有 callback 都在同一个 dispatch queue 上跑，串行执行，不需要额外加锁。
    /// `parameters` 决定走哪个网络接口 —— 传入禁掉 VPN 的参数即可绕过 utun 直连。
    private static func tcpConnect(
        host: String,
        port: NWEndpoint.Port,
        url: URL,
        timeout: TimeInterval,
        parameters: NWParameters
    ) async -> LatencyResult {
        let connection = TCPProbeConnection(host: host, port: port, parameters: parameters, url: url)
        return await connection.run(timeout: timeout)
    }
}

/// 串行队列统一处理完成、超时和任务取消，及时关闭 socket，最多恢复一次 continuation。
private final class TCPProbeConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let url: URL
    private let queue = DispatchQueue(label: "qingzhou.tcp-probe")
    private var continuation: CheckedContinuation<LatencyResult, Never>?
    private var finished: LatencyResult?
    init(host: String, port: NWEndpoint.Port, parameters: NWParameters, url: URL) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        self.url = url
    }
    func run(timeout: TimeInterval) async -> LatencyResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    if let finished = self.finished { continuation.resume(returning: finished); return }
                    self.continuation = continuation
                    let start = DispatchTime.now()
                    self.connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            let elapsed = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
                            self.finish(.init(url: self.url, latencyMs: Int(elapsed / 1_000_000)))
                        case .failed(let error), .waiting(let error):
                            let failure: DirectProbeFailure
                            switch error {
                            case .posix(.ECONNREFUSED): failure = .refused
                            case .posix(.ENETDOWN), .posix(.ENETUNREACH), .posix(.EHOSTUNREACH): failure = .networkUnavailable
                            case .dns: failure = .dnsFailed
                            default: failure = .connectionFailed
                            }
                            self.finish(.init(url: self.url, latencyMs: nil, failure: failure))
                        default: break
                        }
                    }
                    self.queue.asyncAfter(deadline: .now() + max(0.01, timeout)) {
                        self.finish(.init(url: self.url, latencyMs: nil, failure: .timeout))
                    }
                    self.connection.start(queue: self.queue)
                }
            }
        } onCancel: {
            self.queue.async { self.finish(.init(url: self.url, latencyMs: nil, failure: .cancelled)) }
        }
    }
    private func finish(_ result: LatencyResult) {
        guard finished == nil else { return }
        finished = result
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// 保留 URLSession 版本：留给单测注入，或将来接入代理后通过代理 session 走端到端探测。
public struct URLSessionLatencyProber: LatencyProber {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 10
            cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: cfg)
        }
    }

    public func probe(_ url: URL, timeout: TimeInterval = 5) async -> LatencyResult {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let start = DispatchTime.now()
        do {
            let (_, _) = try await session.data(for: req)
            let elapsed = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
            return LatencyResult(url: url, latencyMs: Int(elapsed / 1_000_000))
        } catch {
            return LatencyResult(url: url, latencyMs: nil, errorDescription: error.localizedDescription)
        }
    }
}
