import XCTest
import QingzhouCore

final class MeasurementHistoryContextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testHistoryClusteringSeparatesNetworksInsideSameTimeWindow() {
        var history = NodeMetricsHistory()
        history.recordDirect(fingerprint: "n", latencyMs: 50, at: now, networkID: UUID())
        history.recordDirect(fingerprint: "n", latencyMs: 200, at: now.addingTimeInterval(10), networkID: UUID())
        let rounds = SelectionReplay.rounds(from: history)
        XCTAssertEqual(rounds.count, 2)
        XCTAssertEqual(rounds.last?.observations["n"]?.directMs, 200)
    }
    func testSameSecondNetworksFormTwoCompleteRounds() {
        let a = UUID(), b = UUID()
        var history = NodeMetricsHistory()
        for node in ["a", "b"] {
            history.recordDirect(fingerprint: node, latencyMs: 50, at: now, networkID: a)
            history.recordDirect(fingerprint: node, latencyMs: 200, at: now, networkID: b)
        }
        let rounds = SelectionReplay.rounds(from: history)
        XCTAssertEqual(rounds.count, 2)
        XCTAssertTrue(rounds.allSatisfy { $0.observations.count == 2 })
    }

    func testProxyMergeDoesNotCrossNetworkOrGoBackInTime() {
        let a = UUID(), b = UUID()
        var history = NodeMetricsHistory()
        history.recordDirect(fingerprint: "n", latencyMs: 50, at: now, networkID: a)
        history.recordProxied(fingerprint: "n", proxiedMs: 200, at: now.addingTimeInterval(10), networkID: b)
        history.recordProxied(fingerprint: "n", proxiedMs: 20, at: now, networkID: b)
        XCTAssertEqual(history.samples(for: "n").count, 3)
        XCTAssertNil(history.samples(for: "n", networkID: a).first?.proxiedMs)
        XCTAssertEqual(history.samples(for: "n", networkID: b).count, 2)
    }
    func testLegacyHistoryDecodesButDoesNotEnterCurrentNetwork() throws {
        let data = Data(#"{"samples":{"n":[{"at":0,"latencyMs":50}]}}"#.utf8)
        let history = try JSONDecoder().decode(NodeMetricsHistory.self, from: data)
        XCTAssertEqual(history.samples(for: "n").count, 1)
        XCTAssertTrue(history.samples(for: "n", networkID: UUID()).isEmpty)
    }
}
