import XCTest
import QingzhouCore
import QingzhouSpeedTest
import QingzhouLogging
@testable import QingzhouApp

/// 多维打分择优（P1）：选优内核按 NodeScorer 总分选最高者 + 分数黏性（自动路径
/// 挑战者须领先 ≥8 分且连续 2 轮）+ 测量历史落盘。
@MainActor
final class NodeScoringSelectionTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("node-scoring-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    /// 按 host 返回固定延迟的假探针 —— 全流程测试不能真发 TCP 探测
    /// （不存在的域名解析失败 + 超时会把测试拖爆）。
    private struct FakeLatencyProber: LatencyProber {
        var latencyByHost: [String: Int] = [:]
        func probe(_ url: URL, timeout: TimeInterval) async -> LatencyResult {
            LatencyResult(url: url, latencyMs: latencyByHost[url.host ?? ""])
        }
    }

    private func makeState(latencyByHost: [String: Int] = [:]) -> AppState {
        AppState(
            logger: Logger(capacity: 100, minimumLevel: .debug),
            persistence: Persistence(directory: tmpDir),
            nodeSelector: NodeSelector(prober: FakeLatencyProber(latencyByHost: latencyByHost))
        )
    }

    private func node(_ name: String, host: String, latency: Int? = nil) -> Node {
        Node(name: name, protocolType: .trojan, host: host, port: 443,
             password: "pw", lastLatencyMs: latency)
    }

    /// 给节点灌 count 条恒定延迟的历史；interleaveFailures 时一半样本是失败（成功率 0.5）。
    private func seedHistory(_ state: AppState, node: Node, count: Int,
                             latencyMs: Int, interleaveFailures: Bool = false) {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<count {
            let failed = interleaveFailures && i % 2 == 1
            state.nodeMetricsHistory.recordDirect(
                fingerprint: node.identityFingerprint,
                latencyMs: failed ? nil : latencyMs,
                at: base.addingTimeInterval(Double(i))
            )
        }
    }

    // MARK: - 选优内核：总分最高者当选

    func testPickBestPrefersStableNodeOverJitteryFasterOne() {
        let state = makeState()
        // 快但一半轮次测不通（稳定性 50）vs 慢 30ms 但满勤（稳定性 100）：
        // 总分 A ≈ 73.2 < B ≈ 83.3 —— 纯延迟择优会翻车的场景，打分应选稳定的
        let jittery = node("快但抖", host: "a.com", latency: 60)
        let stable = node("稳但慢", host: "b.com", latency: 90)
        seedHistory(state, node: jittery, count: 10, latencyMs: 60, interleaveFailures: true)
        seedHistory(state, node: stable, count: 10, latencyMs: 90)
        state.nodes = [jittery, stable]

        XCTAssertEqual(state.pickBestRespectingRegions(from: state.nodes)?.name, "稳但慢")
    }

    func testPickBestFallsBackToLatencyWithoutHistory() {
        let state = makeState()
        // 无历史（稳定性同为中性 70）、无带宽、同倍率：退化为延迟低者胜
        state.nodes = [node("快", host: "a.com", latency: 50),
                       node("慢", host: "b.com", latency: 200)]
        XCTAssertEqual(state.pickBestRespectingRegions(from: state.nodes)?.name, "快")
    }

    // MARK: - 分数黏性（自动路径连续 2 轮领先 ≥8 分才切换）

    /// 挑战者 60ms vs 在位者 300ms（无历史）：总分差 ≈ 27 分，远超 8 分门槛。
    private func bigGapPair() -> (challenger: Node, incumbent: Node) {
        (node("挑战者", host: "a.com", latency: 60), node("在位者", host: "b.com", latency: 300))
    }

    func testScheduledSwitchNeedsTwoConsecutiveWinningRounds() {
        let state = makeState()
        state.isVPNRunning = true
        let (challenger, incumbent) = bigGapPair()
        // 第 1 轮领先：先按兵不动（单轮领先大概率是测量抖动）
        XCTAssertTrue(state.shouldHoldForScoreStickiness(
            origin: .scheduled, challenger: challenger, incumbent: incumbent))
        // 第 2 轮仍领先：放行
        XCTAssertFalse(state.shouldHoldForScoreStickiness(
            origin: .scheduled, challenger: challenger, incumbent: incumbent))
    }

    func testManualSelectIsNotHeldByStreak() {
        let state = makeState()
        state.isVPNRunning = true
        let (challenger, incumbent) = bigGapPair()
        // 手动点「择优」是用户主动要换：一轮就换（仍受 autoSwitchWorthRestart 幅度闸，
        // 那个闸不归本判定管）
        XCTAssertFalse(state.shouldHoldForScoreStickiness(
            origin: .manual, challenger: challenger, incumbent: incumbent))
    }

    func testStickinessOnlyAppliesWhileVPNRunning() {
        let state = makeState()
        state.isVPNRunning = false
        let (challenger, incumbent) = bigGapPair()
        // VPN 没跑时改 currentNodeId 不花钱，不设黏性
        XCTAssertFalse(state.shouldHoldForScoreStickiness(
            origin: .scheduled, challenger: challenger, incumbent: incumbent))
    }

    func testIncumbentMeasurementFailureReleasesImmediately() {
        let state = makeState()
        state.isVPNRunning = true
        let challenger = node("挑战者", host: "a.com", latency: 60)
        let broken = node("在位者已坏", host: "b.com", latency: nil)
        // 当前节点本轮测速失败 = 已坏：沿用 autoSwitchWorthRestart 的 nil 放行语义，不等轮次
        XCTAssertFalse(state.shouldHoldForScoreStickiness(
            origin: .scheduled, challenger: challenger, incumbent: broken))
    }

    func testChallengerChangeRestartsStreak() {
        let state = makeState()
        state.isVPNRunning = true
        let (challengerA, incumbent) = bigGapPair()
        let challengerB = node("挑战者B", host: "c.com", latency: 55)
        XCTAssertTrue(state.shouldHoldForScoreStickiness(
            origin: .scheduled, challenger: challengerA, incumbent: incumbent))
        // 换了个挑战者：连续计数从头来 —— 不能拿别人攒的轮次
        XCTAssertTrue(state.shouldHoldForScoreStickiness(
            origin: .scheduled, challenger: challengerB, incumbent: incumbent))
        XCTAssertFalse(state.shouldHoldForScoreStickiness(
            origin: .scheduled, challenger: challengerB, incumbent: incumbent))
    }

    func testMarginBelowThresholdHoldsAndResetsStreak() {
        let state = makeState()
        state.isVPNRunning = true
        let (bigChallenger, incumbent) = bigGapPair()
        // 领先不足 8 分的挑战者（95ms vs 100ms，总分差 ≈ 0.7）：永远按兵不动
        let smallChallenger = node("将将好一点", host: "c.com", latency: 95)
        let closeIncumbent = node("在位者", host: "b.com", latency: 100)
        XCTAssertTrue(state.shouldHoldForScoreStickiness(
            origin: .scheduled, challenger: smallChallenger, incumbent: closeIncumbent))
        XCTAssertTrue(state.shouldHoldForScoreStickiness(
            origin: .scheduled, challenger: smallChallenger, incumbent: closeIncumbent))
        // 大挑战者攒了 1 轮 → 小挑战者一轮不合格清零 → 大挑战者要重新攒满 2 轮
        XCTAssertTrue(state.shouldHoldForScoreStickiness(
            origin: .scheduled, challenger: bigChallenger, incumbent: incumbent))
        XCTAssertTrue(state.shouldHoldForScoreStickiness(
            origin: .scheduled, challenger: smallChallenger, incumbent: closeIncumbent))
        XCTAssertTrue(state.shouldHoldForScoreStickiness(
            origin: .scheduled, challenger: bigChallenger, incumbent: incumbent))
        XCTAssertFalse(state.shouldHoldForScoreStickiness(
            origin: .scheduled, challenger: bigChallenger, incumbent: incumbent))
    }

    // MARK: - 全流程：测量落历史 + 内核替换生效

    func testAutoSelectRecordsHistoryAndPicksByScore() async throws {
        // b.com 探测失败（nil）也要落历史 —— 稳定性维度靠失败样本算成功率
        let state = makeState(latencyByHost: ["a.com": 80])
        try state.addNode(fromURL: "trojan://pw@a.com:443#好节点")
        try state.addNode(fromURL: "trojan://pw@b.com:443#坏节点")

        await state.autoSelectBestNode()

        XCTAssertEqual(state.currentNode?.name, "好节点")
        let good = state.nodes.first { $0.name == "好节点" }!
        let bad = state.nodes.first { $0.name == "坏节点" }!
        XCTAssertEqual(state.nodeMetricsHistory.samples(for: good.identityFingerprint).map(\.latencyMs), [80])
        XCTAssertEqual(state.nodeMetricsHistory.samples(for: bad.identityFingerprint).count, 1)
        XCTAssertNil(state.nodeMetricsHistory.samples(for: bad.identityFingerprint).first?.latencyMs)
    }

    // MARK: - 落盘与启动加载

    func testHistoryPersistsAndReloads() throws {
        let state = makeState()
        state.nodeMetricsSaveInterval = 0   // 关掉节流做确定性断言
        try state.addNode(fromURL: "trojan://pw@a.com:443#N")
        let n = state.nodes[0]
        state.recordNodeDirectMeasurement(n, latencyMs: 77, at: Date(timeIntervalSince1970: 1_700_000_000))
        state.persistence.waitForPendingWritesForTesting()

        let reloaded = makeState()
        XCTAssertEqual(reloaded.nodeMetricsHistory.samples(for: n.identityFingerprint).map(\.latencyMs), [77])
    }

    func testHistoryOfVanishedNodesPrunedOnLoad() throws {
        let state = makeState()
        state.nodeMetricsSaveInterval = 0
        try state.addNode(fromURL: "trojan://pw@a.com:443#N")
        // 一条属于早已不存在节点的历史：下次启动加载时应被清掉
        state.nodeMetricsHistory.recordDirect(fingerprint: "ss://gone@dead.com:8388", latencyMs: 50)
        state.recordNodeDirectMeasurement(state.nodes[0], latencyMs: 60, at: Date())
        state.persistence.waitForPendingWritesForTesting()

        let reloaded = makeState()
        XCTAssertFalse(reloaded.nodeMetricsHistory.samples(for: state.nodes[0].identityFingerprint).isEmpty)
        XCTAssertTrue(reloaded.nodeMetricsHistory.samples(for: "ss://gone@dead.com:8388").isEmpty)
    }
}
