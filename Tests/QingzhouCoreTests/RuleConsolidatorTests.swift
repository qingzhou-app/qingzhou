import XCTest
@testable import QingzhouCore

/// RuleConsolidator：检测自定义规则里同一主域名下多条 DOMAIN / DOMAIN-SUFFIX 同目标规则，
/// 建议合并为一条 DOMAIN-SUFFIX（域名分析「建议」tab 的「可合并」类建议）。
///
/// 安全边界：同主域名下存在**不同目标**的规则时不建议合并 —— 规则是按序 first-match，
/// 合并成 SUFFIX 会吞掉后面不同目标的精确规则，改变分流行为。
final class RuleConsolidatorTests: XCTestCase {

    func testTwoDomainRulesUnderSameRegistrableDomainAreMergeable() {
        let rules = [
            Rule(type: .domain, value: "www.youtube.com", target: .proxy),
            Rule(type: .domain, value: "m.youtube.com", target: .proxy),
        ]
        let out = RuleConsolidator.mergeSuggestions(customRules: rules)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].domain, "youtube.com")
        XCTAssertEqual(out[0].target, .proxy)
        XCTAssertEqual(Set(out[0].rules.map(\.id)), Set(rules.map(\.id)))
        XCTAssertEqual(out[0].mergedLineForm, "DOMAIN-SUFFIX,youtube.com,PROXY")
    }

    func testDomainAndSuffixMixIsMergeable() {
        let rules = [
            Rule(type: .domainSuffix, value: "google.com", target: .proxy),
            Rule(type: .domain, value: "mail.google.com", target: .proxy),
        ]
        let out = RuleConsolidator.mergeSuggestions(customRules: rules)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].domain, "google.com")
    }

    func testDifferentTargetsUnderSameDomainAreNotMergeable() {
        // 合并会改变 first-match 语义（SUFFIX 吞掉不同目标的精确规则），必须跳过
        let rules = [
            Rule(type: .domain, value: "a.example.com", target: .proxy),
            Rule(type: .domain, value: "b.example.com", target: .proxy),
            Rule(type: .domain, value: "ads.example.com", target: .reject),
        ]
        XCTAssertTrue(RuleConsolidator.mergeSuggestions(customRules: rules).isEmpty)
    }

    func testSingleRuleIsNotMergeable() {
        let rules = [Rule(type: .domain, value: "www.example.com", target: .proxy)]
        XCTAssertTrue(RuleConsolidator.mergeSuggestions(customRules: rules).isEmpty)
    }

    func testNonDomainRuleTypesAreIgnored() {
        let rules = [
            Rule(type: .ipCIDR, value: "1.2.3.0/24", target: .proxy),
            Rule(type: .geoip, value: "cn", target: .direct),
            Rule(type: .domainKeyword, value: "google", target: .proxy),
            Rule(type: .final, value: "", target: .proxy),
            // KEYWORD/CIDR 不参与，剩下单条 DOMAIN 不够合并
            Rule(type: .domain, value: "www.google.com", target: .proxy),
        ]
        XCTAssertTrue(RuleConsolidator.mergeSuggestions(customRules: rules).isEmpty)
    }

    func testBareIPAndDotlessValuesAreIgnored() {
        let rules = [
            Rule(type: .domain, value: "192.168.1.1", target: .direct),
            Rule(type: .domain, value: "10.0.0.1", target: .direct),
            Rule(type: .domain, value: "localhost", target: .direct),
        ]
        XCTAssertTrue(RuleConsolidator.mergeSuggestions(customRules: rules).isEmpty)
    }

    func testDuplicateSuffixRulesAreMergeable() {
        // 两条完全相同语义的 SUFFIX（手工 + 一键各加了一次）→ 合并去重
        let rules = [
            Rule(type: .domainSuffix, value: "example.com", target: .direct),
            Rule(type: .domainSuffix, value: "example.com", target: .direct),
        ]
        let out = RuleConsolidator.mergeSuggestions(customRules: rules)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].rules.count, 2)
    }

    func testValueCaseInsensitive() {
        let rules = [
            Rule(type: .domain, value: "WWW.Example.COM", target: .proxy),
            Rule(type: .domain, value: "api.example.com", target: .proxy),
        ]
        let out = RuleConsolidator.mergeSuggestions(customRules: rules)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].domain, "example.com")
    }

    func testMultipleDomainsSortedByDomain() {
        let rules = [
            Rule(type: .domain, value: "a.zzz.com", target: .proxy),
            Rule(type: .domain, value: "b.zzz.com", target: .proxy),
            Rule(type: .domain, value: "a.aaa.com", target: .direct),
            Rule(type: .domain, value: "b.aaa.com", target: .direct),
        ]
        let out = RuleConsolidator.mergeSuggestions(customRules: rules)
        XCTAssertEqual(out.map(\.domain), ["aaa.com", "zzz.com"])
    }

    func testTwoLevelPublicSuffixDomains() {
        // com.cn 这类二级公共后缀：主域名取三段，别把 sina.com.cn 和 sohu.com.cn 混为一组
        let rules = [
            Rule(type: .domain, value: "news.sina.com.cn", target: .direct),
            Rule(type: .domain, value: "sports.sina.com.cn", target: .direct),
            Rule(type: .domain, value: "www.sohu.com.cn", target: .direct),
        ]
        let out = RuleConsolidator.mergeSuggestions(customRules: rules)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].domain, "sina.com.cn")
        XCTAssertEqual(out[0].rules.count, 2)
    }
}
