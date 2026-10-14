import XCTest
import QingzhouCore
@testable import QingzhouApp

@MainActor
final class ProxyBandwidthAttributionTests: XCTestCase {
    private func setup() -> (AppState, Node, AppliedTunnelConfiguration, Date) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = AppState(persistence: Persistence(directory: directory))
        state.settings.iCloudSyncEnabled = false; state.isVPNRunning = true
        let node = Node(name: "N", protocolType: .trojan, host: "n.example", port: 443, password: "pw")
        state.nodes = [node]
        let applied = AppliedTunnelConfiguration(node: node, mode: .global, blockQUIC: true)
        let start = Date()
        state.syncAppliedConfiguration(session: .init(startedAt: start, autoStopSeconds: 0, appliedConfiguration: applied), status: .connected)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (state, node, applied, start)
    }
    private func feed(_ state: AppState, id: UUID?, start: Date, proxyBps: Int64) {
        for second in stride(from: 0, through: 122, by: 2) {
            let at = start.addingTimeInterval(Double(second))
            state.ingestXrayOutboundStats(.init(outbounds: ["proxy": .init(downlinkBytes: Int64(second) * proxyBps),
                "direct": .init(downlinkBytes: Int64(second) * 90_000_000)], sampledAt: at, configurationID: id), now: at)
        }
    }
    func testDirectOnlyDownloadDoesNotRaiseNodeScore() {
        let (state, node, applied, start) = setup()
        feed(state, id: applied.id, start: start, proxyBps: 0)
        XCTAssertNil(state.recentBandwidth(for: node, now: start.addingTimeInterval(122)))
    }
    func testLegacyAndPreviousConfigurationCountersCannotCreditCurrentNode() {
        let (state, node, _, start) = setup()
        feed(state, id: nil, start: start, proxyBps: 8_000_000)
        feed(state, id: UUID(), start: start, proxyBps: 8_000_000)
        XCTAssertNil(state.recentBandwidth(for: node, now: start.addingTimeInterval(122)))
    }
    func testEditingSameUUIDCannotCreditNewConnectionWithOldCounters() {
        let (state, _, applied, start) = setup()
        state.nodes[0].password = "changed"
        feed(state, id: applied.id, start: start, proxyBps: 8_000_000)
        XCTAssertNil(state.recentBandwidth(for: state.nodes[0], now: start.addingTimeInterval(122)))
    }
    func testSparseCounterReadsDoNotInferSustainedActivityDuringAppSuspension() {
        let (state, node, applied, start) = setup()
        for minute in 0...3 {
            let at = start.addingTimeInterval(Double(minute * 60))
            state.ingestXrayOutboundStats(.init(outbounds: ["proxy": .init(downlinkBytes: Int64(minute) * 90_000_000)],
                sampledAt: at, configurationID: applied.id), now: at)
        }
        XCTAssertNil(state.recentBandwidth(for: node, now: start.addingTimeInterval(180)))
    }
}
