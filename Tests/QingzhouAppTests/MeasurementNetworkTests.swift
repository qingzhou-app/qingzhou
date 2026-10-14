import XCTest
import QingzhouCore
import QingzhouSpeedTest
@testable import QingzhouApp

@MainActor
final class MeasurementNetworkTests: XCTestCase {
    private actor Direct: LatencyProber {
        var gate: CloudIOGate?
        init(gate: CloudIOGate? = nil) { self.gate = gate }
        func probe(_ url: URL, timeout: TimeInterval) async -> LatencyResult {
            if let pending = gate { gate = nil; await pending.suspend() }
            return .init(url: url, latencyMs: 50)
        }
    }
    private struct Proxy: ProxiedLatencyProbing {
        let gate: CloudIOGate
        func pingNode(node: Node, targetURL: String?, timeoutSeconds: Int) async throws -> Int {
            await gate.suspend(); return 40
        }
    }
    private func make(direct: Direct = .init(), proxy: Proxy? = nil) -> AppState {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = AppState(persistence: Persistence(directory: dir), nodeSelector: NodeSelector(prober: direct), proxiedProber: proxy)
        app.settings.iCloudSyncEnabled = false
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return app
    }
    private func node() -> Node {
        Node(name: "A", protocolType: .trojan, host: "a.example", port: 443, password: "pw", lastLatencyMs: 50,
             lastProxiedLatencyMs: 40, lastProxiedTestedAt: Date(), observedPeakDownBps: 9_000_000)
    }

    func testPathChangeClearsMeasurementsAndCooldownButKeepsSelection() {
        let app = make(), n = node()
        app.nodes = [n]; app.currentNodeId = n.id
        app.nodeProbeCooldown.confirm([n.identityFingerprint])
        for _ in 0..<3 { app.recordNodeDirectMeasurement(n, latencyMs: 50, at: Date()) }
        app.measurementNetworkDidChange()
        XCTAssertNil(app.nodes[0].lastLatencyMs)
        XCTAssertNil(app.nodes[0].lastProxiedLatencyMs)
        XCTAssertNil(app.nodes[0].observedPeakDownBps)
        XCTAssertEqual(app.scoreForAutoSelect(app.nodes[0]).stability.score, 70)
        XCTAssertFalse(app.nodeProbeCooldown.contains(n.identityFingerprint))
        XCTAssertEqual(app.currentNodeId, n.id)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testDirectReplyFromPreviousNetworkCannotSelectOrWriteHistory() async {
        let gate = CloudIOGate(), app = make(direct: .init(gate: gate))
        var n = node(); n.lastLatencyMs = nil; app.nodes = [n]
        app.settings.autoSelectUsesProxiedLatency = false
        let task = Task { await app.autoSelectBestNode() }
        await gate.waitUntilEntered(); app.measurementNetworkDidChange(); await gate.resume(); await task.value
        XCTAssertNil(app.currentNodeId)
        XCTAssertNil(app.nodes[0].lastLatencyMs)
        XCTAssertTrue(app.nodeMetricsHistory.samples(for: n.identityFingerprint).isEmpty)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testProxyReplyFromPreviousNetworkCannotWriteBack() async {
        let gate = CloudIOGate(), app = make(proxy: .init(gate: gate)), n = node()
        app.nodes = [n]; app.isVPNRunning = true
        let task = Task { await app.measureProxiedLatency(n, showToastOnError: false) }
        await gate.waitUntilEntered(); app.measurementNetworkDidChange(); await gate.resume()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertNil(app.nodes[0].lastProxiedLatencyMs)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testSavingDraftCannotRevivePreviousNetworkMeasurements() {
        let app = make(), n = node()
        app.nodes = [n]
        app.measurementNetworkDidChange()
        var draft = n; draft.name = "Renamed"
        app.updateNode(draft)
        XCTAssertEqual(app.nodes[0].name, "Renamed")
        XCTAssertNil(app.nodes[0].lastLatencyMs)
        XCTAssertNil(app.nodes[0].lastProxiedLatencyMs)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testEditingConnectionIdentityCannotInheritOldMeasurements() {
        let app = make(), n = node()
        app.nodes = [n]
        var draft = n; draft.password = "changed"
        app.updateNode(draft)
        XCTAssertNil(app.nodes[0].lastLatencyMs)
        XCTAssertNil(app.nodes[0].lastProxiedLatencyMs)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testLegacyCloudRestoreDiscardsForeignNetworkMeasurements() async {
        let app = make()
        var n = node(); n.protocolType = .hysteria2
        var snapshot = app.persistence.loadSnapshot()
        snapshot.nodes = [n]; snapshot.currentNodeId = n.id; snapshot.settings.iCloudSyncEnabled = false
        let saved = app.applyCloudSnapshot(VaultDocument(revision: 1, modifiedAt: Date(), deviceName: "Other", snapshot: snapshot))
        XCTAssertNil(app.nodes[0].lastLatencyMs)
        XCTAssertNil(app.nodes[0].lastProxiedLatencyMs)
        XCTAssertNil(app.nodes[0].observedPeakDownBps)
        XCTAssertFalse(app.hasUsableSelectionMeasurement(app.nodes[0]))
        _ = await saved.value
    }

    func testRestartDoesNotRankPersistedMeasurementsFromUnknownNetwork() {
        let app = make(), n = node()
        app.nodes = [n]; app.persist(); app.persistence.waitForPendingWritesForTesting()
        let reloaded = AppState(persistence: app.persistence)
        XCTAssertNil(reloaded.pickBestRespectingRegions(from: reloaded.nodes))
        XCTAssertNil(reloaded.nodes[0].observedPeakDownBps)
    }
}
