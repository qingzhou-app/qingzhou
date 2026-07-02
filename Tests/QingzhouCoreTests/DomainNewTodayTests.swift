import XCTest
@testable import QingzhouCore

/// DomainDailyHistory.newTodayStats：「今日新增」判定 —— 今天出现、
/// 且 30 天窗口内更早的天里从未见过的主域名（域名 tab 顶部「今日新增」分组数据源）。
final class DomainNewTodayTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func conn(_ host: String, route: String = "PROXY", at: Date) -> Connection {
        Connection(targetHost: host, sourceAddress: "127.0.0.1:1",
                   targetAddress: "\(host):443", type: .https, route: route,
                   matchedRule: "", openedAt: at)
    }

    func testDomainOnlySeenTodayIsNew() {
        var h = DomainDailyHistory()
        h.record([conn("fresh.example.com", at: now),
                  conn("api.fresh.example.com", at: now)], calendar: cal)
        let out = h.newTodayStats(now: now, calendar: cal)
        XCTAssertEqual(out.map(\.domain), ["example.com"])
        XCTAssertEqual(out[0].connectionCount, 2, "今日新增行显示今天的聚合统计")
    }

    func testDomainSeenInEarlierHistoryIsNotNew() {
        var h = DomainDailyHistory()
        h.record([conn("old.com", at: now.addingTimeInterval(-86_400 * 10))], calendar: cal)
        h.record([conn("old.com", at: now), conn("new.com", at: now)], calendar: cal)
        XCTAssertEqual(h.newTodayStats(now: now, calendar: cal).map(\.domain), ["new.com"])
    }

    func testDomainSeenYesterdayIsNotNew() {
        var h = DomainDailyHistory()
        h.record([conn("a.com", at: now.addingTimeInterval(-86_400))], calendar: cal)
        h.record([conn("a.com", at: now)], calendar: cal)
        XCTAssertTrue(h.newTodayStats(now: now, calendar: cal).isEmpty)
    }

    func testNoTodayRecordsMeansEmpty() {
        var h = DomainDailyHistory()
        h.record([conn("a.com", at: now.addingTimeInterval(-86_400))], calendar: cal)
        XCTAssertTrue(h.newTodayStats(now: now, calendar: cal).isEmpty)
    }

    func testExcludingBareIPsFiltersIPEntries() {
        var h = DomainDailyHistory()
        h.record([conn("1.2.3.4", at: now), conn("new.com", at: now)], calendar: cal)
        XCTAssertEqual(h.newTodayStats(now: now, calendar: cal, excludingBareIPs: true)
            .map(\.domain), ["new.com"])
        // 不开过滤时裸 IP 也算新面孔（与「忽略 IP」开关口径一致）
        XCTAssertEqual(h.newTodayStats(now: now, calendar: cal).count, 2)
    }

    func testSortedByConnectionCountDescThenDomain() {
        var h = DomainDailyHistory()
        h.record([conn("busy.com", at: now), conn("busy.com", at: now),
                  conn("aaa.com", at: now), conn("bbb.com", at: now)], calendar: cal)
        XCTAssertEqual(h.newTodayStats(now: now, calendar: cal).map(\.domain),
                       ["busy.com", "aaa.com", "bbb.com"])
    }
}
