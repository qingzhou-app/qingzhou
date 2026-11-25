import Foundation

/// 分流方案自定义策略组的路由目标。
public enum SplitExitPolicyTarget: String, Codable, Sendable, CaseIterable, Equatable {
    case exit
    case direct
    case reject
}

/// 分流方案通用自定义策略组（按配置顺序 first-match，优先于保留网段、geolocation-!cn 与国内名单）。
///
/// 用于替代硬编码的站点/服务分流规则，用户或测试可按任意域名后缀、精确域名、关键字、
/// 内置 geosite 分类或 CIDR 网段组合定义 `.exit` / `.direct` / `.reject` 策略组。
public struct SplitExitPolicyGroup: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var target: SplitExitPolicyTarget
    public var domains: [String]
    public var fullDomains: [String]
    public var keywords: [String]
    public var geoSites: [String]
    public var cidrs: [String]
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        target: SplitExitPolicyTarget,
        domains: [String] = [],
        fullDomains: [String] = [],
        keywords: [String] = [],
        geoSites: [String] = [],
        cidrs: [String] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.target = target
        self.domains = domains
        self.fullDomains = fullDomains
        self.keywords = keywords
        self.geoSites = geoSites
        self.cidrs = cidrs
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id, name, target, domains, fullDomains, keywords, geoSites, cidrs, isEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        target = try c.decode(SplitExitPolicyTarget.self, forKey: .target)
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        fullDomains = try c.decodeIfPresent([String].self, forKey: .fullDomains) ?? []
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        geoSites = try c.decodeIfPresent([String].self, forKey: .geoSites) ?? []
        cidrs = try c.decodeIfPresent([String].self, forKey: .cidrs) ?? []
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}
