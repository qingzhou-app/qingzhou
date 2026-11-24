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
    /// Surge / Clash 风格的 `,no-resolve` 标记（IP / GEOIP 规则不触发前置 DNS 解析）。
    public var noResolve: Bool

    enum CodingKeys: String, CodingKey {
        case id, type, value, target, comment, noResolve
    }

    public init(
        id: UUID = UUID(),
        type: RuleType,
        value: String,
        target: RuleTarget,
        comment: String? = nil,
        noResolve: Bool = false
    ) {
        self.id = id
        self.type = type
        self.value = value
        self.target = target
        self.comment = comment
        self.noResolve = noResolve
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.type = try c.decode(RuleType.self, forKey: .type)
        self.value = try c.decode(String.self, forKey: .value)
        self.target = try c.decode(RuleTarget.self, forKey: .target)
        self.comment = try c.decodeIfPresent(String.self, forKey: .comment)
        self.noResolve = try c.decodeIfPresent(Bool.self, forKey: .noResolve) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(value, forKey: .value)
        try c.encode(target, forKey: .target)
        try c.encodeIfPresent(comment, forKey: .comment)
        try c.encode(noResolve, forKey: .noResolve)
    }

    /// 规则源文本形式，例如 `DOMAIN-SUFFIX,google.com,PROXY` 或 `IP-CIDR,10.0.0.0/8,DIRECT,no-resolve`。
    public var lineForm: String {
        if type == .final {
            return "\(type.rawValue),\(target.rawValue)"
        }
        let base = "\(type.rawValue),\(value),\(target.rawValue)"
        return noResolve ? "\(base),no-resolve" : base
    }
}
