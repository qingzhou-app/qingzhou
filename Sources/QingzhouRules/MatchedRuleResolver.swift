import Foundation
import QingzhouCore

/// 从 access log 的「host + 实际路由结果」反推这条连接命中了哪条规则，回填
/// `Connection.matchedRule`（access log 本身不含规则信息）。
///
/// 诚实原则（避免制造新的假数据）：
/// 1. **用户规则**（customRules + remoteRules，经 RuleEngine）目前并没有注入 xray 的
///    routing —— 只有当规则判定与实际路由**一致**时才认领该规则文本；不一致时认领
///    就是在撒谎（实际是 xray 内置规则决定的）。
/// 2. 用户规则解释不了时，按 proxyMode + 实际路由推断 **xray 内置规则**
///    （见 XrayConfigComposer.buildRouting）：rule 模式的直连是 geoip:private /
///    geoip:cn / geosite:cn，拒绝是 geosite:category-ads-all。
/// 3. rule 模式下走了代理且用户规则也没命中 = 只命中兜底 catch-all →
///    `Connection.noMatchedRule`（「未命中（默认策略）」）。
///
/// 性能：主 App 每 2 秒批量摄入 access log，同批常有大量重复 host —— 内置一层
/// host+route → 结果 的缓存，超上限整体清空（简单粗暴但足够：重建成本只是一次
/// 规则遍历，且浏览场景下热点 host 会立刻回填进缓存）。
/// 规则集 / proxyMode 变化时由持有方（AppState）换一个新实例，缓存随之作废。
public final class MatchedRuleResolver {

    private let engine: RuleEngine
    private let mode: ProxyMode
    private let cacheLimit: Int
    private var cache: [String: String] = [:]

    public init(rules: [Rule], mode: ProxyMode,
                geoip: GeoIPResolver = NoopGeoIPResolver(), cacheLimit: Int = 4096) {
        self.engine = RuleEngine(rules: rules, geoip: geoip)
        self.mode = mode
        self.cacheLimit = max(1, cacheLimit)
    }

    /// 当前缓存条数，仅测试用（验证命中与上限清理）。
    public var cacheCountForTesting: Int { cache.count }

    /// - Parameters:
    ///   - host: 目标域名或 IP（FakeDNS 假 IP 应先翻译回域名再传入）。
    ///   - route: 实际路由结果（由 access log 的 outboundTag 归类，见 `DomainAnalyzer.routeCategory`）。
    public func resolve(host: String, route: DomainRoute) -> String {
        let key = "\(host)|\(route.rawValue)"
        if let hit = cache[key] { return hit }
        let result = compute(host: host, route: route)
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        return result
    }

    // MARK: - 私有

    private func compute(host: String, route: DomainRoute) -> String {
        // 1) 用户规则：命中了非 FINAL 规则、且判定与实际路由一致 → 认领
        let match = engine.match(MatchContext(host: host))
        if match.rule.type != .final, Self.agrees(match.rule.target, route) {
            return match.rule.lineForm
        }

        // 2) xray 内置规则推断（与 XrayConfigComposer.buildRouting 一一对应）
        switch mode {
        case .direct:
            return "直连模式（DIRECT）"
        case .global:
            // global 模式唯一的直连是内置局域网 CIDR；其余全走代理
            return route == .direct ? "局域网直连（内置）" : "全局模式（GLOBAL）"
        case .rule:
            switch route {
            case .reject:
                return "geosite:category-ads-all"
            case .direct:
                if Self.isPrivateHost(host) { return "geoip:private" }
                return Self.isIPLiteral(host) ? "geoip:cn" : "geosite:cn"
            case .proxy, .mixed:
                // 只命中了「其余走代理」的兜底 → 明确的「未命中」语义值，不是空串
                return Connection.noMatchedRule
            }
        }
    }

    private static func agrees(_ target: RuleTarget, _ route: DomainRoute) -> Bool {
        switch (target, route) {
        case (.proxy, .proxy), (.direct, .direct), (.reject, .reject): return true
        default: return false
        }
    }

    private static let privateV4: [CIDR.V4] = [
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16"
    ].compactMap(CIDR.parseIPv4)

    private static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        if let v4 = CIDR.ipv4ToUInt32(host) {
            return privateV4.contains { $0.contains(v4) }
        }
        // IPv6 判定前先确认真是 IPv6（含冒号）——否则 "fcbarcelona.com" 这类域名会被误判
        let h = host.lowercased()
        guard h.contains(":") else { return false }
        return h == "::1" || h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd")
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        CIDR.ipv4ToUInt32(host) != nil || host.contains(":")   // 域名此时已不含端口，带冒号即 IPv6
    }
}
