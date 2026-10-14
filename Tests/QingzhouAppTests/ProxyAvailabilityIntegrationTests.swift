import XCTest
import QingzhouCore
import QingzhouSpeedTest
@testable import QingzhouApp

@MainActor
final class ProxyAvailabilityIntegrationTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }
    private struct Direct: LatencyProber {
        func probe(_ url: URL, timeout: TimeInterval) async -> LatencyResult { .init(url: url, latencyMs: 50) }
    }
    private struct Proxy: ProxiedLatencyProbing {
        let run: @MainActor (Node, String?) async throws -> Int
        func pingNode(node: Node, targetURL: String?, timeoutSeconds: Int) async throws -> Int { try await run(node, targetURL) }
    }
    private func make(_ probe: Proxy) -> AppState {
        let app = AppState(persistence: Persistence(directory: directory), nodeSelector: NodeSelector(prober: Direct()), proxiedProber: probe)
        app.settings.iCloudSyncEnabled = false
        app.settings.autoSelectUsesProxiedLatency = true
        app.isVPNRunning = true
        return app
    }
    private func node(_ name: String) -> Node { Node(name: name, protocolType: .trojan, host: name + ".example", port: 443, password: "pw") }

    func testScheduledRecoveryBypassesScoreWaitOnlyAfterConfirmedFailure() async throws {
        let a = node("A"), b = node("B")
        let app = make(Proxy { n, _ in
            if n.id == a.id { throw ProxyProbeError(kind: .probeFailed, message: "failed") }
            return 200
        })
        app.nodes = [a, b]; app.currentNodeId = a.id
        await app.autoSelectBestNode(origin: .scheduled)
        XCTAssertEqual(app.currentNodeId, b.id)
        XCTAssertEqual(app.lastSelectionReport?.reason, .availabilityRecovery)
        XCTAssertEqual(app.lastSelectionReport?.proxy.confirmedFailureCount, 1)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testAllFailedWithNoSelectionDoesNotInventVerifiedWinner() async {
        let app = make(Proxy { _, _ in throw ProxyProbeError(kind: .probeFailed, message: "failed") })
        app.nodes = [node("A"), node("B")]
        await app.autoSelectBestNode()
        XCTAssertNil(app.currentNodeId)
        XCTAssertEqual(app.lastSelectionReport?.reason, .proxyUnverified)
        XCTAssertFalse(app.nodeProbeCooldown.contains(app.nodes[0].identityFingerprint))
        app.persistence.waitForPendingWritesForTesting()
    }

    func testIdentityChangedDuringProbeDoesNotReceiveStaleMeasurement() async {
        let gate = CloudIOGate()
        let app = make(Proxy { _, _ in await gate.suspend(); return 40 })
        let a = node("A"); app.nodes = [a]
        let task = Task { await app.measureProxiedLatency(a, showToastOnError: false) }
        await gate.waitUntilEntered()
        app.nodes[0].password = "new-password"
        await gate.resume()
        let value = await task.value
        XCTAssertNil(value)
        XCTAssertNil(app.nodes[0].lastProxiedLatencyMs)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testCancellationDoesNotClearOldMeasurement() async {
        let gate = CloudIOGate()
        let app = make(Proxy { _, _ in await gate.suspend(); throw CancellationError() })
        var a = node("A"); a.lastProxiedLatencyMs = 90
        app.nodes = [a]
        let task = Task { await app.measureProxiedLatency(a, showToastOnError: false) }
        await gate.waitUntilEntered(); task.cancel(); await gate.resume(); _ = await task.value
        XCTAssertEqual(app.nodes[0].lastProxiedLatencyMs, 90)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testUDPCurrentNodeIsProbedWithoutTCPMeasurement() async {
        let app = make(Proxy { _, _ in 80 })
        let a = node("A"), b = node("B")
        app.nodes = [a, b]; app.currentNodeId = b.id
        app.settings.preferredRegion = nil
        // UDP 当前节点没有 TCP 数值，仍需代理测量。
        app.nodes[1].protocolType = .hysteria2
        await app.autoSelectBestNode(origin: .scheduled)
        XCTAssertNotNil(app.nodes[1].lastProxiedLatencyMs)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testRestartDuringProbeRejectsOldSessionSuccess() async {
        let gate = CloudIOGate()
        let app = make(Proxy { _, _ in await gate.suspend(); return 40 })
        let a = node("A"); app.nodes = [a]
        let task = Task { await app.measureProxiedLatency(a, showToastOnError: false) }
        await gate.waitUntilEntered()
        app.isVPNRunning = false; app.isVPNRunning = true
        await gate.resume()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertNil(app.nodes[0].lastProxiedLatencyMs)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testCompletedSwitchDuringRoundKeepsOriginalSelection() async {
        let gate = CloudIOGate()
        let a = node("A"), b = node("B")
        var first = true
        let app = make(Proxy { node, _ in
            if first { first = false; await gate.suspend() }
            return node.id == a.id ? 20 : 600
        })
        app.nodes = [a, b]; app.currentNodeId = b.id
        let task = Task { await app.autoSelectBestNode() }
        await gate.waitUntilEntered()
        app.isSwitchingTunnel = true; app.isSwitchingTunnel = false
        await gate.resume(); await task.value
        XCTAssertEqual(app.currentNodeId, b.id)
        XCTAssertNil(app.nodes[0].lastProxiedLatencyMs)
        XCTAssertEqual(app.lastSelectionReport?.proxy.state, .interrupted)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testScheduledCooldownSkipsCandidateButManualRoundCanRecoverIt() async {
        let a = node("A"), b = node("B")
        let app = make(Proxy { _, _ in 80 })
        app.nodes = [a, b]; app.currentNodeId = b.id
        app.nodeProbeCooldown.confirm([a.identityFingerprint])
        await app.autoSelectBestNode(origin: .scheduled)
        XCTAssertNil(app.nodes[0].lastProxiedLatencyMs)
        XCTAssertEqual(app.lastSelectionReport?.proxy.coolingDownCount, 1)
        await app.autoSelectBestNode()
        XCTAssertEqual(app.nodes[0].lastProxiedLatencyMs, 80)
        XCTAssertFalse(app.nodeProbeCooldown.contains(a.identityFingerprint))
        app.persistence.waitForPendingWritesForTesting()
    }

    func testNewerMeasurementWinsOverDelayedOlderMeasurement() async {
        let gate = CloudIOGate()
        var first = true
        let app = make(Proxy { _, _ in
            if first { first = false; await gate.suspend(); return 600 }
            return 80
        })
        let a = node("A"); app.nodes = [a]
        let task = Task { await app.measureProxiedLatency(a, showToastOnError: false) }
        await gate.waitUntilEntered()
        _ = await app.measureProxiedLatency(a, showToastOnError: false)
        await gate.resume(); _ = await task.value
        XCTAssertEqual(app.nodes[0].lastProxiedLatencyMs, 80)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testManualRetestDuringLaterCandidateInvalidatesWholeRound() async {
        let gate = CloudIOGate()
        let a = node("A"), b = node("B")
        var aCount = 0
        let app = make(Proxy { node, _ in
            if node.id == b.id { await gate.suspend(); return 600 }
            aCount += 1
            if aCount == 1 { return 20 }
            throw ProxyProbeError(kind: .probeFailed, message: "new failure")
        })
        app.nodes = [a, b]; app.currentNodeId = b.id
        let task = Task { await app.autoSelectBestNode() }
        await gate.waitUntilEntered()
        _ = await app.measureProxiedLatency(a, showToastOnError: false)
        await gate.resume(); await task.value
        XCTAssertEqual(app.currentNodeId, b.id)
        XCTAssertEqual(app.lastSelectionReport?.proxy.state, .interrupted)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testDisablingRefinementDuringProbeDoesNotRestoreClearedValues() async {
        let gate = CloudIOGate()
        let app = make(Proxy { _, _ in await gate.suspend(); return 40 })
        let a = node("A"); app.nodes = [a]
        let task = Task { await app.autoSelectBestNode() }
        await gate.waitUntilEntered()
        app.setAutoSelectUsesProxiedLatency(false)
        await gate.resume(); await task.value
        XCTAssertNil(app.currentNodeId)
        XCTAssertNil(app.nodes[0].lastProxiedLatencyMs)
        XCTAssertEqual(app.lastSelectionReport?.proxy.state, .interrupted)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testRemovedSuccessWitnessCannotJustifyCooldown() async {
        let gate = CloudIOGate()
        let a = node("A"), b = node("B"), c = node("C")
        let app = make(Proxy { n, target in
            if n.id == c.id { return 80 }
            if n.id == b.id, target != ConnectivityProbe.defaultProxiedTarget { await gate.suspend() }
            throw ProxyProbeError(kind: .probeFailed, message: "failed")
        })
        app.nodes = [a, b, c]; app.currentNodeId = a.id
        let task = Task { await app.autoSelectBestNode(origin: .scheduled) }
        await gate.waitUntilEntered()
        app.nodes.removeAll { $0.id == c.id }
        await gate.resume(); await task.value
        XCTAssertFalse(app.nodeProbeCooldown.contains(a.identityFingerprint))
        XCTAssertEqual(app.lastSelectionReport?.proxy.confirmedFailureCount, 0)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testInPlaceSwitchPreservesCooldownWhileInvalidatingOldProbes() {
        let app = make(Proxy { _, _ in 80 })
        let a = node("A"); app.nodes = [a]
        app.nodeProbeCooldown.confirm([a.identityFingerprint])
        app.isSwitchingTunnel = true; app.isSwitchingTunnel = false
        XCTAssertTrue(app.nodeProbeCooldown.contains(a.identityFingerprint))
        app.isVPNRunning = false
        XCTAssertFalse(app.nodeProbeCooldown.contains(a.identityFingerprint))
    }

    func testSuccessfulManualRetestReleasesCooldown() async {
        let app = make(Proxy { _, _ in 80 })
        let a = node("A"); app.nodes = [a]
        app.nodeProbeCooldown.confirm([a.identityFingerprint])
        _ = await app.measureProxiedLatency(a, showToastOnError: false)
        XCTAssertFalse(app.nodeProbeCooldown.contains(a.identityFingerprint))
        app.persistence.waitForPendingWritesForTesting()
    }
}
