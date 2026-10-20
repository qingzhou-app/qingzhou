import XCTest
import QingzhouCore
@testable import QingzhouSpeedTest

final class DirectProbeFailureTests: XCTestCase {
    struct Probe: LatencyProber {
        let failure: DirectProbeFailure
        func probe(_ url: URL, timeout: TimeInterval) async -> LatencyResult {
            .init(url: url, latencyMs: nil, failure: failure)
        }
    }
    func testDNSBatchRetainsAlternateAddressesAndIgnoresSyntheticOnes() {
        var batch = DirectAddressBatch()
        XCTAssertNil(batch.append("198.18.0.1", moreComing: true))
        XCTAssertNil(batch.append("192.0.2.1", moreComing: true))
        XCTAssertEqual(batch.append("192.0.2.2", moreComing: false), .success(["192.0.2.1", "192.0.2.2"]))
    }
    func testFirstAddressFailureFallsBackWithinBudget() async {
        let url = URL(string: "tcp://multi.example:443")!
        let result = await TCPConnectLatencyProber.connectAddresses(["192.0.2.1", "192.0.2.2"], url: url, timeout: 5) { address, budget in
            XCTAssertGreaterThan(budget, 0)
            XCTAssertLessThanOrEqual(budget, 5)
            return address == "192.0.2.1" ? .init(url: url, latencyMs: nil, failure: .refused) : .init(url: url, latencyMs: 36)
        }
        XCTAssertEqual(result.latencyMs, 36)
        XCTAssertNil(result.failure)
    }

    func testFakeDNSLiteralIsRejectedBeforeTCP() async {
        let result = await TCPConnectLatencyProber().probe(URL(string: "tcp://198.19.255.254:443")!, timeout: 0.1)
        XCTAssertEqual(result.failure, .syntheticAddress)
        XCTAssertNil(result.latencyMs)
        XCTAssertFalse(result.isNodeObservation)
    }
    func testUnknownEnvironmentDoesNotErasePreviousNodeObservation() async {
        let date = Date(timeIntervalSince1970: 123)
        let node = Node(name: "A", protocolType: .trojan, host: "a.example", port: 443,
                        lastLatencyMs: 42, lastTestedAt: date)
        let selector = NodeSelector(prober: Probe(failure: .noPhysicalInterface))
        let result = await selector.measure(nodes: [node])
        XCTAssertEqual(result[0].lastLatencyMs, 42)
        XCTAssertEqual(result[0].lastTestedAt, date)
        let burst = await NodeSelector.burstProbe(URL(string: "tcp://a.example:443")!, prober: Probe(failure: .noPhysicalInterface), timeout: 1)
        XCTAssertNil(burst.lossFraction)
        XCTAssertEqual(burst.failure, .noPhysicalInterface)
    }
    func testTimeoutStillCountsAsFailedTCPAttempt() async {
        let result = await NodeSelector.burstProbe(URL(string: "tcp://a.example:443")!, prober: Probe(failure: .timeout), timeout: 1)
        XCTAssertEqual(result.lossFraction, 1)
        XCTAssertTrue(result.isNodeObservation)
    }
    func testAlreadyCancelledProbeDoesNotStartNetworkWork() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await TCPConnectLatencyProber().probe(URL(string: "tcp://127.0.0.1:9")!, timeout: 5)
        }
        let result = await task.value
        XCTAssertEqual(result.failure, .cancelled)
    }
}
