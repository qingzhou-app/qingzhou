import XCTest
@testable import QingzhouCore

/// DailyDigest.filtered(byDomainKeyword:)：域名分析「每日」tab 的搜索过滤。
final class DailyDigestFilterTests: XCTestCase {

    private func stat(_ domain: String, count: Int = 1) -> DomainStat {
        DomainStat(domain: domain, connectionCount: count, uploadBytes: 0, downloadBytes: 0,
                   route: .direct, lastMatchedRule: "", firstSeen: .init(), lastSeen: .init())
    }

    private func digest(_ domains: [DomainStat]) -> DailyDigest {
        DailyDigest(day: Calendar.current.startOfDay(for: .init()),
                    domains: domains, proxyCount: 5, directCount: 3, rejectCount: 2)
    }

    func testKeepsOnlyMatchingDomainsCaseInsensitive() {
        let d = digest([stat("zhihu.com"), stat("ZHIMG.com"), stat("baidu.com")])
        let f = d.filtered(byDomainKeyword: "ZHi")
        XCTAssertEqual(f?.domains.map(\.domain), ["zhihu.com", "ZHIMG.com"])
    }

    func testNoMatchReturnsNilSoDayRowHides() {
        let d = digest([stat("baidu.com")])
        XCTAssertNil(d.filtered(byDomainKeyword: "zhihu"))
    }

    func testEmptyOrWhitespaceKeywordReturnsSelfUnchanged() {
        let d = digest([stat("a.com"), stat("b.com")])
        XCTAssertEqual(d.filtered(byDomainKeyword: ""), d)
        XCTAssertEqual(d.filtered(byDomainKeyword: "   "), d)
    }

    func testRouteCountsKeepWholeDayMeaning() {
        // 代理/直连/拒绝次数是全天口径，过滤不改写 —— UI 搜索态下自行隐藏这段，
        // 免得和过滤后的行数对不上（口径对账的老教训）。
        let d = digest([stat("zhihu.com"), stat("baidu.com")])
        let f = d.filtered(byDomainKeyword: "zhihu")
        XCTAssertEqual(f?.proxyCount, 5)
        XCTAssertEqual(f?.directCount, 3)
        XCTAssertEqual(f?.rejectCount, 2)
    }
}
