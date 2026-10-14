import XCTest
import Observation
import QingzhouCore
import QingzhouSpeedTest
@testable import QingzhouApp

@MainActor
final class NodeSelectionReportTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selection-report-\(UUID())")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }
    private struct Prober: LatencyProber {
        let values: [String: Int]
        func probe(_ url: URL, timeout: TimeInterval) async -> LatencyResult {
            LatencyResult(url: url, latencyMs: values[url.host ?? ""])
        }
    }
    private struct CallbackProber: LatencyProber {
        let callback: @MainActor @Sendable () async -> Void
        func probe(_ url: URL, timeout: TimeInterval) async -> LatencyResult {
            await callback()
            return LatencyResult(url: url, latencyMs: 40)
        }
    }
    private func app(_ values: [String: Int] = [:]) -> AppState {
        let state = AppState(persistence: Persistence(directory: directory), nodeSelector: NodeSelector(prober: Prober(values: values)))
        state.settings.iCloudSyncEnabled = false
        state.settings.autoSelectUsesProxiedLatency = false
        return state
    }
    private func node(_ name: String, host: String) -> Node {
        Node(name: name, protocolType: .trojan, host: host, port: 443, password: "private-password")
    }

    func testReportExplainsCompositeScoreRatherThanLowestLatency() async throws {
        let state = app(["fast.example": 60, "stable.example": 90])
        let fast = node("fast", host: "fast.example"), stable = node("stable", host: "stable.example")
        state.nodes = [fast, stable]
        for i in 0..<10 {
            state.nodeMetricsHistory.recordDirect(fingerprint: fast.identityFingerprint, latencyMs: i % 2 == 0 ? 60 : nil)
            state.nodeMetricsHistory.recordDirect(fingerprint: stable.identityFingerprint, latencyMs: 90)
        }
        await state.autoSelectBestNode()
        let report = try XCTUnwrap(state.lastSelectionReport)
        XCTAssertEqual(report.reason, .highestScore)
        XCTAssertEqual(report.selected?.id, stable.id)
        XCTAssertEqual(report.selected?.directLatencyMs, 90)
        XCTAssertEqual(report.directSucceeded, 2)
        XCTAssertEqual(report.directFailed, 0)
        let total = try XCTUnwrap(report.selected?.score.total)
        XCTAssertEqual(total, state.scoreForAutoSelect(try XCTUnwrap(state.currentNode)).total, accuracy: 0.01)
        state.persistence.waitForPendingWritesForTesting()
    }

    func testAlreadySelectedWinnerGetsExplicitKeepReason() async throws {
        let state = app(["a.example": 50])
        let n = node("A", host: "a.example")
        state.nodes = [n]; state.currentNodeId = n.id
        await state.autoSelectBestNode()
        XCTAssertEqual(state.lastSelectionReport?.reason, .alreadyBest)
        state.persistence.waitForPendingWritesForTesting()
    }

    func testNoCandidateDoesNotDescribeAllNodesAsBroken() async throws {
        let state = app()
        var excluded = node("excluded", host: "excluded.example"); excluded.isExcluded = true
        let udp = Node(name: "UDP", protocolType: .hysteria2, host: "udp.example", port: 443, password: "pw")
        state.nodes = [excluded, udp, node("failed", host: "failed.example")]
        await state.autoSelectBestNode()
        let report = try XCTUnwrap(state.lastSelectionReport)
        XCTAssertEqual(report.reason, .noEligibleMeasurement)
        XCTAssertEqual(report.excludedCount, 1)
        XCTAssertEqual(report.directFailed, 1)
        XCTAssertEqual(report.directSucceeded, 0)
        XCTAssertEqual(report.unmeasuredUDPCount, 1, "未执行TCP探针的UDP节点不能计为测试失败")
        XCTAssertNil(report.selected)
        state.persistence.waitForPendingWritesForTesting()
    }

    func testPreferredRegionDecisionRecordsUsedPolicy() async throws {
        let state = app(["hk.example": 120, "jp.example": 40])
        let hk = node("香港 A", host: "hk.example"), jp = node("日本 A", host: "jp.example")
        state.nodes = [hk, jp]; state.settings.preferredRegion = hk.region
        await state.autoSelectBestNode()
        let report = try XCTUnwrap(state.lastSelectionReport)
        XCTAssertEqual(report.selected?.id, hk.id)
        XCTAssertEqual(report.preferredRegion, hk.region)
        XCTAssertTrue(report.usedPreferredRegion)
        state.persistence.waitForPendingWritesForTesting()
    }

    func testPreferredRegionFallbackIsVisible() async throws {
        let state = app(["jp.example": 40])
        let hk = node("香港 A", host: "hk.example"), jp = node("日本 A", host: "jp.example")
        state.nodes = [hk, jp]; state.settings.preferredRegion = hk.region
        await state.autoSelectBestNode()
        XCTAssertEqual(state.lastSelectionReport?.selected?.id, jp.id)
        XCTAssertEqual(state.lastSelectionReport?.usedPreferredRegion, false)
        state.persistence.waitForPendingWritesForTesting()
    }

    func testProxyRefinementSkippedOfflineIsRecorded() async throws {
        let state = app(["a.example": 40])
        state.nodes = [node("A", host: "a.example")]
        state.settings.autoSelectUsesProxiedLatency = true
        await state.autoSelectBestNode()
        XCTAssertEqual(state.lastSelectionReport?.proxy.state, .vpnUnavailable)
        XCTAssertEqual(state.lastSelectionReport?.proxy.attempted, 0)
        state.persistence.waitForPendingWritesForTesting()
    }

    func testScheduledHoldExplainsMargin() async throws {
        let state = app(["a.example": 90, "b.example": 100])
        let a = node("A", host: "a.example"), b = node("B", host: "b.example")
        state.nodes = [a, b]; state.currentNodeId = b.id; state.isVPNRunning = true
        await state.autoSelectBestNode(origin: .scheduled)
        XCTAssertEqual(state.currentNodeId, b.id)
        XCTAssertEqual(state.lastSelectionReport?.reason, .insufficientLead)
        XCTAssertEqual(state.lastSelectionReport?.challenger?.id, a.id)
        XCTAssertEqual(state.lastSelectionReport?.selected?.id, b.id)
        state.persistence.waitForPendingWritesForTesting()
    }

    func testScheduledHoldReportsActualWinningRound() async throws {
        let state = app(["a.example": 60, "b.example": 300])
        let a = node("A", host: "a.example"), b = node("B", host: "b.example")
        state.nodes = [a, b]; state.currentNodeId = b.id; state.isVPNRunning = true
        await state.autoSelectBestNode(origin: .scheduled)
        XCTAssertEqual(state.lastSelectionReport?.reason, .confirmingLead(completed: 1, required: 2))
        state.persistence.waitForPendingWritesForTesting()
    }

    func testReportIsFrozenObservableAndNotPersisted() async throws {
        let state = app(["a.example": 40])
        state.nodes = [node("A", host: "a.example")]
        let changed = expectation(description: "selection report notifies view")
        withObservationTracking { _ = state.lastSelectionReport } onChange: { changed.fulfill() }
        await state.autoSelectBestNode()
        await fulfillment(of: [changed], timeout: 1)
        let report = try XCTUnwrap(state.lastSelectionReport)
        state.nodes[0].name = "edited"; state.nodes[0].lastLatencyMs = 900
        state.settings.scoringProfile = .saver
        XCTAssertEqual(report.selected?.name, "A")
        XCTAssertEqual(report.selected?.directLatencyMs, 40)
        XCTAssertEqual(report.profile, .balanced)
        state.persistence.waitForPendingWritesForTesting()
        XCTAssertNil(app().lastSelectionReport, "重新加载后不拿旧报告冒充当前网络的解释")
    }

    func testProxyFailuresRecordAttemptsAndUnverifiedDirectFallback() async throws {
        let state = app(["a.example": 40, "b.example": 80])
        let a = node("A", host: "a.example"), b = node("B", host: "b.example")
        state.nodes = [a, b]; state.currentNodeId = a.id
        state.settings.autoSelectUsesProxiedLatency = true
        state.isVPNRunning = true // 未加载manager：pingNode明确失败，不访问真实网络/扩展。
        await state.autoSelectBestNode()
        let report = try XCTUnwrap(state.lastSelectionReport)
        XCTAssertEqual(report.proxy.attempted, 2)
        XCTAssertEqual(report.proxy.failed, 2)
        XCTAssertEqual(report.proxy.succeeded, 0)
        XCTAssertTrue(report.proxy.fellBackToDirect)
        XCTAssertEqual(report.reason, .alreadyBest)
        state.persistence.waitForPendingWritesForTesting()
    }

    func testFailedRefinementKeepsOriginalRankingScoreInsteadOfRecomputingIt() async throws {
        let state = app(["a.example": 100, "b.example": 30])
        var a = node("A", host: "a.example"), b = node("B", host: "b.example")
        a.lastLatencyMs = 100; a.lastProxiedLatencyMs = 50; a.lastProxiedTestedAt = Date()
        b.lastLatencyMs = 30; b.lastProxiedLatencyMs = 500; b.lastProxiedTestedAt = Date()
        state.nodes = [a, b]; state.currentNodeId = a.id; state.isVPNRunning = true
        state.settings.autoSelectUsesProxiedLatency = true
        let originalScore = state.scoreForAutoSelect(a).total
        await state.autoSelectBestNode()
        let report = try XCTUnwrap(state.lastSelectionReport)
        XCTAssertEqual(report.selected?.id, a.id)
        XCTAssertEqual(try XCTUnwrap(report.selected?.score.total), originalScore, accuracy: 0.01,
            "代理失败后保留初选，不得把重算的低分伪装成实际排名依据")
        state.persistence.waitForPendingWritesForTesting()
    }

    func testRegionExplanationUsesThePolicyThatBuiltThePool() async throws {
        let state = app(["hk.example": 100, "jp.example": 40])
        let hk = node("香港 A", host: "hk.example"), jp = node("日本 A", host: "jp.example")
        state.nodes = [hk, jp]; state.currentNodeId = hk.id; state.isVPNRunning = true
        state.settings.preferredRegion = hk.region; state.settings.autoSelectUsesProxiedLatency = true
        withObservationTracking { _ = state.proxiedMeasuringNodeIds } onChange: {
            MainActor.assumeIsolated { state.settings.preferredRegion = jp.region }
        }
        await state.autoSelectBestNode()
        XCTAssertEqual(state.settings.preferredRegion, jp.region)
        XCTAssertEqual(state.lastSelectionReport?.preferredRegion, hk.region)
        XCTAssertEqual(state.lastSelectionReport?.usedPreferredRegion, true)
        state.persistence.waitForPendingWritesForTesting()
    }

    func testHoldReportUsesThePreferencesThatActuallyJudgedTheLead() async throws {
        let state = app(["a.example": 90, "b.example": 100])
        let a = node("A", host: "a.example"), b = node("B", host: "b.example")
        state.nodes = [a, b]; state.currentNodeId = b.id; state.isVPNRunning = true
        state.settings.autoSelectUsesProxiedLatency = true
        withObservationTracking { _ = state.proxiedMeasuringNodeIds } onChange: {
            MainActor.assumeIsolated {
                state.settings.scoringProfile = .saver
                state.settings.preferLowerRate = false
            }
        }
        await state.autoSelectBestNode(origin: .scheduled)
        XCTAssertEqual(state.lastSelectionReport?.reason, .insufficientLead)
        XCTAssertEqual(state.lastSelectionReport?.profile, .saver)
        XCTAssertEqual(state.lastSelectionReport?.prefersLowerRate, false)
        XCTAssertEqual(state.lastSelectionReport?.challenger?.score.cost.weight, 0)
        state.persistence.waitForPendingWritesForTesting()
    }

    func testCancelledUDPBootstrapIsNotReportedAsNoCandidate() async throws {
        let state = app()
        state.isVPNRunning = true
        state.nodes = [Node(name: "UDP", protocolType: .hysteria2, host: "udp.example", port: 443, password: "pw")]
        withObservationTracking { _ = state.proxiedMeasuringNodeIds } onChange: {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let task = Task { await state.autoSelectBestNode() }
        await task.value
        XCTAssertEqual(state.lastSelectionReport?.reason, .cancelled)
        state.persistence.waitForPendingWritesForTesting()
    }

    func testStoppedUDPBootstrapKeepsActualAttemptsAndMarksInterruption() async throws {
        let state = app()
        state.isVPNRunning = true
        state.nodes = [Node(name: "UDP", protocolType: .hysteria2, host: "udp.example", port: 443, password: "pw")]
        withObservationTracking { _ = state.proxiedMeasuringNodeIds } onChange: {
            MainActor.assumeIsolated { state.isVPNRunning = false }
        }
        await state.autoSelectBestNode()
        XCTAssertEqual(state.lastSelectionReport?.proxy.attempted, 1)
        XCTAssertEqual(state.lastSelectionReport?.proxy.state, .interrupted)
        state.persistence.waitForPendingWritesForTesting()
    }

    func testFreshUDPMeasurementCanWinWithoutTCPFailureCount() async throws {
        let state = app()
        state.nodes = [Node(name: "UDP", protocolType: .hysteria2, host: "udp.example", port: 443,
            password: "pw", lastProxiedLatencyMs: 40, lastProxiedTestedAt: Date())]
        await state.autoSelectBestNode()
        XCTAssertEqual(state.lastSelectionReport?.selected?.id, state.nodes[0].id)
        XCTAssertEqual(state.lastSelectionReport?.directFailed, 0)
        XCTAssertEqual(state.lastSelectionReport?.unmeasuredUDPCount, 0)
        state.persistence.waitForPendingWritesForTesting()
    }

    func testUserChoiceDuringMeasurementGetsSupersededExplanation() async throws {
        let a = node("A", host: "a.example"), b = node("B", host: "b.example")
        let choice = SelectionChoiceAction()
        let app = AppState(persistence: Persistence(directory: directory),
            nodeSelector: NodeSelector(prober: CallbackProber { choice.choose() }))
        app.settings.iCloudSyncEnabled = false
        app.settings.autoSelectUsesProxiedLatency = false
        app.nodes = [a, b]; app.currentNodeId = a.id
        choice.state = app; choice.id = b.id
        await app.autoSelectBestNode()
        XCTAssertEqual(app.currentNodeId, b.id)
        XCTAssertEqual(app.lastSelectionReport?.reason, .selectionChanged)
        app.persistence.waitForPendingWritesForTesting()
    }

    func testCancelledRoundDoesNotClaimSelectionOrCompletedProbes() async throws {
        let gate = CloudIOGate()
        let state = AppState(persistence: Persistence(directory: directory),
            nodeSelector: NodeSelector(prober: CallbackProber { await gate.suspend() }))
        state.settings.iCloudSyncEnabled = false
        state.nodes = [node("A", host: "a.example")]
        let task = Task { await state.autoSelectBestNode() }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.resume()
        await task.value
        XCTAssertEqual(state.lastSelectionReport?.reason, .cancelled)
        XCTAssertEqual(state.lastSelectionReport?.directSucceeded, 0)
        XCTAssertNil(state.currentNodeId)
    }

    func testBusyRequestCannotCreateFalseCompletedReport() async throws {
        let choice = SelectionChoiceAction()
        let state = AppState(persistence: Persistence(directory: directory),
            nodeSelector: NodeSelector(prober: CallbackProber { await choice.runBusyRequest() }))
        state.settings.iCloudSyncEnabled = false
        state.settings.autoSelectUsesProxiedLatency = false
        state.nodes = [node("A", host: "a.example")]
        choice.state = state
        await state.autoSelectBestNode()
        XCTAssertTrue(choice.busySawNoReport)
        XCTAssertNotNil(state.lastSelectionReport)
        state.persistence.waitForPendingWritesForTesting()
    }

    @MainActor private final class SelectionChoiceAction {
        weak var state: AppState?
        var id: UUID?
        var busySawNoReport = false
        func choose() { state?.currentNodeId = id }
        func runBusyRequest() async {
            await state?.autoSelectBestNode()
            busySawNoReport = state?.lastSelectionReport == nil
        }
    }
}
