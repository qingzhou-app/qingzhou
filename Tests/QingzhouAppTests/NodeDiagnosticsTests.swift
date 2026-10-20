import XCTest
import QingzhouCore
import QingzhouSpeedTest
@testable import QingzhouApp

@MainActor
final class NodeDiagnosticsTests: XCTestCase {
    private struct Direct: LatencyProber {
        let run: @Sendable (URL) async -> LatencyResult
        func probe(_ url: URL, timeout: TimeInterval) async -> LatencyResult { await run(url) }
    }
    private struct Proxy: ProxiedLatencyProbing {
        let run: @MainActor () async throws -> Int
        func pingNode(node: Node, targetURL: String?, timeoutSeconds: Int) async throws -> Int { try await run() }
    }
    private func make(direct: Direct = Direct { .init(url: $0, latencyMs: 42) }, proxy: Proxy = Proxy { 80 }) -> AppState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = AppState(persistence: Persistence(directory: directory), nodeSelector: NodeSelector(prober: direct), proxiedProber: proxy)
        app.settings.iCloudSyncEnabled = false
        app.nodes = [Node(name: "private-label", protocolType: .trojan, host: "private.example", port: 443, password: "secret-password")]
        addTeardownBlock { app.persistence.waitForPendingWritesForTesting(); try? FileManager.default.removeItem(at: directory) }
        return app
    }
    func testReportSeparatesTCPFromProxyAndContainsNoPrivateFields() async throws {
        let app = make(proxy: Proxy { throw ProxyProbeError(kind: .probeFailed, message: "secret-password private.example") })
        app.isVPNRunning = true
        let result = await app.diagnoseNode(app.nodes[0])
        let report = try XCTUnwrap(result)
        XCTAssertEqual(report.directLatencyMs, 42)
        XCTAssertEqual(report.proxyOutcome, .failure(.probeFailed))
        XCTAssertEqual(report.conclusion, .proxyFailed)
        for secret in ["private-label", "private.example", "secret-password", app.nodes[0].id.uuidString] {
            XCTAssertFalse(report.sanitizedText.contains(secret))
        }
        XCTAssertTrue(report.sanitizedText.contains("tcp_ms=42"))
    }
    func testUDPDiagnosticSkipsTCPAndVerifiesProxy() async throws {
        let app = make(direct: Direct { url in XCTFail("UDP must not be TCP-probed"); return .init(url: url, latencyMs: 1) })
        app.nodes[0].protocolType = .hysteria2; app.isVPNRunning = true
        let result = await app.diagnoseNode(app.nodes[0])
        let report = try XCTUnwrap(result)
        XCTAssertNil(report.directLatencyMs)
        XCTAssertEqual(report.proxyOutcome, .success(80))
        XCTAssertEqual(report.conclusion, .proxySucceeded)
    }
    func testVPNOffReportDoesNotPretendTCPMeansInternetWorks() async throws {
        let app = make(proxy: Proxy { XCTFail("VPN off"); return 1 })
        let result = await app.diagnoseNode(app.nodes[0])
        let report = try XCTUnwrap(result)
        XCTAssertEqual(report.conclusion, .proxyNotTested)
        XCTAssertNil(report.proxyOutcome)
    }
    func testNetworkChangeDiscardsReportBeforeProxyStage() async {
        let gate = CloudIOGate()
        let app = make(direct: Direct { url in await gate.suspend(); return .init(url: url, latencyMs: 42) }, proxy: Proxy { XCTFail("stale"); return 1 })
        let node = app.nodes[0]
        let task = Task { await app.diagnoseNode(node) }
        await gate.waitUntilEntered(); app.measurementNetworkDidChange(); await gate.resume()
        let result = await task.value
        XCTAssertNil(result)
    }
    func testNodeEditDiscardsLateProxyResult() async {
        let gate = CloudIOGate()
        let app = make(proxy: Proxy { await gate.suspend(); return 80 }); app.isVPNRunning = true
        let node = app.nodes[0]
        let task = Task { await app.diagnoseNode(node) }
        await gate.waitUntilEntered(); app.nodes[0].password = "changed"; await gate.resume()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertNil(app.nodes[0].lastProxiedTestedAt)
    }
    func testCancellationDiscardsLateProxyResult() async {
        let gate = CloudIOGate()
        let app = make(proxy: Proxy { await gate.suspend(); return 80 }); app.isVPNRunning = true
        let node = app.nodes[0]
        let task = Task { await app.diagnoseNode(node) }
        await gate.waitUntilEntered(); task.cancel(); await gate.resume()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertNil(app.nodes[0].lastProxiedTestedAt)
    }
    func testStoppingVPNDiscardsLateProxyResult() async {
        let gate = CloudIOGate()
        let app = make(proxy: Proxy { await gate.suspend(); return 80 }); app.isVPNRunning = true
        let node = app.nodes[0]
        let task = Task { await app.diagnoseNode(node) }
        await gate.waitUntilEntered(); app.isVPNRunning = false; await gate.resume()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertNil(app.nodes[0].lastProxiedTestedAt)
    }
    func testDeletingNodeDiscardsLateProxyResult() async {
        let gate = CloudIOGate()
        let app = make(proxy: Proxy { await gate.suspend(); return 80 }); app.isVPNRunning = true
        let node = app.nodes[0]
        let task = Task { await app.diagnoseNode(node) }
        await gate.waitUntilEntered(); app.nodes = []; await gate.resume()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertTrue(app.nodeMetricsHistory.samples.isEmpty)
    }

    func testEnvironmentFailureDoesNotCreateQualityHistory() async {
        let app = make(direct: Direct { .init(url: $0, latencyMs: nil, failure: .syntheticAddress) })
        app.nodes[0].lastLatencyMs = 50; let date = Date(); app.nodes[0].lastTestedAt = date
        await app.measureAllNodes()
        XCTAssertEqual(app.nodes[0].lastLatencyMs, 50)
        XCTAssertEqual(app.nodes[0].lastTestedAt, date)
        XCTAssertTrue(app.nodeMetricsHistory.samples.isEmpty)
    }
}
