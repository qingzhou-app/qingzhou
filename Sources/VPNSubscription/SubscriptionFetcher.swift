import Foundation
import VPNCore
import VPNLogging

/// 把网络请求抽成协议，单测里可以注入假实现避免真实出网。
public protocol HTTPClient: Sendable {
    func get(_ url: URL) async throws -> (Data, [String: String])
}

/// 默认 URLSession 实现。Header 字典 key 全部转小写以便大小写无关查询。
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

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
        var req = URLRequest(url: url)
        // 多数订阅源会根据 UA 切换返回格式；用一个被广泛接受的 UA
        req.setValue("ClashforWindows/0.20.39", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        var headers: [String: String] = [:]
        if let http = response as? HTTPURLResponse {
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
    private let client: HTTPClient
    private let logger: Logger?

    public init(client: HTTPClient = URLSessionHTTPClient(), logger: Logger? = nil) {
        self.client = client
        self.logger = logger
    }

    public func refresh(_ subscription: Subscription) async throws -> (updated: Subscription, payload: SubscriptionPayload) {
        logger?.info("Refreshing subscription \(subscription.name) (\(subscription.url))", category: "subscription")
        let (data, headers) = try await client.get(subscription.url)
        let body = String(data: data, encoding: .utf8) ?? ""
        let userInfoHeader = headers["subscription-userinfo"]
        let payload = SubscriptionParser.parse(body: body, userInfoHeader: userInfoHeader)
        logger?.info("Subscription \(subscription.name): parsed \(payload.nodes.count) nodes, \(payload.failedLines.count) failures", category: "subscription")

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
            userInfo: payload.userInfo
        )
        return (updated, taggedPayload)
    }
}
