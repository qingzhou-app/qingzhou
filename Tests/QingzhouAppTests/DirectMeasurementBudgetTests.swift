import XCTest
import QingzhouCore
import QingzhouSpeedTest
@testable import QingzhouApp

@MainActor
final class DirectMeasurementBudgetTests: XCTestCase {
    actor Probe: LatencyProber {
        var hosts: [String] = []
        func probe(_ url: URL, timeout: TimeInterval) async -> LatencyResult {
            hosts.append(url.host ?? "")
            return .init(url: url, latencyMs: 50)
        }
        func takeHosts() -> [String] { defer { hosts = [] }; return hosts }
    }
    private func make(_ probe: any LatencyProber, concurrency: Int = 8) -> AppState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = AppState(persistence: Persistence(directory: directory), nodeSelector: NodeSelector(prober: probe, maxConcurrent: concurrency))
        app.settings.iCloudSyncEnabled = false
        app.settings.autoSelectUsesProxiedLatency = false
        addTeardownBlock { app.persistence.waitForPendingWritesForTesting(); try? FileManager.default.removeItem(at: directory) }
        return app
    }
    private func node(_ i: Int) -> Node {
        Node(name: "N\(i)", protocolType: .trojan, host: "n\(i).example", port: 443, password: "pw")
    }


    private actor GatedProbe: LatencyProber {
        let gate: CloudIOGate
        var calls = 0
        init(_ gate: CloudIOGate) { self.gate = gate }
        func probe(_ url: URL, timeout: TimeInterval) async -> LatencyResult {
            calls += 1
            if calls == 1 { await gate.suspend() }
            return .init(url: url, latencyMs: 50)
        }
    }
    private actor ChangingProbe: LatencyProber {
        var failing = false
        func failChallenger() { failing = true }
        func probe(_ url: URL, timeout: TimeInterval) async -> LatencyResult {
            .init(url: url, latencyMs: url.host == "n0.example" ? 600 : (failing ? nil : 10))
        }
    }
    private actor TableProbe: LatencyProber {
        var values: [String: Int] = [:]
        func set(_ values: [String: Int]) { self.values = values }
        func probe(_ url: URL, timeout: TimeInterval) async -> LatencyResult { .init(url: url, latencyMs: values[url.host ?? ""]) }
    }
    func testReenabledAliasCannotResurrectSuccessOlderThanIdentityFailure() async {
        let probe = TableProbe(), app = make(probe)
        let a = node(0), c = node(2)
        var alias = a; alias.id = UUID(); alias.name = "Alias"
        app.nodes = [a, alias, c]; app.currentNodeId = c.id
        await probe.set([a.host: 20, c.host: 600]); await app.measureAllNodes()
        app.nodes[1].isExcluded = true
        await probe.set([:]); await app.measureAllNodes()
        app.nodes[1].isExcluded = false
        await app.autoSelectBestNode(origin: .scheduled, applySelection: {})
        XCTAssertEqual(app.currentNodeId, c.id)
        XCTAssertNil(app.nodes[1].lastLatencyMs)
        XCTAssertEqual(app.nodeMetricsHistory.samples(for: a.identityFingerprint).count, 2)
    }
    func testTwoRoundLeadRequiresAnotherChallengerMeasurement() async {
        let probe = ChangingProbe(), app = make(probe)
        app.nodes = [node(0), node(1)]; app.currentNodeId = app.nodes[0].id
        app.isVPNRunning = true
        await app.autoSelectBestNode(origin: .scheduled, applySelection: {})
        XCTAssertEqual(app.lastSelectionReport?.reason, .confirmingLead(completed: 1, required: 2))
        await probe.failChallenger()
        await app.autoSelectBestNode(origin: .scheduled, applySelection: {})
        XCTAssertEqual(app.currentNodeId, app.nodes[0].id)
        XCTAssertNil(app.nodes[1].lastLatencyMs, "复用同一旧结果不能算独立的第二轮领先")
    }
    func testPathChangeStopsStartingMoreTCPHandshakes() async {
        let gate = CloudIOGate(), probe = GatedProbe(gate)
        let app = make(probe, concurrency: 1)
        app.nodes = (0..<40).map(node)
        let task = Task { await app.autoSelectBestNode(origin: .scheduled) }
        await gate.waitUntilEntered()
        app.measurementNetworkDidChange()
        await gate.resume(); await task.value
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(app.nodeMetricsHistory.samples.isEmpty)
        XCTAssertEqual(app.lastSelectionReport?.reason, .networkChanged)
    }

    func testAliasesShareOneBurstAndOneHistorySampleButBothRowsUpdate() async {
        let probe = Probe(), app = make(probe)
        let n = node(0)
        var alias = n; alias.id = UUID(); alias.name = "Alias"
        app.nodes = [n, alias]
        await app.measureAllNodes()
        let calls = await probe.takeHosts()
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(app.nodes.map(\.lastLatencyMs), [50, 50])
        XCTAssertEqual(app.nodeMetricsHistory.samples(for: n.identityFingerprint).count, 1)
    }

    func testScheduledBudgetRotatesUnmeasuredNodesAndAlwaysChecksIncumbent() async {
        let probe = Probe(), app = make(probe)
        app.nodes = (0..<80).map(node)
        app.currentNodeId = app.nodes[79].id
        let incumbentHost = app.nodes[79].host
        var coverage: Set<String> = []
        for _ in 0..<4 {
            await app.autoSelectBestNode(origin: .scheduled)
            let hosts = await probe.takeHosts()
            XCTAssertLessThanOrEqual(hosts.count, 72)
            XCTAssertTrue(hosts.contains(incumbentHost))
            coverage.formUnion(hosts)
            // 固定当前节点，让覆盖断言与评分平分时的选择无关。
            app.currentNodeId = app.nodes[79].id
        }
        XCTAssertEqual(coverage.count, 80)
    }

    func testManualMeasurementRemainsFullAcrossUniqueConfigurations() async {
        let probe = Probe(), app = make(probe)
        app.nodes = (0..<40).map(node)
        await app.measureAllNodes()
        let calls = await probe.takeHosts()
        XCTAssertEqual(calls.count, 120)
        XCTAssertEqual(Set(calls).count, 40)
    }

    func testScheduledRoundDoesNotProbeExcludedRegion() async {
        let probe = Probe(), app = make(probe)
        var excluded = node(0); excluded.name = "🇯🇵 Japan"
        app.nodes = [excluded, node(1)]
        app.settings.excludedRegions = [excluded.region]
        await app.autoSelectBestNode(origin: .scheduled)
        let calls = await probe.takeHosts()
        XCTAssertFalse(calls.contains(excluded.host))
    }
}
