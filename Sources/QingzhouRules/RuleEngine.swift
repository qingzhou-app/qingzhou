import Foundation
import QingzhouCore

/// GEOIP 解析接口。生产环境注入 maxmind / mmdb 实现；测试用 fake。
public protocol GeoIPResolver: Sendable {
    func countryCode(for ipAddress: String) -> String?
}

public struct NoopGeoIPResolver: GeoIPResolver {
    public init() {}
    public func countryCode(for ipAddress: String) -> String? { nil }
}

/// 匹配请求的上下文。
public struct MatchContext: Sendable {
    public let host: String           // 域名或 IP 字面量
    public let ipAddress: String?     // 已解析的 IP（若已解析）
    public let processName: String?   // macOS：发起请求的进程名
    public let userAgent: String?     // HTTP 请求的 UA

    public init(host: String, ipAddress: String? = nil, processName: String? = nil, userAgent: String? = nil) {
        self.host = host
        self.ipAddress = ipAddress
        self.processName = processName
        self.userAgent = userAgent
    }
}

public struct MatchResult: Sendable, Equatable {
    public let rule: Rule
    public let target: RuleTarget
}

/// 规则引擎：按顺序遍历规则列表，命中即返回；都不命中时走 FINAL（若有）。
public struct RuleEngine: Sendable {
    public let rules: [Rule]
    public let geoip: GeoIPResolver

    /// 预编译的 IPv4 CIDR，避免每次匹配重复解析。
    private let ipv4CIDRs: [(rule: Rule, cidr: CIDR.V4)]
    private let ipv6CIDRs: [(rule: Rule, cidr: CIDR.V6)]

    public init(rules: [Rule], geoip: GeoIPResolver = NoopGeoIPResolver()) {
        self.rules = rules
        self.geoip = geoip
        self.ipv4CIDRs = rules.compactMap { r in
            guard r.type == .ipCIDR, let cidr = CIDR.parseIPv4(r.value) else { return nil }
            return (r, cidr)
        }
        self.ipv6CIDRs = rules.compactMap { r in
            guard r.type == .ipCIDR6, let cidr = CIDR.parseIPv6(r.value) else { return nil }
            return (r, cidr)
        }
    }

    public func match(_ ctx: MatchContext) -> MatchResult {
        let hostLower = ctx.host.lowercased()
        let ipv4 = ctx.ipAddress.flatMap(CIDR.ipv4ToUInt32)
        let ipv6 = ctx.ipAddress.flatMap(CIDR.ipv6Components)

        for rule in rules {
            switch rule.type {
            case .domain:
                if hostLower == rule.value.lowercased() {
                    return MatchResult(rule: rule, target: rule.target)
                }
            case .domainSuffix:
                let suffix = rule.value.lowercased()
                if hostLower == suffix || hostLower.hasSuffix("." + suffix) {
                    return MatchResult(rule: rule, target: rule.target)
                }
            case .domainKeyword:
                if hostLower.contains(rule.value.lowercased()) {
                    return MatchResult(rule: rule, target: rule.target)
                }
            case .ipCIDR:
                if let v4 = ipv4,
                   let entry = ipv4CIDRs.first(where: { $0.rule.id == rule.id }),
                   entry.cidr.contains(v4) {
                    return MatchResult(rule: rule, target: rule.target)
                }
            case .ipCIDR6:
                if let (h, l) = ipv6,
                   let entry = ipv6CIDRs.first(where: { $0.rule.id == rule.id }),
                   entry.cidr.contains(high: h, low: l) {
                    return MatchResult(rule: rule, target: rule.target)
                }
            case .geoip:
                if let ip = ctx.ipAddress,
                   let cc = geoip.countryCode(for: ip),
                   cc.uppercased() == rule.value.uppercased() {
                    return MatchResult(rule: rule, target: rule.target)
                }
            case .processName:
                if let pn = ctx.processName, pn == rule.value {
                    return MatchResult(rule: rule, target: rule.target)
                }
            case .userAgent:
                if let ua = ctx.userAgent, ua.contains(rule.value) {
                    return MatchResult(rule: rule, target: rule.target)
                }
            case .geoSite:
                // 域名分类表只在 xray 侧（geosite.dat）存在，App 侧的规则模拟器没有这份数据。
                // 这里**不匹配**而不是猜：猜错会给用户"这条规则生效了"的错觉，而真实流量
                // 在 xray 里可能是另一条规则命中的。
                break
            case .final:
                return MatchResult(rule: rule, target: rule.target)
            }
        }
        // 没有任何 FINAL 兜底时，默认按 DIRECT 处理（保守策略）
        let fallback = Rule(type: .final, value: "", target: .direct)
        return MatchResult(rule: fallback, target: .direct)
    }

    /// 关键字 + 类型过滤搜索，用于 UI「查看当前生效规则」。
    public func search(keyword: String = "", type: RuleType? = nil) -> [Rule] {
        let kw = keyword.lowercased()
        return rules.filter { rule in
            let typeOK = type == nil || rule.type == type
            let kwOK = kw.isEmpty
                || rule.value.lowercased().contains(kw)
                || rule.target.rawValue.lowercased().contains(kw)
                || rule.type.rawValue.lowercased().contains(kw)
            return typeOK && kwOK
        }
    }
}
