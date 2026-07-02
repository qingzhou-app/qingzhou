import XCTest
@testable import QingzhouCore

/// DomainDailyHistory.dailyCounts：单个主域名最近 N 天的连接次数序列
/// （域名详情页 7 天趋势柱状图的数据源）。
final class DomainDailyCountsTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func conn(_ host: String, at: Date) -> Connection {
        Connection(targetHost: host, sourceAddress: "127.0.0.1:1",
                   targetAddress: "\(host):443", type: .https, route: "PROXY",
                   matchedRule: "", openedAt: at)
    }

    func testReturnsSevenChronologicalDaysWithZeroFill() {
        var h = DomainDailyHistory()
        h.record([conn("www.example.com", at: now),
                  conn("api.example.com", at: now),
                  conn("example.com", at: now.addingTimeInterval(-86_400 * 2))], calendar: cal)

        let out = h.dailyCounts(domain: "example.com", days: 7, now: now, calendar: cal)
        XCTAssertEqual(out.count, 7)
        // 时间正序：最早的在前，今天在最后
        XCTAssertEqual(out.last?.day, cal.startOfDay(for: now))
        XCTAssertEqual(out.map(\.count), [0, 0, 0, 0, 1, 0, 2], "无记录的天补 0")
    }

    func testOldRecordsOutsideWindowIgnored() {
        var h = DomainDailyHistory()
        h.record([conn("example.com", at: now.addingTimeInterval(-86_400 * 10))], calendar: cal)
        let out = h.dailyCounts(domain: "example.com", days: 7, now: now, calendar: cal)
        XCTAssertEqual(out.map(\.count), [0, 0, 0, 0, 0, 0, 0])
    }

    func testUnknownDomainIsAllZeros() {
        var h = DomainDailyHistory()
        h.record([conn("other.com", at: now)], calendar: cal)
        let out = h.dailyCounts(domain: "example.com", days: 7, now: now, calendar: cal)
        XCTAssertEqual(out.map(\.count), [0, 0, 0, 0, 0, 0, 0])
    }

    func testDomainKeyIsRegistrableDomainExactMatch() {
        var h = DomainDailyHistory()
        h.record([conn("www.example.com", at: now)], calendar: cal)
        // 记录已按主域名归并存储；查询也用主域名（详情页传的就是聚合行的 domain）
        XCTAssertEqual(h.dailyCounts(domain: "example.com", days: 7, now: now, calendar: cal)
            .last?.count, 1)
    }
}
