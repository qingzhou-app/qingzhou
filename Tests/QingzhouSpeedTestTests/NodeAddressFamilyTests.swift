import XCTest
@testable import QingzhouSpeedTest

final class NodeAddressFamilyTests: XCTestCase {
    private let target = URL(string: "tcp://node.example:443")!
    func testIPv6OnlyNodeGetsAAAAFallback() async {
        let url = target
        let result = await TCPConnectLatencyProber.probeAddressFamilies(url: url, timeout: 1) { ipv6, _ in
            ipv6 ? .init(url: url, latencyMs: 42) : .init(url: url, latencyMs: nil, failure: .dnsFailed)
        }
        XCTAssertEqual(result.latencyMs, 42)
    }
    func testSlowAbsentARecordDoesNotConsumeAAAAOpportunity() async {
        let url = target
        let result = await TCPConnectLatencyProber.probeAddressFamilies(url: url, timeout: 0.5) { ipv6, budget in
            if ipv6 { return .init(url: url, latencyMs: 42) }
            try? await Task.sleep(for: .seconds(budget))
            return .init(url: url, latencyMs: nil, failure: .dnsFailed)
        }
        XCTAssertEqual(result.latencyMs, 42)
    }
    func testFastAAAADNSMustNotDiscardWorkingIPv4Path() async {
        let url = target
        let result = await TCPConnectLatencyProber.probeAddressFamilies(url: url, timeout: 1) { ipv6, _ in
            if ipv6 { return .init(url: url, latencyMs: nil, failure: .networkUnavailable) }
            try? await Task.sleep(for: .milliseconds(300))
            return .init(url: url, latencyMs: 42)
        }
        XCTAssertEqual(result.latencyMs, 42)
    }
    func testImmediateIPv4SuccessAndSyntheticFailureCancelDelayedFamily() async {
        let url = target
        let success = await TCPConnectLatencyProber.probeAddressFamilies(url: url, timeout: 1) { ipv6, _ in
            if ipv6 { XCTFail("Fast IPv4 success needs no extra lookup") }
            return .init(url: url, latencyMs: 42)
        }
        XCTAssertEqual(success.latencyMs, 42)
        let synthetic = await TCPConnectLatencyProber.probeAddressFamilies(url: url, timeout: 1) { ipv6, _ in
            if ipv6 { XCTFail("Retain synthetic address protection") }
            return .init(url: url, latencyMs: nil, failure: .syntheticAddress)
        }
        XCTAssertEqual(synthetic.failure, .syntheticAddress)
    }
    func testMissingOtherFamilyDNSCannotEraseActualHandshakeFailure() async {
        let url = target
        let result = await TCPConnectLatencyProber.probeAddressFamilies(url: url, timeout: 1) { ipv6, _ in
            .init(url: url, latencyMs: nil, failure: ipv6 ? .dnsFailed : .timeout)
        }
        XCTAssertEqual(result.failure, .timeout)
    }
}
