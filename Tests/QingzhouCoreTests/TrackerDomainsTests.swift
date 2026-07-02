import XCTest
@testable import QingzhouCore

/// TrackerDomains：追踪器域名判定（内置后缀表，来源见资源文件头注释）。
/// 域名分析里给命中的域名行加「追踪器」徽章、建议页给高频追踪器「建议拒绝」。
final class TrackerDomainsTests: XCTestCase {

    func testResourceTableLoads() {
        XCTAssertGreaterThan(TrackerDomains.suffixes.count, 150, "内置表应有几百条")
        XCTAssertLessThan(TrackerDomains.suffixes.count, 1000, "定位是高频子集，别膨胀成全量表")
        // 全部小写、无空行注释混入
        XCTAssertTrue(TrackerDomains.suffixes.allSatisfy { $0 == $0.lowercased() && !$0.isEmpty })
    }

    func testWellKnownTrackersHit() {
        XCTAssertTrue(TrackerDomains.isTracker("doubleclick.net"))
        XCTAssertTrue(TrackerDomains.isTracker("www.google-analytics.com"), "子域名应命中后缀")
        XCTAssertTrue(TrackerDomains.isTracker("ssl.googletagmanager.com"))
        XCTAssertTrue(TrackerDomains.isTracker("sdk.appsflyer.com"))
        XCTAssertTrue(TrackerDomains.isTracker("cnzz.com"), "国内统计服务也在表内")
        XCTAssertTrue(TrackerDomains.isTracker("hm.baidu.com"),
                      "表支持多段后缀条目：百度统计是追踪器，baidu.com 主站不是")
    }

    func testNormalDomainsMiss() {
        XCTAssertFalse(TrackerDomains.isTracker("github.com"))
        XCTAssertFalse(TrackerDomains.isTracker("www.apple.com"))
        XCTAssertFalse(TrackerDomains.isTracker("baidu.com"), "主站不是追踪器，别把整个大厂划进去")
    }

    func testBareIPAndEdgeCasesMiss() {
        XCTAssertFalse(TrackerDomains.isTracker("1.2.3.4"))
        XCTAssertFalse(TrackerDomains.isTracker("::1"))
        XCTAssertFalse(TrackerDomains.isTracker(""))
        XCTAssertFalse(TrackerDomains.isTracker("localhost"))
    }

    func testCaseInsensitiveAndTrailingDot() {
        XCTAssertTrue(TrackerDomains.isTracker("Stats.DoubleClick.NET"))
        XCTAssertTrue(TrackerDomains.isTracker("doubleclick.net."))
    }

    func testSuffixMatchDoesNotOvershoot() {
        // 只做「逐级剥子域名」的后缀匹配，别把 notdoubleclick.net 这种字符串包含误判进来
        XCTAssertFalse(TrackerDomains.isTracker("notdoubleclick.net"))
        XCTAssertFalse(TrackerDomains.isTracker("doubleclick.net.evil.com"))
    }
}

/// DomainAnalyzer.suggestions 的「建议拒绝」分支：高频追踪器域名。
final class TrackerSuggestionTests: XCTestCase {

    private func stat(_ domain: String, count: Int, route: DomainRoute,
                      rule: String = "") -> DomainStat {
        DomainStat(domain: domain, connectionCount: count, uploadBytes: 0, downloadBytes: 0,
                   route: route, lastMatchedRule: rule, firstSeen: Date(), lastSeen: Date())
    }

    func testHighFrequencyTrackerGetsRejectSuggestion() {
        let out = DomainAnalyzer.suggestions([stat("doubleclick.net", count: 10, route: .proxy)])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].kind, .shouldReject)
        XCTAssertEqual(out[0].domain, "doubleclick.net")
    }

    func testLowFrequencyTrackerNotSuggested() {
        let out = DomainAnalyzer.suggestions(
            [stat("doubleclick.net", count: DomainAnalyzer.trackerRejectMinConnections - 1,
                  route: .proxy)])
        XCTAssertTrue(out.filter { $0.kind == .shouldReject }.isEmpty)
    }

    func testAlreadyRejectedTrackerNotSuggested() {
        let out = DomainAnalyzer.suggestions([stat("doubleclick.net", count: 10, route: .reject)])
        XCTAssertTrue(out.isEmpty)
    }

    func testTrackerSuggestionTakesPriorityOverOtherKinds() {
        // 追踪器 + 未命中规则的直连：只给「建议拒绝」，不再叠加 shouldProxy/unmatched
        let out = DomainAnalyzer.suggestions([stat("doubleclick.net", count: 10, route: .direct)])
        XCTAssertEqual(out.map(\.kind), [.shouldReject])
    }

    func testNonTrackerUnaffected() {
        let out = DomainAnalyzer.suggestions([stat("github.com", count: 10, route: .proxy,
                                                   rule: "DOMAIN-SUFFIX,github.com,PROXY")])
        XCTAssertTrue(out.isEmpty)
    }
}
