import XCTest
@testable import QingzhouCore

final class MeasurementFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testProxyInfluenceHalvesAfterSixHours() {
        let input = NodeScorer.Input(directLatencyMs: 100, proxiedLatencyMs: 100,
            proxiedTestedAt: now.addingTimeInterval(-6 * 3600))
        XCTAssertEqual(NodeScorer.score(input, now: now).latency.score, 80.125, accuracy: 0.0001)
    }

    func testFutureProxyTimestampCannotClaimFreshMeasurement() {
        let input = NodeScorer.Input(directLatencyMs: 100, proxiedLatencyMs: 50,
            proxiedTestedAt: now.addingTimeInterval(60))
        XCTAssertEqual(NodeScorer.score(input, now: now).latency.score, 77.5)
    }

    func testOldPerfectHistoryReturnsToNeutral() {
        let history = Array(repeating: NodeMetricSample(at: now.addingTimeInterval(-25 * 3600), latencyMs: 50), count: 10)
        XCTAssertEqual(NodeScorer.score(.init(history: history), now: now).stability.score, 70)
    }

    func testRecentFailuresOutweighOldSuccesses() {
        let old = Array(repeating: NodeMetricSample(at: now.addingTimeInterval(-18 * 3600), latencyMs: 50), count: 3)
        let recent = Array(repeating: NodeMetricSample(at: now), count: 3)
        let score = NodeScorer.score(.init(history: old + recent), now: now).stability.score
        XCTAssertLessThan(score, 45)
        XCTAssertGreaterThan(score, 0, "Old evidence loses confidence as well as weight")
    }

    func testFutureAndExpiredHistoryCannotMeetMinimumSampleCount() {
        let history = [NodeMetricSample(at: now, latencyMs: 50),
            NodeMetricSample(at: now.addingTimeInterval(1), latencyMs: 50),
            NodeMetricSample(at: now.addingTimeInterval(-25 * 3600), latencyMs: 50)]
        XCTAssertEqual(NodeScorer.score(.init(history: history), now: now).stability.score, 70)
    }
}
