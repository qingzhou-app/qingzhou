import XCTest
import QingzhouCore
import QingzhouRules
import QingzhouLogging
@testable import QingzhouApp

@MainActor
final class AppStateTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vpn-state-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    private func makeState() -> AppState {
        AppState(
            logger: Logger(capacity: 100, minimumLevel: .debug),
            persistence: Persistence(directory: tmpDir)
        )
    }

    func testAddNodePersistsAndDedupes() throws {
        let state = makeState()
        try state.addNode(fromURL: "trojan://pw@a.com:443#first")
        try state.addNode(fromURL: "trojan://pw@a.com:443#second")  // 同身份指纹
        XCTAssertEqual(state.nodes.count, 1)
        XCTAssertEqual(state.nodes.first?.name, "second")

        // 异步 persist 需要等磁盘落盘完成才能从同目录 reload
        state.persistence.waitForPendingWritesForTesting()

        // 新 state 从同目录加载，应该还在
        let reloaded = makeState()
        XCTAssertEqual(reloaded.nodes.count, 1)
        XCTAssertEqual(reloaded.nodes.first?.name, "second")
    }

    func testAddNodesBatchSeparatesGoodAndBad() {
        let state = makeState()
        let result = state.addNodes(fromText: """
        trojan://pw@a.com:443#A
        not a url
        hy2://pw@b.com:443#B
        """)
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(state.nodes.count, 2)
    }

    func testToggleExclusionClearsCurrentIfExcluded() throws {
        let state = makeState()
        try state.addNode(fromURL: "trojan://pw@a.com:443#X")
        let node = state.nodes[0]
        state.select(node)
        XCTAssertEqual(state.currentNodeId, node.id)

        state.toggleExclusion(node)
        XCTAssertTrue(state.nodes[0].isExcluded)
        XCTAssertNil(state.currentNodeId, "排除当前节点后应当清空 currentNodeId")
    }

    func testSetProxyModeChangesDedupesAndPersists() {
        let state = makeState()
        XCTAssertEqual(state.settings.proxyMode, .rule, "默认应为规则模式")

        state.setProxyMode(.global)
        XCTAssertEqual(state.settings.proxyMode, .global)

        // 相同值是 no-op（不重复持久化 / 不重启），且不崩
        state.setProxyMode(.global)
        XCTAssertEqual(state.settings.proxyMode, .global)

        state.persistence.waitForPendingWritesForTesting()
        let reloaded = makeState()
        XCTAssertEqual(reloaded.settings.proxyMode, .global, "模式切换必须持久化")
    }

    func testMergeClearsSelectionWhenSelectedNodeVanishes() {
        let state = makeState()
        let subId = UUID()
        let a = Node(name: "A", protocolType: .trojan, host: "a.com", port: 443,
                     password: "pw", subscriptionId: subId)
        let b = Node(name: "B", protocolType: .trojan, host: "b.com", port: 443,
                     password: "pw", subscriptionId: subId)
        state.merge(newNodes: [a, b], fromSubscription: subId)
        state.select(state.nodes.first { $0.name == "A" }!)
        XCTAssertNotNil(state.currentNodeId)

        // 刷新后上游把 A 删了，只剩 B
        state.merge(newNodes: [b], fromSubscription: subId)
        XCTAssertEqual(state.nodes.count, 1)
        XCTAssertNil(state.currentNodeId, "选中的 A 被订阅刷掉后，currentNodeId 必须清空而不是悬空")
    }

    func testMergePreservesSelectionWhenSelectedNodeSurvives() {
        let state = makeState()
        let subId = UUID()
        let a = Node(name: "A", protocolType: .trojan, host: "a.com", port: 443,
                     password: "pw", subscriptionId: subId)
        state.merge(newNodes: [a], fromSubscription: subId)
        state.select(state.nodes[0])
        let selected = state.currentNodeId

        // 刷新，A 仍在（同身份指纹）+ 新增 C
        let c = Node(name: "C", protocolType: .trojan, host: "c.com", port: 443,
                     password: "pw", subscriptionId: subId)
        state.merge(newNodes: [a, c], fromSubscription: subId)
        XCTAssertEqual(state.nodes.count, 2)
        XCTAssertEqual(state.currentNodeId, selected, "A 还在就不该动选择")
    }

    func testRemoveSubscriptionAlsoRemovesItsNodes() async {
        let state = makeState()
        let sub = Subscription(name: "sub1", url: URL(string: "https://x/sub")!)
        state.subscriptions = [sub]
        state.nodes = [
            Node(name: "from-sub", protocolType: .trojan, host: "h", port: 1, password: "p", subscriptionId: sub.id),
            Node(name: "manual", protocolType: .trojan, host: "h2", port: 2, password: "p")
        ]
        state.removeSubscription(sub)
        XCTAssertEqual(state.nodes.count, 1)
        XCTAssertEqual(state.nodes.first?.name, "manual")
    }

    func testSettingsBindingPersistsAndAppliesLogLevel() {
        let state = makeState()
        let binding = state.setting(\.logLevel)
        binding.wrappedValue = "WARN"
        XCTAssertEqual(state.settings.logLevel, "WARN")

        state.persistence.waitForPendingWritesForTesting()
        let reloaded = makeState()
        XCTAssertEqual(reloaded.settings.logLevel, "WARN")

        // logger 级别也应该被同步：DEBUG 应被过滤掉，WARN 应保留
        reloaded.logger.clear()
        reloaded.logger.debug("hidden")
        reloaded.logger.warn("shown")
        let entries = reloaded.logger.snapshot()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].message, "shown")
    }

    func testCurrentRuleEngineCustomFirst() {
        let state = makeState()
        let rule = Rule(type: .domainSuffix, value: "example.com", target: .reject)
        state.addCustomRule(rule)
        state.remoteRules = [
            Rule(type: .domainSuffix, value: "example.com", target: .proxy),
            Rule(type: .final, value: "", target: .proxy)
        ]
        let engine = state.currentRuleEngine()
        let result = engine.match(MatchContext(host: "example.com"))
        XCTAssertEqual(result.target, .reject, "自定义规则应优先")
    }

    func testCurrentRuleEngineFinalFallbackFromRemote() {
        let state = makeState()
        state.remoteRules = [Rule(type: .final, value: "", target: .proxy)]
        let result = state.currentRuleEngine().match(MatchContext(host: "anything.example"))
        XCTAssertEqual(result.target, .proxy)
    }

    // MARK: - 域名每日历史（持久化）

    private func historyConn(_ host: String, route: String = "PROXY") -> Connection {
        Connection(targetHost: host, sourceAddress: "127.0.0.1:1",
                   targetAddress: "\(host):443", type: .https, route: route, matchedRule: "")
    }

    func testRecordDomainHistoryAggregatesAndPersistsAcrossRestart() {
        let state = makeState()
        state.domainHistorySaveInterval = 0   // 关掉 10s 落盘节流，测试确定性
        XCTAssertTrue(state.domainHistory.isEmpty)
        state.recordDomainHistory([historyConn("www.google.com"), historyConn("mail.google.com")])
        state.recordDomainHistory([historyConn("www.google.com")])   // 第二批增量

        let digests = state.domainHistory.digests()
        XCTAssertEqual(digests.count, 1)
        XCTAssertEqual(digests[0].domains.first?.domain, "google.com")
        XCTAssertEqual(digests[0].domains.first?.connectionCount, 3)

        // 落盘是异步 + 节流（首批立即写）——等写完后从同目录重建，历史应还在
        state.persistence.waitForPendingWritesForTesting()
        let reloaded = makeState()
        XCTAssertEqual(reloaded.domainHistory.digests().first?.domains.first?.connectionCount, 3,
                       "重启后每日历史应从磁盘恢复（此前重启即清零）")
    }

    func testDomainHistoryStaysOutOfSnapshot() throws {
        let state = makeState()
        state.recordDomainHistory([historyConn("secret-site.com")])
        state.persist()
        state.persistence.waitForPendingWritesForTesting()

        // 敏感访问历史绝不进 Snapshot（CloudVault 只镜像 Snapshot）——state.json 里不该出现域名
        let stateJSON = try String(contentsOf: tmpDir.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertFalse(stateJSON.contains("secret-site.com"))
        // 而独立的 domain-history.json 里应该有
        let historyJSON = try String(contentsOf: tmpDir.appendingPathComponent("domain-history.json"), encoding: .utf8)
        XCTAssertTrue(historyJSON.contains("secret-site.com"))
    }

    // MARK: - 地区排除 / 优先

    private func makeMeasuredNodes() -> [Node] {
        [
            Node(name: "香港-HK-1", protocolType: .trojan, host: "hk.com", port: 443, lastLatencyMs: 20),
            Node(name: "日本-JP-1", protocolType: .trojan, host: "jp.com", port: 443, lastLatencyMs: 80),
            Node(name: "美国-US-1", protocolType: .trojan, host: "us.com", port: 443, lastLatencyMs: 150),
        ]
    }

    func testPickBestSkipsExcludedRegion() {
        let state = makeState()
        state.nodes = makeMeasuredNodes()
        // 排除香港（最快的）→ 应选次快的日本
        state.settings.excludedRegions = ["香港"]
        let best = state.pickBestRespectingRegions(from: state.nodes)
        XCTAssertEqual(best?.region, "日本")
    }

    func testPreferredRegionWinsEvenIfSlower() {
        let state = makeState()
        state.nodes = makeMeasuredNodes()
        // 优先美国（最慢的）→ 仍应选美国
        state.settings.preferredRegion = "美国"
        let best = state.pickBestRespectingRegions(from: state.nodes)
        XCTAssertEqual(best?.region, "美国")
    }

    func testPreferredRegionFallsBackWhenEmpty() {
        let state = makeState()
        state.nodes = makeMeasuredNodes()
        // 优先一个没有节点的地区 → 回退全局最快（香港）
        state.settings.preferredRegion = "德国"
        let best = state.pickBestRespectingRegions(from: state.nodes)
        XCTAssertEqual(best?.region, "香港")
    }

    func testRegionCounts() {
        let state = makeState()
        state.nodes = makeMeasuredNodes() + [
            Node(name: "香港-HK-2", protocolType: .trojan, host: "hk2.com", port: 443)
        ]
        let counts = Dictionary(uniqueKeysWithValues: state.regionCounts.map { ($0.region, $0.count) })
        XCTAssertEqual(counts["香港"], 2)
        XCTAssertEqual(counts["日本"], 1)
    }

    func testToggleRegionExclusionClearsCurrentInThatRegion() {
        let state = makeState()
        state.nodes = makeMeasuredNodes()
        let hk = state.nodes.first { $0.region == "香港" }!
        state.select(hk)
        XCTAssertEqual(state.currentNodeId, hk.id)
        state.toggleRegionExclusion("香港")
        XCTAssertTrue(state.settings.excludedRegions.contains("香港"))
        XCTAssertNil(state.currentNodeId, "排除当前节点所在地区后应清空当前选择")
    }

    func testSchedulersStartAndCancelCleanly() async {
        let state = makeState()
        state.startSchedulers()
        // 等一小会让各调度 loop 至少跑一次
        try? await Task.sleep(for: .seconds(0.05))
        state.stopSchedulers()
        // 不 crash 即可；任务取消是 happy path
    }

    // MARK: - 隧道热切换的开关显示

    func testSwitchingTunnelDefaultsFalse() {
        let state = makeState()
        XCTAssertFalse(state.isSwitchingTunnel)
    }

    func testVPNToggleShowsOffWhileSwitching() {
        let state = makeState()
        state.isVPNRunning = true
        XCTAssertTrue(state.vpnRunningBinding.wrappedValue)

        // 热切换窗口内：开关显示"关"（真实隧道确实断着）
        state.isSwitchingTunnel = true
        XCTAssertFalse(state.vpnRunningBinding.wrappedValue)

        // 切换结束：滑回"开"
        state.isSwitchingTunnel = false
        XCTAssertTrue(state.vpnRunningBinding.wrappedValue)
    }

    func testVPNToggleStaysOffWhenNotRunningRegardlessOfSwitching() {
        let state = makeState()
        state.isVPNRunning = false
        state.isSwitchingTunnel = true
        XCTAssertFalse(state.vpnRunningBinding.wrappedValue)
    }

    // MARK: - 连接老化 / 隧道停止关闭

    func testMarkAllConnectionsClosedClosesActiveOnes() {
        let state = makeState()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        state.connectionTracker.ingest(
            Connection(targetHost: "a.com", sourceAddress: "10.0.0.2:1111",
                       targetAddress: "a.com:443", type: .https, route: "PROXY", matchedRule: ""),
            at: t0
        )
        state.connectionTracker.ingest(
            Connection(targetHost: "b.com", sourceAddress: "10.0.0.2:2222",
                       targetAddress: "b.com:443", type: .https, route: "DIRECT", matchedRule: ""),
            at: t0 + 1
        )
        XCTAssertTrue(state.connections.allSatisfy(\.isActive))

        state.markAllConnectionsClosed(at: t0 + 30)

        XCTAssertEqual(state.connections.count, 2)
        XCTAssertTrue(state.connections.allSatisfy { !$0.isActive })
        XCTAssertTrue(state.connections.allSatisfy { $0.closedAt == t0 + 30 })
    }
}
