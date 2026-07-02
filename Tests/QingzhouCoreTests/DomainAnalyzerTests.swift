import XCTest
@testable import QingzhouCore

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

    func testAggregateSortsByConnectionCountWhenRequested() {
        // 流量字节在接上 QueryStats 前恒 0（access log 不含字节数），按流量排序是假排序。
        // UI 侧改用连接次数维度；字节有真实来源后再切回 .traffic。
        let conns = [
            conn("one.com", route: "PROXY", up: 9_999, down: 9_999),   // 流量大但只 1 次
            conn("many.com", route: "PROXY"),
            conn("many.com", route: "PROXY"),
            conn("many.com", route: "PROXY")
        ]
        let stats = DomainAnalyzer.aggregate(conns, sortBy: .connections)
        XCTAssertEqual(stats.map(\.domain), ["many.com", "one.com"])
        // 默认仍按流量（保持旧行为，供未来切回）
        XCTAssertEqual(DomainAnalyzer.aggregate(conns).first?.domain, "one.com")
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

    // MARK: - suggestions × 「未命中（默认策略）」哨兵值

    func testNoUnmatchedNoiseForForeignProxyOnDefaultPolicy() {
        // rule 模式下境外域名走默认代理是**预期行为**，回填哨兵值后不应再刷「未命中」建议
        let stats = DomainAnalyzer.aggregate([
            conn("github.com", route: "PROXY", rule: Connection.noMatchedRule)
        ])
        XCTAssertTrue(DomainAnalyzer.suggestions(stats).isEmpty)
    }

    func testStillSuggestsProxyForSentinelForeignDirect() {
        // 境外域名直连且只命中默认策略 → 仍应建议补代理规则（哨兵值等同「未命中」）
        let stats = DomainAnalyzer.aggregate([
            conn("notion.so", route: "DIRECT", rule: Connection.noMatchedRule)
        ])
        XCTAssertEqual(DomainAnalyzer.suggestions(stats).first?.kind, .shouldProxy)
    }

    func testNoSuggestionForForeignDirectMatchedByBuiltinRule() {
        // 回填出 geosite:cn 之类内置规则 → 说明 xray 是按规则直连的，不该误报 shouldProxy
        let stats = DomainAnalyzer.aggregate([conn("notion.so", route: "DIRECT", rule: "geosite:cn")])
        XCTAssertTrue(DomainAnalyzer.suggestions(stats).isEmpty)
    }

    // MARK: - aggregate 的 lastMatchedRule：真实规则优先于哨兵值

    func testAggregatePrefersRealRuleOverSentinel() {
        let real = "DOMAIN-SUFFIX,x.com,PROXY"
        // 先真实后哨兵、先哨兵后真实，聚合结果都应保留真实规则
        for conns in [
            [conn("x.com", route: "PROXY", rule: real),
             conn("x.com", route: "PROXY", rule: Connection.noMatchedRule)],
            [conn("x.com", route: "PROXY", rule: Connection.noMatchedRule),
             conn("x.com", route: "PROXY", rule: real)]
        ] {
            XCTAssertEqual(DomainAnalyzer.aggregate(conns).first?.lastMatchedRule, real)
        }
    }

    // MARK: - routeCategory

    func testRouteCategoryMapsRouteStrings() {
        XCTAssertEqual(DomainAnalyzer.routeCategory("DIRECT"), .direct)
        XCTAssertEqual(DomainAnalyzer.routeCategory("REJECT"), .reject)
        XCTAssertEqual(DomainAnalyzer.routeCategory("香港 IEPL 01"), .proxy)
    }
}
