import XCTest
import NetworkExtension
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

    // MARK: - 自动择优黏性滞后（VPN 运行中，新最优要显著更好才值得重启隧道）

    func testAutoSwitchWorthRestartHysteresis() {
        // 当前节点本轮测速失败（nil）= 已坏，无条件放行
        XCTAssertTrue(AppState.autoSwitchWorthRestart(currentMs: nil, bestMs: 500))
        // 显著更好（300→100：提升 200 ≥ max(50, 300×0.3=90)）→ 切
        XCTAssertTrue(AppState.autoSwitchWorthRestart(currentMs: 300, bestMs: 100))
        // 小抖动（100→80：提升 20 < 50）→ 不值得为 20ms 断流重启
        XCTAssertFalse(AppState.autoSwitchWorthRestart(currentMs: 100, bestMs: 80))
        // 绝对值够但比例不够（500→400：提升 100 < 500×0.3=150）→ 不切
        XCTAssertFalse(AppState.autoSwitchWorthRestart(currentMs: 500, bestMs: 400))
        // 比例够且绝对值达标（60→5：提升 55 ≥ max(50, 18)）→ 切
        XCTAssertTrue(AppState.autoSwitchWorthRestart(currentMs: 60, bestMs: 5))
        // 边界：提升恰好等于门槛（150→100：提升 50 = max(50, 45)）→ 切
        XCTAssertTrue(AppState.autoSwitchWorthRestart(currentMs: 150, bestMs: 100))
        // 新最优反而更差 / 相同 → 不切
        XCTAssertFalse(AppState.autoSwitchWorthRestart(currentMs: 100, bestMs: 100))
        XCTAssertFalse(AppState.autoSwitchWorthRestart(currentMs: 100, bestMs: 180))
    }

    func testAutoSelectKeepsCurrentNodeOnSmallImprovementWhileVPNRunning() throws {
        let state = makeState()
        try state.addNode(fromURL: "trojan://pw@a.com:443#慢一点的当前节点")
        try state.addNode(fromURL: "trojan://pw@b.com:443#快一点的候选")
        // 手动构造测速结果：当前 100ms、候选 80ms —— 差 20ms，不值得重启
        state.nodes[0].lastLatencyMs = 100
        state.nodes[1].lastLatencyMs = 80
        state.select(state.nodes[0])
        state.isVPNRunning = true

        // 直接检验门槛判定（autoSelectBestNode 会真发 TCP 探测，单测里不跑全流程）：
        // pickBestRespectingRegions 会选 80ms 的候选，但门槛应拦下切换
        let best = state.pickBestRespectingRegions(from: state.nodes)
        XCTAssertEqual(best?.name, "快一点的候选")
        XCTAssertFalse(AppState.autoSwitchWorthRestart(
            currentMs: state.nodes[0].lastLatencyMs, bestMs: best?.lastLatencyMs ?? .max))
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

    func testPrefersLowerRateWhenLatencyClose() {
        let state = makeState()
        // 两个延迟接近（差 20ms < 30ms 带宽）：50ms 的 2x 与 70ms 的 0.5x → 选低倍率的 0.5x
        state.nodes = [
            Node(name: "香港-快-2x", protocolType: .trojan, host: "a.com", port: 443, lastLatencyMs: 50),
            Node(name: "香港-省-0.5x", protocolType: .trojan, host: "b.com", port: 443, lastLatencyMs: 70),
        ]
        let best = state.pickBestRespectingRegions(from: state.nodes)
        XCTAssertEqual(best?.name, "香港-省-0.5x", "延迟接近时应优先低倍率")
    }

    func testLatencyStillWinsWhenGapLarge() {
        let state = makeState()
        // 差距大（150ms > 30ms 带宽）：不算「接近」，低倍率不该逆袭
        state.nodes = [
            Node(name: "香港-快-2x", protocolType: .trojan, host: "a.com", port: 443, lastLatencyMs: 50),
            Node(name: "美国-省-0.5x", protocolType: .trojan, host: "b.com", port: 443, lastLatencyMs: 200),
        ]
        let best = state.pickBestRespectingRegions(from: state.nodes)
        XCTAssertEqual(best?.name, "香港-快-2x", "差距大时仍按延迟选最快")
    }

    func testPreferLowerRateToggleOff() {
        let state = makeState()
        state.settings.preferLowerRate = false
        state.nodes = [
            Node(name: "香港-快-2x", protocolType: .trojan, host: "a.com", port: 443, lastLatencyMs: 50),
            Node(name: "香港-省-0.5x", protocolType: .trojan, host: "b.com", port: 443, lastLatencyMs: 70),
        ]
        let best = state.pickBestRespectingRegions(from: state.nodes)
        XCTAssertEqual(best?.name, "香港-快-2x", "关掉开关退化为纯延迟最低")
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

    // MARK: - 启动采认在跑的隧道（主 App 被杀重开 / 替换安装后开关显示要对）

    func testTunnelActiveStatusMapping() {
        XCTAssertTrue(AppState.isTunnelActive(.connected))
        XCTAssertTrue(AppState.isTunnelActive(.connecting))
        XCTAssertTrue(AppState.isTunnelActive(.reasserting))
        XCTAssertFalse(AppState.isTunnelActive(.disconnected))
        XCTAssertFalse(AppState.isTunnelActive(.disconnecting))
        XCTAssertFalse(AppState.isTunnelActive(.invalid))
    }

    func testAdoptRunningTunnelMatchesSystemStatus() async {
        // 测试宿主读的是这台机器的真实 VPN 配置（开发机上轻舟可能正在跑）——
        // 不能断言固定值，断言「采认结果与系统实际状态一致」。
        let state = makeState()
        XCTAssertFalse(state.isVPNRunning)
        await state.adoptRunningTunnelState()
        XCTAssertEqual(
            state.isVPNRunning,
            AppState.isTunnelActive(state.tunnelManager.status),
            "开关必须与系统 NEVPNStatus 对齐（这正是被修的 bug）"
        )
    }

    func testAdoptRunningTunnelRespectsInProgressState() async {
        // 本进程已经认为在跑 / 正在切换：采认不得干扰（幂等 guard）
        let state = makeState()
        state.isVPNRunning = true
        await state.adoptRunningTunnelState()
        XCTAssertTrue(state.isVPNRunning)
    }

    // MARK: - 系统 VPN 状态实时对齐（小组件/系统设置/快捷指令在 App 外改了隧道）

    func testReconcileTurnsOnWhenSystemConnected() {
        let state = makeState()
        XCTAssertFalse(state.isVPNRunning)
        // 小组件在后台开了 VPN → 系统状态 connected → App 侧应翻「开」
        state.reconcileVPNStatus(with: .connected)
        XCTAssertTrue(state.isVPNRunning)
    }

    func testReconcileTurnsOffWhenSystemDisconnected() {
        let state = makeState()
        state.isVPNRunning = true
        // 小组件在后台关了 VPN → 系统状态 disconnected → App 侧应翻「关」
        state.reconcileVPNStatus(with: .disconnected)
        XCTAssertFalse(state.isVPNRunning)
    }

    func testReconcileIgnoresTransientDisconnecting() {
        let state = makeState()
        state.isVPNRunning = true
        // .disconnecting 是瞬态，不翻，避免开关闪烁
        state.reconcileVPNStatus(with: .disconnecting)
        XCTAssertTrue(state.isVPNRunning)
    }

    func testReconcileSkippedDuringHotSwitch() {
        let state = makeState()
        state.isVPNRunning = true
        state.isSwitchingTunnel = true
        // 热切换 stop→start 的中间态不能被误读成「用户关了 VPN」
        state.reconcileVPNStatus(with: .disconnected)
        XCTAssertTrue(state.isVPNRunning)
    }
}
