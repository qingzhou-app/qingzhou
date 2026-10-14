import XCTest
import NetworkExtension
import Observation
import QingzhouCore
@testable import QingzhouApp

@MainActor
final class AppliedTunnelStateTests: XCTestCase {
    private func makeState() -> AppState {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("applied-tunnel-\(UUID().uuidString)")
        let state = AppState(persistence: Persistence(directory: directory))
        state.settings.iCloudSyncEnabled = false
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return state
    }

    func testUnconfirmedTrafficDoesNotCreditSelectedNode() {
        let state = makeState()
        let selected = Node(name: "selected", protocolType: .trojan, host: "example.com", port: 443, password: "pw")
        state.nodes = [selected]
        state.currentNodeId = selected.id
        state.isVPNRunning = true
        state.ingestTrafficStats(TrafficStats(downloadSpeedBps: 500_000))
        XCTAssertNil(state.nodes[0].observedPeakDownBps,
                     "启动请求和界面选择不证明这个节点实际承载了流量")
        state.persistence.waitForPendingWritesForTesting()
    }

    func testConfirmedTrafficCreditsRunningNodeDespiteDifferentSelection() {
        let state = makeState()
        let running = Node(name: "running", protocolType: .trojan, host: "a.example", port: 443, password: "pw")
        let selected = Node(name: "selected", protocolType: .trojan, host: "b.example", port: 443, password: "pw")
        state.nodes = [running, selected]
        state.currentNodeId = selected.id
        state.isVPNRunning = true
        let applied = AppliedTunnelConfiguration(node: running, mode: .global, blockQUIC: true)
        state.syncAppliedConfiguration(session: TunnelSessionInfo(
            startedAt: Date(), autoStopSeconds: 0, appliedConfiguration: applied), status: .connected)
        let start = Date()
        for second in stride(from: 0, through: 122, by: 2) {
            let at = start.addingTimeInterval(Double(second))
            state.ingestXrayOutboundStats(.init(outbounds: ["proxy": .init(downlinkBytes: Int64(second) * 500_000)],
                sampledAt: at, configurationID: applied.id), now: at)
        }
        XCTAssertEqual(state.currentNodeId, selected.id)
        XCTAssertEqual(state.runningNode?.id, running.id)
        XCTAssertEqual(state.nodes[0].observedPeakDownBps, 500_000)
        XCTAssertNil(state.nodes[1].observedPeakDownBps)
        state.persistence.waitForPendingWritesForTesting()
    }

    func testTUNTrafficAloneCannotProveProxyBandwidth() {
        let state = makeState()
        let node = Node(name: "running", protocolType: .trojan, host: "a.example", port: 443, password: "pw")
        state.nodes = [node]; state.isVPNRunning = true
        let applied = AppliedTunnelConfiguration(node: node, mode: .global, blockQUIC: true)
        let start = Date()
        state.syncAppliedConfiguration(session: .init(startedAt: start, autoStopSeconds: 0, appliedConfiguration: applied), status: .connected)
        for minute in 0..<3 {
            let at = start.addingTimeInterval(Double(minute * 60))
            state.ingestTrafficStats(.init(downloadSpeedBps: 90_000_000, sampledAt: at, configurationID: applied.id))
        }
        XCTAssertNil(state.recentBandwidth(for: node, now: start.addingTimeInterval(120)), "Global mode still has direct LAN traffic")
    }

