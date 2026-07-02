import XCTest
import QingzhouCore
@testable import XrayConfig

/// 用户规则 → xray routing rule 的转换。核心保障：
/// 1) 各类型字段语义正确（full:/domain:/裸串/CIDR/geoip:）
/// 2) 保序 + 相邻同类合并（不跨段合并 —— 那会破坏 first-match）
/// 3) 畸形 / 不支持的规则跳过而不是抛错（一条坏规则不能让 xray 起不来）
final class RoutingRuleConverterTests: XCTestCase {

    // MARK: - 各类型映射

    func testDomainMapsToFullPrefix() {
        let out = RoutingRuleConverter.xrayRules(from: [
            Rule(type: .domain, value: "www.Example.com", target: .proxy)
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0]["domain"] as? [String], ["full:www.example.com"], "DOMAIN = 完全匹配 → full: 前缀，且小写化")
        XCTAssertEqual(out[0]["outboundTag"] as? String, "proxy")
        XCTAssertEqual(out[0]["type"] as? String, "field")
    }

    func testDomainSuffixMapsToDomainPrefix() {
        let out = RoutingRuleConverter.xrayRules(from: [
            Rule(type: .domainSuffix, value: "example.com", target: .reject)
        ])
        XCTAssertEqual(out[0]["domain"] as? [String], ["domain:example.com"],
                       "DOMAIN-SUFFIX → domain: 前缀（匹配本域 + 子域）")
        XCTAssertEqual(out[0]["outboundTag"] as? String, "reject")
    }

    func testDomainKeywordMapsToPlainSubstring() {
        let out = RoutingRuleConverter.xrayRules(from: [
            Rule(type: .domainKeyword, value: "google", target: .proxy)
        ])
        XCTAssertEqual(out[0]["domain"] as? [String], ["google"], "KEYWORD → 裸串（xray 裸串就是子串匹配）")
    }

    func testIPCIDRMapsToIPArray() {
        let out = RoutingRuleConverter.xrayRules(from: [
            Rule(type: .ipCIDR, value: "10.0.0.0/8", target: .direct)
        ])
        XCTAssertEqual(out[0]["ip"] as? [String], ["10.0.0.0/8"])
        XCTAssertNil(out[0]["domain"], "IP 规则不能有 domain 字段")
        XCTAssertEqual(out[0]["outboundTag"] as? String, "direct")
    }

    func testIPCIDR6MapsToIPArray() {
        let out = RoutingRuleConverter.xrayRules(from: [
            Rule(type: .ipCIDR6, value: "2001:db8::/32", target: .proxy)
        ])
        XCTAssertEqual(out[0]["ip"] as? [String], ["2001:db8::/32"])
    }

    func testBareIPWithoutPrefixAccepted() {
        let out = RoutingRuleConverter.xrayRules(from: [
            Rule(type: .ipCIDR, value: "8.8.8.8", target: .direct)
        ])
        XCTAssertEqual(out[0]["ip"] as? [String], ["8.8.8.8"], "xray 的 ip 数组接受单 IP")
    }

    func testGeoIPMapsToGeoipPrefix() {
        let out = RoutingRuleConverter.xrayRules(from: [
            Rule(type: .geoip, value: "CN", target: .direct)
        ])
        XCTAssertEqual(out[0]["ip"] as? [String], ["geoip:cn"], "GEOIP → geoip: 前缀且小写")
    }

    func testGeoIPOutsideBundledDataSkipped() {
        // 内置 geoip.dat 是精简版（only-cn-private）。缺失分类必须跳过 ——
        // xray 对 routing 规则里找不到的 geoip 分类直接启动失败，
        // 一条 GEOIP,us 规则透传过去就是"VPN 连不上"级别的事故。
        let out = RoutingRuleConverter.xrayRules(from: [
            Rule(type: .geoip, value: "us", target: .proxy),
            Rule(type: .geoip, value: "JP", target: .direct)
        ])
        XCTAssertTrue(out.isEmpty, "非 cn/private 的 GEOIP 规则在精简 geo 数据下必须整条跳过")
    }

    func testGeoIPPrivateStillSupported() {
        let out = RoutingRuleConverter.xrayRules(from: [
            Rule(type: .geoip, value: "private", target: .direct)
        ])
        XCTAssertEqual(out[0]["ip"] as? [String], ["geoip:private"])
    }

    // MARK: - 保序合并

    func testConsecutiveSameTargetDomainRulesMergeIntoOne() {
        let out = RoutingRuleConverter.xrayRules(from: [
            Rule(type: .domainSuffix, value: "a.com", target: .proxy),
            Rule(type: .domain, value: "b.com", target: .proxy),
            Rule(type: .domainKeyword, value: "cdn", target: .proxy)
        ])
        XCTAssertEqual(out.count, 1, "相邻同目标的 domain 类规则应合并成一条")
        XCTAssertEqual(out[0]["domain"] as? [String], ["domain:a.com", "full:b.com", "cdn"])
    }

