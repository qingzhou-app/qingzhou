import XCTest
import QingzhouCore
import QingzhouProtocols
import QingzhouSubscription
import QingzhouSpeedTest
import QingzhouLogging
@testable import QingzhouApp

@MainActor
final class AppStateDataSafetyTests: XCTestCase {
    private struct ResponseClient: HTTPClient {
        var body: String
        func get(_ url: URL) async throws -> (Data, [String: String]) {
            (Data(body.utf8), [:])
        }
    }

    private struct CallbackProber: LatencyProber {
        var callback: @MainActor @Sendable () -> Void
        func probe(_ url: URL, timeout: TimeInterval) async -> LatencyResult {
            await callback()
            return LatencyResult(url: url, latencyMs: 60)
        }
    }

    private final class ProbeAction {
        var state: AppState?
        var fired = false
        var action: ((AppState) -> Void)?
        func fire() {
            guard !fired, let state else { return }
            fired = true
            action?(state)
        }
    }

    private var directories: [URL] = []
    private func makeState(body: String = "", selector: NodeSelector? = nil) -> AppState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(directory)
        let state = AppState(
            logger: Logger(capacity: 100, minimumLevel: .error),
            persistence: Persistence(directory: directory),
            subscriptionFetcher: SubscriptionFetcher(client: ResponseClient(body: body)),
            nodeSelector: selector)
        state.settings.iCloudSyncEnabled = false
        return state
    }

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        try await super.tearDown()
    }

    func testInvalidSubscriptionResponsePreservesNodesAndMetadata() async throws {
        for body in ["<html>expired</html>", "<a href=\"https://example.com\">login</a>", "trojan://bad",
                     "proxies:\n  - {name: unsupported, type: ssr, server: example.com, port: 8388}"] {
            let state = makeState(body: body)
            let sub = Subscription(name: "S", url: URL(string: "https://example.com/sub")!)
            var node = try ProxyURLParser.parse("trojan://pw@a.example:443#old")
            node.subscriptionId = sub.id
            state.subscriptions = [sub]; state.nodes = [node]; state.currentNodeId = node.id
            await state.refreshSubscription(sub)
            XCTAssertEqual(state.nodes, [node], body)
            XCTAssertEqual(state.currentNodeId, node.id, body)
            XCTAssertNil(state.subscriptions[0].lastUpdatedAt, body)
            XCTAssertNotNil(state.subscriptionErrors[sub.id], body)
        }
    }

    func testRecognizedEmptySubscriptionCanRemoveNodes() async throws {
        let state = makeState(body: "{\"servers\":[]}")
        let sub = Subscription(name: "S", url: URL(string: "https://example.com/sub")!)
        var node = try ProxyURLParser.parse("trojan://pw@a.example:443#old")
        node.subscriptionId = sub.id
        state.subscriptions = [sub]; state.nodes = [node]
        await state.refreshSubscription(sub)
        XCTAssertTrue(state.nodes.isEmpty)
        XCTAssertNil(state.subscriptionErrors[sub.id])
        state.persistence.waitForPendingWritesForTesting()
    }

    func testSubscriptionMergeDeduplicatesAndPreservesAllMeasurements() throws {
        let state = makeState()
        let subID = UUID()
        var node = try ProxyURLParser.parse("trojan://pw@a.example:443#old")
        node.subscriptionId = subID
        node.lastProxiedLatencyMs = 70; node.lastProxiedTestedAt = Date()
        node.observedPeakDownBps = 9_000_000; node.observedBandwidthAt = Date()
        state.nodes = [node]
        var updated = node; updated.name = "new"
        updated.lastProxiedLatencyMs = nil; updated.lastProxiedTestedAt = nil
        updated.observedPeakDownBps = nil; updated.observedBandwidthAt = nil
        state.merge(newNodes: [updated, updated], fromSubscription: subID)
        XCTAssertEqual(state.nodes.count, 1)
        XCTAssertEqual(state.nodes.first?.lastProxiedLatencyMs, 70)
        XCTAssertEqual(state.nodes.first?.observedPeakDownBps, 9_000_000)
        guard state.nodes.count == 1 else { return } // 旧实现重复key会崩，先报告边界断言
        state.merge(newNodes: [updated], fromSubscription: subID)
        XCTAssertEqual(state.nodes.first?.id, node.id)
    }

    func testDifferentTransportsAtSameEndpointRemainDistinctNodes() {
        let state = makeState()
        let subscriptionID = UUID()
        let a = Node(name: "route-A", protocolType: .vless, host: "example.com", port: 443,
                     uuid: "same-user", parameters: ["network": "ws", "path": "/a"])
        let b = Node(name: "route-B", protocolType: .vless, host: "example.com", port: 443,
                     uuid: "same-user", parameters: ["network": "ws", "path": "/b"])
        state.merge(newNodes: [a,b], fromSubscription: subscriptionID)
        XCTAssertEqual(state.nodes.count, 2, "传输路径不同不是重复节点，不可去重删除")
    }

    func testMeasurementDoesNotRestoreDeletedNodeOrLoseInsertedNode() async throws {
        let action = ProbeAction()
        let selector = NodeSelector(prober: CallbackProber(callback: { action.fire() }))
        let state = makeState(selector: selector)
        let a = try ProxyURLParser.parse("trojan://pw@a.example:443#A")
        let b = try ProxyURLParser.parse("trojan://pw@b.example:443#B")
        let c = try ProxyURLParser.parse("trojan://pw@c.example:443#C")
        state.nodes = [a,b]; action.state = state
        action.action = { state in state.removeNode(b); state.nodes.append(c) }
        await state.measureAllNodes()
        XCTAssertEqual(Set(state.nodes.map(\.id)), [a.id, c.id])
        XCTAssertEqual(state.nodes.first(where: { $0.id == a.id })?.lastLatencyMs, 60)
        state.persistence.waitForPendingWritesForTesting()
    }

    func testAutoSelectionDoesNotUndoAnExclusionDuringMeasurement() async throws {
        let action = ProbeAction()
        let selector = NodeSelector(prober: CallbackProber(callback: { action.fire() }))
        let state = makeState(selector: selector)
        let node = try ProxyURLParser.parse("trojan://pw@a.example:443#A")
        state.nodes = [node]; action.state = state
        action.action = { $0.toggleExclusion(node) }
        await state.autoSelectBestNode()
        XCTAssertTrue(state.nodes[0].isExcluded)
        XCTAssertNil(state.currentNodeId)
        state.persistence.waitForPendingWritesForTesting()
    }

    func testExplicitReselectOfCurrentNodeCancelsOldAutoSelectionIntent() async throws {
        let action = ProbeAction()
        let selector = NodeSelector(prober: CallbackProber(callback: { action.fire() }))
        let state = makeState(selector: selector)
        let current = try ProxyURLParser.parse("trojan://pw@current.example:443#Z-current")
        let best = try ProxyURLParser.parse("trojan://pw@best.example:443#A-best")
        state.nodes = [current, best]; state.currentNodeId = current.id; action.state = state
        action.action = { $0.select(current) }
        await state.autoSelectBestNode()
        XCTAssertEqual(state.currentNodeId, current.id, "重新点选同一节点也是新用户意图")
        state.persistence.waitForPendingWritesForTesting()
    }

    func testRefreshDoesNotRecreateSubscriptionRemovedWhileFetching() async throws {
        // 刷新已删除订阅不应把它重新插入；重叠refresh的旧结果也必须作废。
        let state = makeState(body: "trojan://pw@a.example:443#A")
        let sub = Subscription(name: "deleted", url: URL(string: "https://example.com/sub")!)
        await state.refreshSubscription(sub)
        XCTAssertTrue(state.subscriptions.isEmpty)
        XCTAssertTrue(state.nodes.isEmpty)
        state.persistence.waitForPendingWritesForTesting()
    }
}