    func testOnlyProxyCountersCreditBandwidthInBothModesAndIdleWindowExpires() {
        let state = makeState()
        let node = Node(name: "running", protocolType: .trojan, host: "a.example", port: 443, password: "pw")
        state.nodes = [node]; state.isVPNRunning = true
        let start = Date()
        for mode: ProxyMode in [.rule, .global] {
            let applied = AppliedTunnelConfiguration(node: node, mode: mode, blockQUIC: true)
            state.syncAppliedConfiguration(session: TunnelSessionInfo(
                startedAt: start, autoStopSeconds: 0, appliedConfiguration: applied), status: .connected)
            for second in stride(from: 0, through: 122, by: 2) {
                let at = start.addingTimeInterval(Double(second))
                state.ingestXrayOutboundStats(.init(outbounds: ["proxy": .init(downlinkBytes: Int64(second) * 2_000_000),
                    "direct": .init(downlinkBytes: Int64(second) * 90_000_000)], sampledAt: at, configurationID: applied.id), now: at)
            }
            XCTAssertEqual(state.recentBandwidth(for: node, now: start.addingTimeInterval(122)), 2_000_000)
        }
        XCTAssertNil(state.recentBandwidth(for: node, now: start.addingTimeInterval(32 * 60)))
        state.measurementNetworkDidChange(at: start.addingTimeInterval(123))
        XCTAssertNil(state.recentBandwidth(for: node, now: start.addingTimeInterval(124)))
    }

    func testEditingRunningNodeDoesNotCreditDifferentConnectionWithSameID() {
        let state = makeState()
        var running = Node(name: "running", protocolType: .trojan, host: "a.example", port: 443, password: "pw")
        let applied = AppliedTunnelConfiguration(node: running, mode: .global, blockQUIC: true)
        running.parameters["sni"] = "different.example"
        state.nodes = [running]; state.currentNodeId = running.id; state.isVPNRunning = true
        state.syncAppliedConfiguration(session: TunnelSessionInfo(
            startedAt: Date(), autoStopSeconds: 0, appliedConfiguration: applied), status: .connected)
        state.ingestTrafficStats(TrafficStats(downloadSpeedBps: 500_000, configurationID: applied.id))
        XCTAssertNil(state.runningNode)
        XCTAssertNil(state.nodes[0].observedPeakDownBps)
    }

    func testPreviousConfigurationSampleDoesNotCreditNewActivation() {
        let state = makeState()
        let node = Node(name: "running", protocolType: .trojan, host: "a.example", port: 443, password: "pw")
        state.nodes = [node]; state.currentNodeId = node.id; state.isVPNRunning = true
        let previous = AppliedTunnelConfiguration(node: node, mode: .global, blockQUIC: true)
        let current = AppliedTunnelConfiguration(node: node, mode: .global, blockQUIC: true)
        state.syncAppliedConfiguration(session: TunnelSessionInfo(
            startedAt: Date(), autoStopSeconds: 0, appliedConfiguration: current), status: .connected)
        state.ingestTrafficStats(TrafficStats(downloadSpeedBps: 500_000, configurationID: previous.id))
        XCTAssertNil(state.nodes[0].observedPeakDownBps)
    }

    func testStoppedOrDisconnectedSessionCannotReportAppliedConfiguration() {
        let state = makeState()
        let node = Node(name: "running", protocolType: .trojan, host: "a.example", port: 443, password: "pw")
        let applied = AppliedTunnelConfiguration(node: node, mode: .global, blockQUIC: true)
        var session = TunnelSessionInfo(startedAt: Date(), autoStopSeconds: 0, appliedConfiguration: applied)
        state.syncAppliedConfiguration(session: session, status: .connected)
        XCTAssertEqual(state.appliedTunnelConfiguration?.nodeID, node.id)
        state.syncAppliedConfiguration(session: session, status: .disconnected)
        XCTAssertNil(state.appliedTunnelConfiguration)
        session.stoppedAt = Date()
        state.syncAppliedConfiguration(session: session, status: .connected)
        XCTAssertNil(state.appliedTunnelConfiguration)
    }