    func testDomainAndIPDoNotMerge() {
        let out = RoutingRuleConverter.xrayRules(from: [
            Rule(type: .domainSuffix, value: "a.com", target: .proxy),
            Rule(type: .ipCIDR, value: "1.2.3.0/24", target: .proxy)
        ])
        XCTAssertEqual(out.count, 2, "domain 和 ip 字段种类不同，即使同目标也不合并")
    }

    func testInterleavedTargetsPreserveOrderAndDoNotMergeAcross() {
        // a.com→PROXY, b.com→REJECT, c.com→PROXY：
        // 如果跨段把 c.com 并进第一条 PROXY，规则顺序语义就错了
        let out = RoutingRuleConverter.xrayRules(from: [
            Rule(type: .domainSuffix, value: "a.com", target: .proxy),
            Rule(type: .domainSuffix, value: "b.com", target: .reject),
            Rule(type: .domainSuffix, value: "c.com", target: .proxy)
        ])
        XCTAssertEqual(out.count, 3, "跨段合并会破坏 first-match 语义，必须保持 3 条")
        XCTAssertEqual(out[0]["outboundTag"] as? String, "proxy")
        XCTAssertEqual(out[1]["outboundTag"] as? String, "reject")
        XCTAssertEqual(out[2]["outboundTag"] as? String, "proxy")
        XCTAssertEqual(out[0]["domain"] as? [String], ["domain:a.com"])
        XCTAssertEqual(out[1]["domain"] as? [String], ["domain:b.com"])
        XCTAssertEqual(out[2]["domain"] as? [String], ["domain:c.com"])
    }

    func testDuplicateEntryWithinGroupDeduplicated() {
        let out = RoutingRuleConverter.xrayRules(from: [
            Rule(type: .domainSuffix, value: "a.com", target: .proxy),
            Rule(type: .domainSuffix, value: "a.com", target: .proxy)
        ])
        XCTAssertEqual(out[0]["domain"] as? [String], ["domain:a.com"], "同段内完全重复的条目去重")
    }

    // MARK: - 跳过不支持 / 畸形

    func testUnsupportedTypesSkipped() {
        let out = RoutingRuleConverter.xrayRules(from: [
            Rule(type: .processName, value: "Telegram", target: .proxy),
            Rule(type: .userAgent, value: "Safari*", target: .direct),
            Rule(type: .final, value: "", target: .direct)
        ])
        XCTAssertTrue(out.isEmpty, "PROCESS-NAME / USER-AGENT / FINAL 不产出字段规则")
    }

    func testMalformedValuesSkipped() {
        let out = RoutingRuleConverter.xrayRules(from: [
            Rule(type: .domain, value: "", target: .proxy),
            Rule(type: .domain, value: "has space.com", target: .proxy),
            Rule(type: .domainSuffix, value: "a,b.com", target: .proxy),
            Rule(type: .ipCIDR, value: "999.999.0.0/8", target: .direct),
            Rule(type: .ipCIDR, value: "10.0.0.0/33", target: .direct),
            Rule(type: .ipCIDR, value: "not-an-ip", target: .direct),
            Rule(type: .ipCIDR6, value: "2001:db8::/200", target: .direct),
            Rule(type: .geoip, value: "c n", target: .direct)
        ])
        XCTAssertTrue(out.isEmpty, "畸形值必须整条跳过 —— 一条坏规则不能让 xray 启动失败")
    }

    func testMalformedRuleDoesNotBreakNeighbors() {
        let out = RoutingRuleConverter.xrayRules(from: [
            Rule(type: .domainSuffix, value: "a.com", target: .proxy),
            Rule(type: .ipCIDR, value: "garbage", target: .proxy),
            Rule(type: .domainSuffix, value: "b.com", target: .proxy)
        ])
        // 中间的坏规则消失后，前后两条 domain 规则相邻 → 合并
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0]["domain"] as? [String], ["domain:a.com", "domain:b.com"])
    }

    func testValuesTrimmedBeforeUse() {
        let out = RoutingRuleConverter.xrayRules(from: [
            Rule(type: .domainSuffix, value: "  example.com  ", target: .proxy)
        ])
        XCTAssertEqual(out[0]["domain"] as? [String], ["domain:example.com"])
    }

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertTrue(RoutingRuleConverter.xrayRules(from: []).isEmpty)
    }

    // MARK: - FINAL

    func testFinalOutboundTagPicksFirstFinal() {
        let rules = [
            Rule(type: .domainSuffix, value: "a.com", target: .proxy),
            Rule(type: .final, value: "", target: .direct),
            Rule(type: .final, value: "", target: .reject)
        ]
        XCTAssertEqual(RoutingRuleConverter.finalOutboundTag(from: rules), "direct",
                       "多条 FINAL 取第一条（自定义在前 → 自定义优先）")
    }

    func testFinalOutboundTagNilWhenNoFinal() {
        XCTAssertNil(RoutingRuleConverter.finalOutboundTag(from: [
            Rule(type: .domainSuffix, value: "a.com", target: .proxy)
        ]))
    }
}
