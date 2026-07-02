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
        // digest 级计数是**连接次数**：三者之和 = 当天总连接次数（4），可与行内「N 次」对账
        XCTAssertEqual(d.proxyCount, 1)
        XCTAssertEqual(d.directCount, 2)
        XCTAssertEqual(d.rejectCount, 1)
        XCTAssertEqual(d.proxyCount + d.directCount + d.rejectCount,
                       d.domains.reduce(0) { $0 + $1.connectionCount },
                       "header 三计数之和应等于所有行的连接次数之和")
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

    // MARK: - 「忽略 IP」过滤 × 三个 tab 计数一致性

    func testDigestsCanExcludeBareIPs() {
        var h = DomainDailyHistory()
        let t = Date(timeIntervalSince1970: 1_750_000_000)
        h.record([conn("a.com", at: t),
                  conn("8.8.8.8", route: "DIRECT", at: t),
                  conn("2001:db8::1", at: t)], calendar: cal)

        XCTAssertEqual(h.digests(calendar: cal)[0].domains.count, 3, "不过滤时 3 个条目都在")
        let filtered = h.digests(calendar: cal, excludingBareIPs: true)[0]
        XCTAssertEqual(filtered.domains.map(\.domain), ["a.com"], "裸 IP（v4/v6）应被剔除")
        XCTAssertEqual(filtered.proxyCount + filtered.directCount + filtered.rejectCount, 1,
                       "header 计数也要跟着过滤，不能还数被隐藏的连接")
    }

    func testDigestsDropDayWhoseEntriesAreAllBareIPs() {
        var h = DomainDailyHistory()
        let t = Date(timeIntervalSince1970: 1_750_000_000)
        h.record([conn("8.8.8.8", at: t)], calendar: cal)
        XCTAssertTrue(h.digests(calendar: cal, excludingBareIPs: true).isEmpty,
                      "整天都是裸 IP → 过滤后这一天不该以空壳出现")
    }

    /// 开/关「忽略 IP」两种状态下，域名 tab（aggregate）、每日 tab（digests）、
    /// 建议 tab（suggestions）看到的域名集合与连接次数必须一致 —— 验收反馈的
    /// 「数字对不上」就是每日 tab 没吃过滤造成的。
    func testThreeTabsAgreeOnCountsRegardlessOfIPFilter() {
        let t = Date(timeIntervalSince1970: 1_750_000_000)
        let conns = [
            conn("www.google.com", route: "PROXY", rule: Connection.noMatchedRule, at: t),
            conn("google.com", route: "PROXY", rule: Connection.noMatchedRule, at: t),
            conn("notion.so", route: "DIRECT", rule: Connection.noMatchedRule, at: t),
            conn("8.8.8.8", route: "DIRECT", rule: "geoip:cn（内置国内 IP 直连）", at: t),
            conn("www.baidu.com", route: "DIRECT", rule: "geosite:cn（内置国内域名直连）", at: t)
        ]
        var h = DomainDailyHistory()
        h.record(conns, calendar: cal)

        for hide in [false, true] {
            let visible = hide ? conns.filter { !HostClassifier.isBareIP($0.targetHost) } : conns
            let stats = DomainAnalyzer.aggregate(visible, sortBy: .connections)   // 域名 tab
            let digest = h.digests(calendar: cal, excludingBareIPs: hide)[0]      // 每日 tab

            XCTAssertEqual(stats.count, digest.domains.count,
                           "hide=\(hide)：域名 tab 的域名数 == 每日 tab 当天域名数")
            XCTAssertEqual(Set(stats.map(\.domain)), Set(digest.domains.map(\.domain)),
                           "hide=\(hide)：两个 tab 看到同一批域名")
            let headerTotal = digest.proxyCount + digest.directCount + digest.rejectCount
            XCTAssertEqual(headerTotal, visible.count,
                           "hide=\(hide)：每日 header 三计数之和 == 可见连接次数")
            XCTAssertEqual(headerTotal, stats.reduce(0) { $0 + $1.connectionCount },
                           "hide=\(hide)：header 计数与域名 tab 行内次数之和一致")

            let suggestions = DomainAnalyzer.suggestions(stats)                   // 建议 tab
            if hide {
                XCTAssertFalse(suggestions.contains { HostClassifier.isBareIP($0.domain) },
                               "过滤开着时建议里不该出现裸 IP")
            }
        }
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