    func testOldSessionAfterSuccessfulSwitchAcknowledgementIsUnknown() {
        let state = makeState()
        let node = Node(name: "A", protocolType: .trojan, host: "a.example", port: 443, password: "pw")
        let old = AppliedTunnelConfiguration(node: node, mode: .global, blockQUIC: true)
        let new = AppliedTunnelConfiguration(node: node, mode: .global, blockQUIC: true)
        state.recordAppliedAcknowledgement(new.id)
        state.syncAppliedConfiguration(session: TunnelSessionInfo(
            startedAt: Date(), autoStopSeconds: 0, appliedConfiguration: old), status: .connected)
        XCTAssertNil(state.appliedTunnelConfiguration, "旧文件不能冒充成功回执的新版本")
        state.syncAppliedConfiguration(session: TunnelSessionInfo(
            startedAt: Date(), autoStopSeconds: 0, appliedConfiguration: new), status: .connected)
        XCTAssertEqual(state.appliedTunnelConfiguration?.id, new.id)
    }

    func testQUICStatusUsesAppliedNodeAndRequiresAppliedRouting() {
        let state = makeState()
        let running = Node(name: "A", protocolType: .hysteria2, host: "a.example", port: 443, password: "pw")
        let selected = Node(name: "B", protocolType: .trojan, host: "b.example", port: 443, password: "pw")
        state.nodes = [running, selected]; state.currentNodeId = selected.id; state.isVPNRunning = true
        state.syncAppliedConfiguration(session: TunnelSessionInfo(startedAt: Date(), autoStopSeconds: 0,
            appliedConfiguration: AppliedTunnelConfiguration(node: running, mode: .global, blockQUIC: false)), status: .connected)
        XCTAssertEqual(state.quicRuntimeStatus, .autoProbing)
        state.quicKnownBrokenNodes.insert(running.identityFingerprint)
        XCTAssertNil(state.quicRuntimeStatus, "判坏缓存不是实际routing已经阻断的确认")
    }

    func testHeartbeatContradictionPreventsReadoptingOldSessionAfterAppRestart() {
        let state = makeState()
        let node = Node(name: "A", protocolType: .trojan, host: "a.example", port: 443, password: "pw")
        let old = AppliedTunnelConfiguration(node: node, mode: .global, blockQUIC: true)
        let session = TunnelSessionInfo(startedAt: Date(), autoStopSeconds: 0, appliedConfiguration: old)
        state.isVPNRunning = true
        state.syncAppliedConfiguration(session: session, status: .connected)
        XCTAssertNotNil(state.appliedTunnelConfiguration)
        state.ingestTrafficStats(TrafficStats(configurationID: UUID()))
        XCTAssertNil(state.appliedTunnelConfiguration)
        state.syncAppliedConfiguration(session: session, status: .connected)
        XCTAssertNil(state.appliedTunnelConfiguration, "同一旧会话不能在下一轮重新采认")
    }

    func testAppliedConfigurationStillNotifiesViewsAfterCoordinatorExtraction() {
        let state = makeState()
        let node = Node(name: "A", protocolType: .trojan, host: "a.example", port: 443, password: "pw")
        let applied = AppliedTunnelConfiguration(node: node, mode: .global, blockQUIC: true)
        let confirmed = XCTestExpectation(description: "view observes confirmed configuration")
        withObservationTracking {
            _ = state.appliedTunnelConfiguration
        } onChange: {
            confirmed.fulfill()
        }
        state.syncAppliedConfiguration(session: TunnelSessionInfo(startedAt: Date(), autoStopSeconds: 0,
            appliedConfiguration: applied), status: .connected)
        XCTAssertEqual(XCTWaiter.wait(for: [confirmed], timeout: 0.1), .completed)

        let contradicted = XCTestExpectation(description: "view observes unknown configuration")
        withObservationTracking {
            _ = state.appliedTunnelConfiguration
        } onChange: {
            contradicted.fulfill()
        }
        state.ingestTrafficStats(TrafficStats(configurationID: UUID()))
        XCTAssertNil(state.appliedTunnelConfiguration)
        XCTAssertEqual(XCTWaiter.wait(for: [contradicted], timeout: 0.1), .completed)
    }
}
