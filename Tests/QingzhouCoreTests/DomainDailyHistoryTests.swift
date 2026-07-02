import XCTest
@testable import QingzhouCore

/// DomainDailyHistory：按天 × 主域名的聚合持久化（域名分析「每日」视图的数据源）。
/// 只存聚合结果不存原始连接（隐私 + 体积），保留最近 30 天。
final class DomainDailyHistoryTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func conn(_ host: String, route: String = "PROXY", rule: String = "",
                      at: Date = Date()) -> Connection {
        Connection(targetHost: host, sourceAddress: "127.0.0.1:1",
                   targetAddress: "\(host):443", type: .https, route: route,
                   matchedRule: rule, openedAt: at)
    }

    // MARK: - 增量摄入

    func testRecordAggregatesByRegistrableDomainWithinDay() {
        var h = DomainDailyHistory()
        let t = Date(timeIntervalSince1970: 1_750_000_000)
        h.record([conn("www.google.com", at: t),
                  conn("mail.google.com", at: t.addingTimeInterval(60))], calendar: cal)

        let digests = h.digests(calendar: cal)
        XCTAssertEqual(digests.count, 1)
        XCTAssertEqual(digests[0].domains.count, 1, "两个 google 子域应合并为 google.com")
        XCTAssertEqual(digests[0].domains[0].domain, "google.com")
        XCTAssertEqual(digests[0].domains[0].connectionCount, 2)
    }

    func testRecordIsIncrementalAcrossBatches() {
        var h = DomainDailyHistory()
        let t = Date(timeIntervalSince1970: 1_750_000_000)
        h.record([conn("a.com", at: t)], calendar: cal)
        h.record([conn("a.com", at: t.addingTimeInterval(10))], calendar: cal)   // 第二批（模拟每 2 秒摄入）
        XCTAssertEqual(h.digests(calendar: cal)[0].domains[0].connectionCount, 2)
    }

    func testRecordTracksRouteDistributionAndMixed() {
        var h = DomainDailyHistory()
        let t = Date(timeIntervalSince1970: 1_750_000_000)
        h.record([conn("a.com", route: "PROXY", at: t),
                  conn("a.com", route: "DIRECT", at: t),
                  conn("b.com", route: "DIRECT", at: t),
                  conn("c.com", route: "REJECT", at: t)], calendar: cal)

        let d = h.digests(calendar: cal)[0]
        XCTAssertEqual(d.domains.first { $0.domain == "a.com" }?.route, .mixed)
        XCTAssertEqual(d.domains.first { $0.domain == "b.com" }?.route, .direct)
        XCTAssertEqual(d.domains.first { $0.domain == "c.com" }?.route, .reject)
        // digest 级计数沿用 DomainAnalyzer.daily 的口径：mixed 计入代理
        XCTAssertEqual(d.proxyCount, 1)
        XCTAssertEqual(d.directCount, 1)
        XCTAssertEqual(d.rejectCount, 1)
    }

    func testRecordTracksFirstAndLastSeen() {
        var h = DomainDailyHistory()
        let t = Date(timeIntervalSince1970: 1_750_000_000)
        h.record([conn("a.com", at: t.addingTimeInterval(300))], calendar: cal)
        h.record([conn("a.com", at: t)], calendar: cal)
        h.record([conn("a.com", at: t.addingTimeInterval(600))], calendar: cal)
        let s = h.digests(calendar: cal)[0].domains[0]
        XCTAssertEqual(s.firstSeen, t)
        XCTAssertEqual(s.lastSeen, t.addingTimeInterval(600))
    }

    func testRecordPrefersRealRuleOverSentinel() {
        var h = DomainDailyHistory()
        let t = Date(timeIntervalSince1970: 1_750_000_000)
        h.record([conn("a.com", rule: "DOMAIN-SUFFIX,a.com,PROXY", at: t)], calendar: cal)
        h.record([conn("a.com", rule: Connection.noMatchedRule, at: t)], calendar: cal)
        XCTAssertEqual(h.digests(calendar: cal)[0].domains[0].lastMatchedRule,
                       "DOMAIN-SUFFIX,a.com,PROXY")
    }

    // MARK: - 每日视图

    func testDigestsSplitByDayNewestFirstAndSortByCount() {
        var h = DomainDailyHistory()
        let day1 = Date(timeIntervalSince1970: 1_750_000_000)
        let day2 = day1.addingTimeInterval(86_400 * 2)
        h.record([conn("old.com", at: day1),
                  conn("busy.com", at: day2), conn("busy.com", at: day2),
                  conn("quiet.com", at: day2)], calendar: cal)

        let digests = h.digests(calendar: cal)
        XCTAssertEqual(digests.count, 2)
        XCTAssertGreaterThan(digests[0].day, digests[1].day, "最近的一天在前")
        XCTAssertEqual(digests[0].day, cal.startOfDay(for: day2), "day 应是当天 0 点")
        XCTAssertEqual(digests[0].domains.map(\.domain), ["busy.com", "quiet.com"],
                       "同一天内按连接次数降序")
        XCTAssertEqual(digests[0].domains[0].totalBytes, 0, "没有真实字节来源，字节应为 0 而不是编造")
    }

    // MARK: - 按天滚动清理

    func testPruneKeepsOnlyRecentDays() {
        var h = DomainDailyHistory()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        h.record([conn("ancient.com", at: now.addingTimeInterval(-86_400 * 40)),
                  conn("edge.com", at: now.addingTimeInterval(-86_400 * 29)),   // 第 30 天，压线保留
                  conn("today.com", at: now)], calendar: cal)

        h.prune(now: now, calendar: cal)

        let domains = h.digests(calendar: cal).flatMap { $0.domains.map(\.domain) }
        XCTAssertFalse(domains.contains("ancient.com"), "40 天前的应被清掉")
        XCTAssertTrue(domains.contains("edge.com"), "保留窗口内(含)第 30 天")
        XCTAssertTrue(domains.contains("today.com"))
    }

    func testPruneDropsMalformedDayKeys() {
        var h = DomainDailyHistory()
        h.days["not-a-date"] = [:]
        h.prune(now: Date(timeIntervalSince1970: 1_750_000_000), calendar: cal)
        XCTAssertTrue(h.days.isEmpty)
    }

    // MARK: - Codable（持久化格式）

    func testCodableRoundtrip() throws {
        var h = DomainDailyHistory()
        let t = Date(timeIntervalSince1970: 1_750_000_000)
        h.record([conn("a.com", route: "DIRECT", rule: "geosite:cn", at: t)], calendar: cal)

        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let restored = try dec.decode(DomainDailyHistory.self, from: enc.encode(h))
        XCTAssertEqual(restored, h)
    }
}
