import XCTest
@testable import QingzhouCore

final class DomainTrafficLedgerTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!; return c }
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func snapshot(_ up: Int64, _ down: Int64, session: String = "A", host: String = "video.example.com", route: String = "proxy") -> DomainTrafficSnapshot {
        .init(session: session, entries: [.init(domain: host, route: route, upload: up, download: down)])
    }
    func testVPNSessionSurvivesCoreRestartAndCodingButNewVPNResets() throws {
        var ledger = DomainTrafficLedger(); let t = date("2026-10-20T00:00:00Z")
        ledger.ingest(snapshot(100, 200), at: t, calendar: calendar, vpnSessionID: "vpn-1")
        ledger = try JSONDecoder().decode(DomainTrafficLedger.self, from: JSONEncoder().encode(ledger))
        ledger.ingest(snapshot(130, 260), at: t.addingTimeInterval(10), calendar: calendar, vpnSessionID: "vpn-1")
        ledger.ingest(snapshot(10, 20, session: "B"), at: t.addingTimeInterval(20), calendar: calendar, vpnSessionID: "vpn-1")
        XCTAssertEqual(ledger.currentSession?.rows.first?.all.total, 420)
        ledger.ingest(snapshot(5, 10, session: "C"), at: t.addingTimeInterval(30), calendar: calendar, vpnSessionID: "vpn-2")
        XCTAssertEqual(ledger.currentSession?.rows.first?.all.total, 15)
        XCTAssertEqual(ledger.months["2026-10"]?.rows.first?.all.total, 435)
        XCTAssertEqual(ledger.days["2026-10-20"]?.rows.first?.all.total, 435)
    }
    func testDayBoundaryDoesNotResetSessionOrDoubleCount() {
        var ledger = DomainTrafficLedger()
        ledger.ingest(snapshot(100, 200), at: date("2026-10-20T15:59:59Z"), calendar: calendar, vpnSessionID: "vpn")
        ledger.ingest(snapshot(110, 220), at: date("2026-10-20T16:00:01Z"), calendar: calendar, vpnSessionID: "vpn")
        XCTAssertEqual(ledger.days["2026-10-20"]?.rows.first?.all.total, 300)
        XCTAssertEqual(ledger.days["2026-10-21"]?.rows.first?.all.total, 30)
        XCTAssertEqual(ledger.currentSession?.rows.first?.all.total, 330)
    }
    func testOldLedgerDoesNotInventHistoricalDayOrSessionBytes() throws {
        var ledger = DomainTrafficLedger(); let t = date("2026-10-20T00:00:00Z")
        ledger.ingest(snapshot(100, 200), at: t, calendar: calendar)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        for key in ["daysStorage", "currentSession", "vpnSessionID"] { root.removeValue(forKey: key) }
        ledger = try JSONDecoder().decode(DomainTrafficLedger.self, from: JSONSerialization.data(withJSONObject: root))
        XCTAssertTrue(ledger.days.isEmpty)
        XCTAssertNil(ledger.currentSession)
        ledger.ingest(snapshot(110, 220), at: t.addingTimeInterval(10), calendar: calendar)
        XCTAssertEqual(ledger.days["2026-10-20"]?.rows.first?.all.total, 30)
        XCTAssertEqual(ledger.currentSession?.rows.first?.all.total, 30)
        XCTAssertEqual(ledger.months["2026-10"]?.rows.first?.all.total, 330)
    }
    func testDailyRetentionAndCapacityPreserveTotals() {
        var ledger = DomainTrafficLedger(); let t = date("2026-09-01T00:00:00Z")
        for i in 0..<40 {
            ledger.ingest(snapshot(Int64(i + 1), 0), at: t.addingTimeInterval(Double(i) * 86400), calendar: calendar)
        }
        XCTAssertEqual(ledger.days.count, 31)
        XCTAssertEqual(ledger.currentSession?.rows.first?.all.total, 40)
    }

    func testLedgerPersistsDailyAndCurrentSessionBuckets() throws {
        var ledger = DomainTrafficLedger()
        ledger.ingest(snapshot(100, 200), at: date("2026-10-20T00:00:00Z"), calendar: calendar)
        ledger = try JSONDecoder().decode(DomainTrafficLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(ledger.days["2026-10-20"]?.rows.first?.all.total, 300)
        XCTAssertEqual(ledger.currentSession?.rows.first?.all.total, 300)
    }

    func testCumulativeSnapshotsDeduplicateAndSurviveCoding() throws {
        var ledger = DomainTrafficLedger()
        let t = date("2026-10-20T00:00:00Z")
        ledger.ingest(snapshot(100, 200), at: t, calendar: calendar)
        ledger.ingest(snapshot(100, 200), at: t.addingTimeInterval(10), calendar: calendar)
        let data = try JSONEncoder().encode(ledger)
        ledger = try JSONDecoder().decode(DomainTrafficLedger.self, from: data)
        ledger.ingest(snapshot(140, 280), at: t.addingTimeInterval(20), calendar: calendar)
        let row = try XCTUnwrap(ledger.months["2026-10"]?.rows.first)
        XCTAssertEqual(row.domain, "example.com")
        XCTAssertEqual(row.proxy.upload, 140); XCTAssertEqual(row.proxy.download, 280)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("video.example.com"))
    }
    func testProcessRestartCountsNewSessionOnce() throws {
        var ledger = DomainTrafficLedger(); let t = date("2026-10-20T00:00:00Z")
        ledger.ingest(snapshot(100, 200), at: t, calendar: calendar)
        ledger.ingest(snapshot(30, 40, session: "B"), at: t.addingTimeInterval(10), calendar: calendar)
        ledger.ingest(snapshot(30, 40, session: "B"), at: t.addingTimeInterval(20), calendar: calendar)
        XCTAssertEqual(ledger.months["2026-10"]?.rows.first?.proxy.total, 370)
    }
    func testLocalMonthBoundaryAssignsOnlyIncrementToNextMonth() throws {
        var ledger = DomainTrafficLedger()
        ledger.ingest(snapshot(100, 200), at: date("2026-10-31T15:59:59Z"), calendar: calendar)
        ledger.ingest(snapshot(110, 220), at: date("2026-10-31T16:00:01Z"), calendar: calendar)
        XCTAssertEqual(ledger.months["2026-10"]?.rows.first?.proxy.total, 300)
        XCTAssertEqual(ledger.months["2026-11"]?.rows.first?.proxy.total, 30)
    }
    func testCounterRegressionAndOldSnapshotsCannotInflateTotals() throws {
        var ledger = DomainTrafficLedger(); let t = date("2026-10-20T00:00:00Z")
        ledger.ingest(snapshot(100, 200), at: t, calendar: calendar)
        ledger.ingest(snapshot(20, 40), at: t.addingTimeInterval(10), calendar: calendar)
        ledger.ingest(snapshot(999, 999, session: "old"), at: t.addingTimeInterval(-10), calendar: calendar)
        ledger.ingest(snapshot(120, 240), at: t.addingTimeInterval(20), calendar: calendar)
        XCTAssertEqual(ledger.months["2026-10"]?.rows.first?.proxy.total, 360)
    }
    func testCapacityPreservesOtherAndUnknownBytesByRoute() throws {
        var ledger = DomainTrafficLedger(); let t = date("2026-10-20T00:00:00Z")
        let entries = (0..<600).map { DomainTrafficSnapshot.Entry(domain: "host\($0).com", route: "proxy", upload: 1, download: 2) }
            + [.init(domain: "1.2.3.4", route: "direct", upload: 10, download: 20)]
        ledger.ingest(.init(session: "A", entries: entries), at: t, calendar: calendar)
        let rows = try XCTUnwrap(ledger.months["2026-10"]?.rows)
        XCTAssertLessThanOrEqual(rows.count, 514)
        XCTAssertEqual(rows.reduce(Int64(0)) { $0 + $1.proxy.total }, 1800)
        XCTAssertEqual(rows.first { $0.domain == DomainTrafficLedger.unknownDomain }?.direct.total, 30)
        XCTAssertGreaterThan(rows.first { $0.domain == DomainTrafficLedger.otherDomain }?.proxy.total ?? 0, 0)
    }
    func testRetainsSixCalendarMonthsAndRejectsNegativeCounters() {
        var ledger = DomainTrafficLedger()
        for month in 1...8 {
            ledger.ingest(snapshot(10, 20, session: "s\(month)"), at: date(String(format: "2026-%02d-01T00:00:00Z", month)), calendar: calendar)
        }
        XCTAssertEqual(ledger.months.count, 6)
        XCTAssertNil(ledger.months["2026-01"])
        let before = ledger
        ledger.ingest(snapshot(-1, 3, session: "bad"), at: date("2026-08-02T00:00:00Z"), calendar: calendar)
        XCTAssertEqual(ledger, before)
    }
}
