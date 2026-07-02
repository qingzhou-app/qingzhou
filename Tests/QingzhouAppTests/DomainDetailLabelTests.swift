import XCTest
@testable import QingzhouApp

/// DomainDetailView 的柱下日期标签：今天标「今天」，其余 M/d。
final class DomainDetailLabelTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    func testTodayLabeled() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        XCTAssertEqual(DomainDetailView.dayLabel(cal.startOfDay(for: now), calendar: cal, now: now),
                       "今天")
    }

    func testPastDayLabeledMonthSlashDay() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)   // 2025-06-15 CST
        let past = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: now))!
        let c = cal.dateComponents([.month, .day], from: past)
        XCTAssertEqual(DomainDetailView.dayLabel(past, calendar: cal, now: now),
                       "\(c.month!)/\(c.day!)")
    }
}
