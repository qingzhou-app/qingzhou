import XCTest
import QingzhouCore

final class RecentBandwidthTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    func testIsolatedSpikeDoesNotBecomePermanentScore() {
        var window = RecentBandwidth()
        for (minute, value) in [1_000_000, 1_000_000, 90_000_000].enumerated() {
            window.record(bytesPerSecond: Int64(value), at: start.addingTimeInterval(Double(minute * 60)))
        }
        XCTAssertEqual(window.estimate(at: start.addingTimeInterval(120)), 1_000_000)
        XCTAssertNil(window.estimate(at: start.addingTimeInterval(32 * 60)))
    }
    func testIdleSamplesAndRepeatedSameMinuteCannotCreateConfidence() {
        var window = RecentBandwidth()
        for second in 0..<50 { window.record(bytesPerSecond: 2_000_000, at: start.addingTimeInterval(Double(second))) }
        for minute in 1...10 { window.record(bytesPerSecond: 50_000, at: start.addingTimeInterval(Double(minute * 60))) }
        XCTAssertNil(window.estimate(at: start.addingTimeInterval(600)))
    }
    func testRecentSlowerActivityReplacesExpiredFastPeriod() {
        var window = RecentBandwidth()
        for minute in 0..<3 { window.record(bytesPerSecond: 8_000_000, at: start.addingTimeInterval(Double(minute * 60))) }
        for minute in 33..<36 { window.record(bytesPerSecond: 1_000_000, at: start.addingTimeInterval(Double(minute * 60))) }
        XCTAssertEqual(window.estimate(at: start.addingTimeInterval(35 * 60)), 1_000_000)
    }
    func testClockRollbackCannotUseFutureBuckets() {
        var window = RecentBandwidth()
        for minute in 0..<3 { window.record(bytesPerSecond: 8_000_000, at: start.addingTimeInterval(Double(minute * 60))) }
        XCTAssertNil(window.estimate(at: start.addingTimeInterval(-1)))
    }
}
