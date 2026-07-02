import Foundation
import Network

public struct LatencyResult: Sendable, Equatable {
    public let url: URL
    public let latencyMs: Int?     // nil 表示失败
    public let errorDescription: String?

    public init(url: URL, latencyMs: Int?, errorDescription: String? = nil) {
        self.url = url
        self.latencyMs = latencyMs
        self.errorDescription = errorDescription
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
        guard let host = url.host, !host.isEmpty,
              let rawPort = url.port,
              (1...65535).contains(rawPort),
              let port = NWEndpoint.Port(rawValue: UInt16(rawPort))
        else {
            return LatencyResult(url: url, latencyMs: nil, errorDescription: "invalid host:port")
        }
        // VPN 开启时强制直连：反向**主动绑定**当前物理接口（requiredInterface），
        // 让探测流量绕开 utun，测到的是真实直连 RTT 而不是"建隧道+经节点绕一圈"的假延迟。
        //
        // ⚠️ 历史教训：曾用 NWParameters.prohibitedInterfaceTypes=[.other] 反向排除 utun，
        // 但 iPhone USB 共享等场景下**唯一物理网卡的类型也是 .other** → 探针全部超时。
        // 所以选择逻辑（PhysicalInterfacePicker）按名字识别 utun 等虚拟接口、
        // 且**找不到合适物理接口时回退无绑定** —— 宁可测到假延迟，也不能全超时。
        let parameters = NWParameters.tcp
        if let iface = await DirectInterfaceResolver.shared.currentPhysicalInterface() {
            parameters.requiredInterface = iface
        }
        return await Self.tcpConnect(host: host, port: port, url: url, timeout: timeout, parameters: parameters)
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
        final class Box: @unchecked Sendable { var done = false }
        let box = Box()

        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let queue = DispatchQueue(label: "vpn.tcp-probe", qos: .userInitiated)
        let start = DispatchTime.now()

        return await withCheckedContinuation { (cont: CheckedContinuation<LatencyResult, Never>) in
            queue.asyncAfter(deadline: .now() + timeout) {
                guard !box.done else { return }
                box.done = true
                conn.cancel()
                cont.resume(returning: LatencyResult(url: url, latencyMs: nil, errorDescription: "timeout"))
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !box.done else { return }
                    box.done = true
                    let elapsedNs = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
                    conn.cancel()
                    cont.resume(returning: LatencyResult(url: url, latencyMs: Int(elapsedNs / 1_000_000)))
                case .failed(let err):
                    guard !box.done else { return }
                    box.done = true
                    conn.cancel()
                    cont.resume(returning: LatencyResult(url: url, latencyMs: nil, errorDescription: "\(err)"))
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
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
