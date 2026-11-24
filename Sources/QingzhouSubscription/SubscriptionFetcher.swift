import Foundation
import QingzhouCore
import QingzhouLogging

public enum SubscriptionRefreshError: LocalizedError {
    case httpStatus(Int)
    case unrecognizedFormat
    case noSupportedNodes

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "订阅服务器返回 HTTP \(code)，已保留原有节点"
        case .unrecognizedFormat: return "订阅格式无法识别，请确认链接正确（能否在浏览器里直接打开）"
        case .noSupportedNodes: return "订阅中的节点均无法解析或暂不支持，已保留原有节点"
        }
    }
}

/// 把网络请求抽成协议，单测里可以注入假实现避免真实出网。
public protocol HTTPClient: Sendable {
    func get(_ url: URL) async throws -> (Data, [String: String])
    /// 带 UA 的请求。机场订阅常按 User-Agent 下发不同内容，订阅刷新必须能指定 UA。
    func get(_ url: URL, userAgent: String) async throws -> (Data, [String: String])
}

public extension HTTPClient {
    /// 兼容旧实现（旧 mock / 其他调用方）：忽略 UA，沿用 `get(_:)`。
    func get(_ url: URL, userAgent: String) async throws -> (Data, [String: String]) {
        try await get(url)
    }
}

/// 默认 URLSession 实现。Header 字典 key 全部转小写以便大小写无关查询。
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    /// 其他复用本 client 的服务（规则拉取、版本检查）保持历史 UA，避免无关行为变化。
    public static let legacyUserAgent = "ClashforWindows/0.20.39"

    /// 默认 session 必须设超时。
    /// `URLSession.shared` 的 `timeoutIntervalForResource` 默认是 **7 天** ——
    /// 订阅源连不通时（没开 VPN / 被墙 / DNS 不通），请求不会失败而是挂起到地老天荒，
    /// 表现为「刷新」按钮永远转圈、整个订阅区像卡死。这里强制一个合理超时：
    /// 单次请求 20s 无响应、整体 30s 没拿完就报错，让 UI 能恢复并显示错误。
    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 20
            cfg.timeoutIntervalForResource = 30
            cfg.waitsForConnectivity = false
            cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: cfg)
        }
    }

    public func get(_ url: URL) async throws -> (Data, [String: String]) {
        try await get(url, userAgent: Self.legacyUserAgent)
    }

    public func get(_ url: URL, userAgent: String) async throws -> (Data, [String: String]) {
        var req = URLRequest(url: url)
        // 订阅源按 UA 切换返回格式：UA 由调用方决定，见 SubscriptionFetcher.userAgentCandidates。
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        var headers: [String: String] = [:]
        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                throw SubscriptionRefreshError.httpStatus(http.statusCode)
            }
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String {
                    headers[k.lowercased()] = v
                }
            }
        }
        return (data, headers)
    }
}

/// 高层订阅刷新 API。把 fetch + parse 串成一个调用，并写日志。
public actor SubscriptionFetcher {
    /// 机场常按 User-Agent 下发完全不同的订阅内容：同一 URL，ClashforWindows UA 只给 4 条
    /// 占位节点，Clash Verge UA 给完整 38 条地区节点，浏览器 UA 给 base64 全量链接。
    /// 优先尝试能拿到丰富结果的 UA；只有一个候选成功但节点数可疑地少时，再试下一个。
    public static let userAgentCandidates: [String] = [
        "Clash Verge/2.0.0",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        "ClashforWindows/0.20.39"
    ]

    private let client: HTTPClient
    private let logger: Logger?

    public init(client: HTTPClient = URLSessionHTTPClient(), logger: Logger? = nil) {
        self.client = client
        self.logger = logger
    }

    public func refresh(_ subscription: Subscription) async throws -> (updated: Subscription, payload: SubscriptionPayload) {
        logger?.info("Refreshing subscription \(subscription.name) (\(subscription.url))", category: "subscription")
        var best: (updated: Subscription, payload: SubscriptionPayload)?
        var lastError: Error?

        for ua in Self.userAgentCandidates {
            do {
                let (data, headers) = try await client.get(subscription.url, userAgent: ua)
                let body = String(data: data, encoding: .utf8) ?? ""
                let userInfoHeader = headers["subscription-userinfo"]
                let payload = SubscriptionParser.parse(body: body, userInfoHeader: userInfoHeader)
                guard payload.formatRecognized else {
                    lastError = SubscriptionRefreshError.unrecognizedFormat
                    continue
                }
                guard !payload.nodes.isEmpty || payload.failedLines.isEmpty else {
                    lastError = SubscriptionRefreshError.noSupportedNodes
                    continue
                }
                let result = decorate(subscription, with: payload)
                logger?.info("Subscription \(subscription.name) [UA \(ua)]: parsed \(payload.nodes.count) nodes, \(payload.failedLines.count) failures", category: "subscription")
                // 多节点结果就是我们要的；只有 0/1 条时才继续试其他 UA（真·单节点订阅会走完候选）。
                if payload.nodes.count > 1 { return result }
                if best == nil || payload.nodes.count > best!.payload.nodes.count { best = result }
            } catch {
                lastError = error
            }
        }

        if let best { return best }
        throw lastError ?? SubscriptionRefreshError.unrecognizedFormat
    }

    private func decorate(
        _ subscription: Subscription,
        with payload: SubscriptionPayload
    ) -> (updated: Subscription, payload: SubscriptionPayload) {
        var updated = subscription
        updated.lastUpdatedAt = Date()
        updated.nodeCount = payload.nodes.count
        if let info = payload.userInfo {
            updated.usedBytes = info.usedBytes
            updated.totalBytes = info.total
            updated.expiresAt = info.expire
        }
        // 给节点打上订阅 id，方便后续按订阅维度管理
        var taggedNodes = payload.nodes
        for i in taggedNodes.indices { taggedNodes[i].subscriptionId = updated.id }
        let taggedPayload = SubscriptionPayload(
            nodes: taggedNodes,
            failedLines: payload.failedLines,
            userInfo: payload.userInfo,
            formatRecognized: payload.formatRecognized
        )
        return (updated, taggedPayload)
    }
}
