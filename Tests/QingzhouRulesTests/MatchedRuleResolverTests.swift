import XCTest
import QingzhouCore
@testable import QingzhouRules

/// MatchedRuleResolver：从 access log 的「host + 实际路由」反推命中的规则文本。
///
/// 语义要点（诚实原则）：
/// - 用户规则（RuleEngine）只有在**判定与实际路由一致**时才认领 —— 用户规则目前并没有
///   注入 xray 路由，判定不一致时认领就是又一种假数据；
/// - 不一致 / 没命中时，按 proxyMode + 实际路由推断 xray 内置规则（geosite/geoip）；
/// - rule 模式下走了代理且无用户规则命中 = 只命中了兜底 catch-all → 「未命中（默认策略）」。
final class MatchedRuleResolverTests: XCTestCase {

    private func makeResolver(mode: ProxyMode, rules: [Rule] = []) -> MatchedRuleResolver {
        MatchedRuleResolver(rules: rules, mode: mode)
    }

    // MARK: - 用户规则认领（判定与实际路由一致才算）

    func testUserRuleClaimedWhenVerdictAgreesWithActualRoute() {
        let rule = Rule(type: .domainSuffix, value: "google.com", target: .proxy)
        let r = makeResolver(mode: .rule, rules: [rule])
        XCTAssertEqual(r.resolve(host: "www.google.com", route: .proxy),
                       "DOMAIN-SUFFIX,google.com,PROXY")
    }

    func testUserRuleNotClaimedWhenVerdictDisagrees() {
        // 用户规则说 PROXY，但 xray 实际走了直连（说明是内置 geosite:cn 之类命中的）
        let rule = Rule(type: .domainSuffix, value: "example.com", target: .proxy)
        let r = makeResolver(mode: .rule, rules: [rule])
        XCTAssertEqual(r.resolve(host: "www.example.com", route: .direct), "geosite:cn（内置国内域名直连）")
    }

    func testUserFinalRuleIsNeverClaimed() {
        // FINAL 是默认策略，不是「命中了某条规则」，即使 target 一致也不认领
        let rule = Rule(type: .final, value: "", target: .proxy)
        let r = makeResolver(mode: .rule, rules: [rule])
        XCTAssertEqual(r.resolve(host: "foo.example", route: .proxy), Connection.noMatchedRule)
    }

    // MARK: - rule 模式的内置规则推断

    func testRuleModeDirectDomainInfersGeositeCN() {
        let r = makeResolver(mode: .rule)
        XCTAssertEqual(r.resolve(host: "www.baidu.com", route: .direct), "geosite:cn（内置国内域名直连）")
    }

    func testRuleModeDirectPrivateIPInfersGeoipPrivate() {
        let r = makeResolver(mode: .rule)
        XCTAssertEqual(r.resolve(host: "192.168.1.10", route: .direct), "geoip:private（内置局域网直连）")
        XCTAssertEqual(r.resolve(host: "10.0.0.3", route: .direct), "geoip:private（内置局域网直连）")
        XCTAssertEqual(r.resolve(host: "::1", route: .direct), "geoip:private（内置局域网直连）")
    }

    func testRuleModeDirectPublicIPInfersGeoipCN() {
        let r = makeResolver(mode: .rule)
        XCTAssertEqual(r.resolve(host: "223.5.5.5", route: .direct), "geoip:cn（内置国内 IP 直连）")
    }

    func testRuleModeRejectInfersAdsGeosite() {
        let r = makeResolver(mode: .rule)
        XCTAssertEqual(r.resolve(host: "ads.example.com", route: .reject),
                       "geosite:category-ads-all（内置广告拦截）")
    }

    func testRuleModeProxyWithoutUserRuleIsUnmatchedSentinel() {
        let r = makeResolver(mode: .rule)
        XCTAssertEqual(r.resolve(host: "www.github.com", route: .proxy), Connection.noMatchedRule)
    }

    // MARK: - global / direct 模式（没有分流规则，明说模式而不是留空）

    func testGlobalModeProxy() {
        let r = makeResolver(mode: .global)
        XCTAssertEqual(r.resolve(host: "www.github.com", route: .proxy), "全局模式（GLOBAL）")
    }

    func testGlobalModeDirectIsBuiltinLAN() {
        // global 模式唯一的直连是内置局域网 CIDR 段
        let r = makeResolver(mode: .global)
        XCTAssertEqual(r.resolve(host: "192.168.1.1", route: .direct), "局域网直连（内置）")
    }

    func testDirectMode() {
        let r = makeResolver(mode: .direct)
        XCTAssertEqual(r.resolve(host: "www.github.com", route: .direct), "直连模式（DIRECT）")
    }

    // MARK: - 缓存

    func testCacheIsBoundedAndHit() {
        let r = MatchedRuleResolver(rules: [], mode: .rule, cacheLimit: 2)
        _ = r.resolve(host: "a.example", route: .proxy)
        XCTAssertEqual(r.cacheCountForTesting, 1)
        _ = r.resolve(host: "a.example", route: .proxy)   // 命中缓存，不新增
        XCTAssertEqual(r.cacheCountForTesting, 1)
        _ = r.resolve(host: "b.example", route: .proxy)
        _ = r.resolve(host: "c.example", route: .proxy)   // 超上限触发清理
        XCTAssertLessThanOrEqual(r.cacheCountForTesting, 2)
        // 清理后仍能正确解析
        XCTAssertEqual(r.resolve(host: "a.example", route: .proxy), Connection.noMatchedRule)
    }
}
