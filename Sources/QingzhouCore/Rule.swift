import Foundation

/// 规则类型。覆盖主流分流规则（Surge / Shadowrocket / Clash 通用语义）。
public enum RuleType: String, Codable, Sendable, CaseIterable {
    case domain         = "DOMAIN"
    case domainSuffix   = "DOMAIN-SUFFIX"
    case domainKeyword  = "DOMAIN-KEYWORD"
    case ipCIDR         = "IP-CIDR"
    case ipCIDR6        = "IP-CIDR6"
    case geoip          = "GEOIP"
    /// geosite 分类（v2fly 域名库），例如 `GEOSITE,geolocation-!cn,PROXY`。
    /// 与 `GEOIP` 的区别：GEOIP 匹配**目标 IP**，GEOSITE 匹配**域名**（所以不需要解析，
    /// 也不受 fake-ip 影响）；与 `DOMAIN-SUFFIX` 的区别：一次引用几百条域名，且随
    /// geo 数据更新而更新，不必逐条维护。
    case geoSite        = "GEOSITE"
    case processName    = "PROCESS-NAME"
    case userAgent      = "USER-AGENT"
    case final          = "FINAL"
}

public enum RuleTarget: String, Codable, Sendable, CaseIterable {
    case proxy   = "PROXY"
    case direct  = "DIRECT"
    case reject  = "REJECT"
}

/// 单条规则。`FINAL` 类型的 `value` 通常为空。
public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var type: RuleType
    public var value: String
    public var target: RuleTarget
    public var comment: String?

    public init(
        id: UUID = UUID(),
        type: RuleType,
        value: String,
        target: RuleTarget,
        comment: String? = nil
    ) {
        self.id = id
        self.type = type
        self.value = value
        self.target = target
        self.comment = comment
    }

    /// 规则源文本形式，例如 `DOMAIN-SUFFIX,google.com,PROXY`。
    public var lineForm: String {
        if type == .final {
            return "\(type.rawValue),\(target.rawValue)"
        }
        return "\(type.rawValue),\(value),\(target.rawValue)"
    }
}
