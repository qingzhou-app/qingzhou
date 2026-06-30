import XCTest
@testable import VPNCore

final class DomainAnalyzerTests: XCTestCase {

    private func conn(_ host: String, route: String, rule: String = "",
                      up: Int64 = 0, down: Int64 = 0, at: Date = Date()) -> Connection {
        Connection(targetHost: host, sourceAddress: "127.0.0.1:1",
                   targetAddress: "\(host):443", type: .https, route: route,
                   matchedRule: rule, openedAt: at, uploadBytes: up, downloadBytes: down)
    }

    // MARK: - registrableDomain

    func testRegistrableDomainCollapsesSubdomains() {
        XCTAssertEqual(DomainAnalyzer.registrableDomain("www.google.com"), "google.com")
        XCTAssertEqual(DomainAnalyzer.registrableDomain("api.sub.openai.com"), "openai.com")
    }

    func testRegistrableDomainHandlesTwoLevelSuffix() {
        XCTAssertEqual(DomainAnalyzer.registrableDomain("www.gov.cn"), "www.gov.cn")
        XCTAssertEqual(DomainAnalyzer.registrableDomain("shop.taobao.com.cn"), "taobao.com.cn")
        XCTAssertEqual(DomainAnalyzer.registrableDomain("a.b.co.uk"), "b.co.uk")
    }

    func testRegistrableDomainLeavesIPsAlone() {
        XCTAssertEqual(DomainAnalyzer.registrableDomain("8.8.8.8"), "8.8.8.8")
        XCTAssertEqual(DomainAnalyzer.registrableDomain("2001:db8::1"), "2001:db8::1")
    }

    // MARK: - aggregate

    func testAggregateMergesByDomainAndSortsByBytes() {
        let conns = [
            conn("www.google.com", route: "PROXY", up: 100, down: 900),
            conn("mail.google.com", route: "PROXY", up: 50, down: 50),
            conn("baidu.com", route: "DIRECT", up: 10, down: 10)
        ]
        let stats = DomainAnalyzer.aggregate(conns)
        XCTAssertEqual(stats.count, 2, "两个 google 子域应合并成 google.com")
        XCTAssertEqual(stats.first?.domain, "google.com")
        XCTAssertEqual(stats.first?.connectionCount, 2)
        XCTAssertEqual(stats.first?.totalBytes, 1100)
        XCTAssertEqual(stats.first?.route, .proxy)
    }

    func testAggregateMarksMixedRoute() {
        let conns = [
            conn("x.com", route: "PROXY"),
            conn("x.com", route: "DIRECT")
        ]
        XCTAssertEqual(DomainAnalyzer.aggregate(conns).first?.route, .mixed)
    }

    // MARK: - daily

    func testDailyGroupsByDayDescending() {
        let cal = Calendar(identifier: .gregorian)
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)       // 某天
        let day2 = day1.addingTimeInterval(86_400 * 2)              // 两天后
        let conns = [
            conn("a.com", route: "PROXY", at: day1),
            conn("b.com", route: "DIRECT", at: day2)
        ]
        let digests = DomainAnalyzer.daily(conns, calendar: cal)
        XCTAssertEqual(digests.count, 2)
        XCTAssertGreaterThan(digests[0].day, digests[1].day, "最近的一天在前")
    }

    // MARK: - suggestions

    func testSuggestsProxyForUnmatchedForeignDirect() {
        let stats = DomainAnalyzer.aggregate([conn("notion.so", route: "DIRECT", rule: "")])
        let sugg = DomainAnalyzer.suggestions(stats)
        XCTAssertEqual(sugg.first?.kind, .shouldProxy)
    }

    func testSuggestsDirectForChineseProxied() {
        let stats = DomainAnalyzer.aggregate([conn("www.baidu.com", route: "PROXY", rule: "FINAL,PROXY")])
        let sugg = DomainAnalyzer.suggestions(stats)
        XCTAssertEqual(sugg.first?.kind, .shouldDirect)
    }

    func testNoSuggestionForWellRoutedForeignProxy() {
        let stats = DomainAnalyzer.aggregate([conn("google.com", route: "PROXY", rule: "DOMAIN-SUFFIX,google.com,PROXY")])
        XCTAssertTrue(DomainAnalyzer.suggestions(stats).isEmpty)
    }
}
