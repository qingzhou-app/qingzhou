import Foundation
import QingzhouCore
import QingzhouProtocols

/// 一个订阅响应解析后的结果。
public struct SubscriptionPayload: Sendable {
    public var nodes: [Node]
    public var failedLines: [(line: String, error: Error)]
    public var userInfo: SubscriptionUserInfo?
    /// 订阅原文是否被识别为**某种已知格式**（Clash YAML / SIP008 JSON / base64 或明文分享链接列表）。
    ///
    /// 用来区分两种「0 节点」：
    /// - `formatRecognized == true` 且 `nodes` 为空 → 订阅**确实为空**（如 Clash `proxies: []`、SIP008 `servers: []`）；
    /// - `formatRecognized == false` 且 `nodes` 为空 → 原文**格式无法识别**（既不是上述任一格式、也不含 `://`），
    ///   多半是链接填错 / 返回了 HTML 登录页等，消费侧应给醒目提示而非静默空列表。
    public var formatRecognized: Bool

    public init(
        nodes: [Node],
        failedLines: [(line: String, error: Error)] = [],
        userInfo: SubscriptionUserInfo? = nil,
        formatRecognized: Bool = true
    ) {
        self.nodes = nodes
        self.failedLines = failedLines
        self.userInfo = userInfo
        self.formatRecognized = formatRecognized
    }
}

/// HTTP 响应头 `Subscription-Userinfo` 的解析结果。
///
/// 格式：`upload=N; download=N; total=N; expire=UNIXTIME`，分号或逗号分隔，字段都可能缺失。
public struct SubscriptionUserInfo: Sendable, Equatable {
    public var upload: Int64?
    public var download: Int64?
    public var total: Int64?
    public var expire: Date?

    public init(upload: Int64? = nil, download: Int64? = nil, total: Int64? = nil, expire: Date? = nil) {
        self.upload = upload
        self.download = download
        self.total = total
        self.expire = expire
    }

    public var usedBytes: Int64? {
        switch (upload, download) {
        case let (.some(u), .some(d)): return u + d
        case let (.some(u), .none):    return u
        case let (.none, .some(d)):    return d
        case (.none, .none):           return nil
        }
    }

    public static func parse(_ header: String) -> SubscriptionUserInfo {
        var info = SubscriptionUserInfo()
        let parts = header.split(whereSeparator: { $0 == ";" || $0 == "," })
        for part in parts {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            let key = kv[0].lowercased()
            let value = kv[1]
            switch key {
            case "upload":
                info.upload = Int64(value)
            case "download":
                info.download = Int64(value)
            case "total":
                info.total = Int64(value)
            case "expire":
                if let ts = TimeInterval(value), ts > 0 {
                    info.expire = Date(timeIntervalSince1970: ts)
                }
            default:
                break
            }
        }
        return info
    }
}
