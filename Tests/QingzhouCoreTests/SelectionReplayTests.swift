import XCTest
@testable import QingzhouCore

/// SelectionReplay：离线回放对比 harness —— 同一份测量序列回放两个策略：
/// A「纯 Ping 最低」（竞品基线，Clash url-test 式）vs B「多维打分 + 分数黏性」
/// （**直接调 NodeScorer**，黏性参数镜像 AppState 常量：领先 ≥8 分连 2 轮）。
/// 产出 ReplayReport：有效延迟均值/中位数 → 提速%、倍率×单位流量 → 省流量%、
/// 切换次数对比、每轮明细 + Markdown 渲染。
final class SelectionReplayTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    /// 每 30 分钟一轮（现网 schedulerLoop 默认间隔）。
    private func makeRounds(_ perRound: [[String: SelectionReplay.Observation]]) -> [SelectionReplay.Round] {
        perRound.enumerated().map { i, obs in
            SelectionReplay.Round(at: t0.addingTimeInterval(Double(i) * 1800), observations: obs)
        }
    }

    private func obs(_ direct: Int?, proxied: Int? = nil, loss: Double? = nil) -> SelectionReplay.Observation {
        SelectionReplay.Observation(directMs: direct, proxiedMs: proxied, lossFraction: loss)
    }

    // MARK: - 策略 A（纯 Ping 基线）

    func testPingBaselinePicksLowestDirectEachRoundWithoutStickiness() {
        let nodes = [
            SelectionReplay.NodeSpec(id: "p", name: "P"),
            SelectionReplay.NodeSpec(id: "q", name: "Q"),
        ]
        // r0: p 最低；r1: p 失败 → q；r2: p 回来 → p。无黏性，说切就切。
        let rounds = makeRounds([
            ["p": obs(30), "q": obs(50)],
            ["p": obs(nil, loss: 1.0), "q": obs(50)],
            ["p": obs(30), "q": obs(50)],
        ])
        let report = SelectionReplay.replay(nodes: nodes, rounds: rounds)
        XCTAssertEqual(report.rounds.map(\.pingChoice), ["p", "q", "p"])
        XCTAssertEqual(report.ping.switchCount, 2)
    }

    // MARK: - 场景①：B 靠稳定性避开「延迟低但高丢包」节点，A 中招

    /// flaky 直连 40ms 但每轮丢 2/3（burst 3 次成 1 次）；steady 60ms 零丢包。
    /// A 每轮都选 flaky（40 < 60），有效延迟 40/(1-2/3) = 120ms 吃满 10 轮；
    /// B 前 3 轮历史不足（稳定性中性分）同样在 flaky 上，第 3 轮起稳定性维揭穿
    /// （33 分 vs 100 分），steady 领先 16+ 分，黏性连 2 轮后第 4 轮切走。
    func testScoringEscapesLowLatencyHighLossNodeWhilePingStays() {
        let nodes = [
            SelectionReplay.NodeSpec(id: "flaky", name: "SG-Flaky"),
            SelectionReplay.NodeSpec(id: "steady", name: "JP-Steady"),
        ]
        let rounds = makeRounds(Array(repeating: [
            "flaky": obs(40, loss: 2.0 / 3.0),
            "steady": obs(60, loss: 0),
        ], count: 10))
        let report = SelectionReplay.replay(nodes: nodes, rounds: rounds)

        // A：10 轮全在 flaky 上，10 轮全踩高丢包
        XCTAssertTrue(report.rounds.allSatisfy { $0.pingChoice == "flaky" })
        XCTAssertEqual(report.ping.lossyRoundCount, 10)
        XCTAssertEqual(report.ping.meanEffectiveMs, 120, accuracy: 0.01)
        XCTAssertEqual(report.ping.medianEffectiveMs, 120, accuracy: 0.01)

        // B：r0-r2 在 flaky（r2 挑战者被黏性拦下第 1 轮），r3 起切到 steady
        XCTAssertEqual(report.rounds[0].scoringChoice, "flaky")
        XCTAssertEqual(report.rounds[2].scoringChoice, "flaky")
        XCTAssertEqual(report.rounds[2].scoringHeldChallenger, "steady")   // 黏性 1/2 轮
        XCTAssertEqual(report.rounds[3].scoringChoice, "steady")
        XCTAssertTrue(report.rounds[3...].allSatisfy { $0.scoringChoice == "steady" })
        XCTAssertEqual(report.scoring.switchCount, 1)
        XCTAssertEqual(report.scoring.lossyRoundCount, 3)
        XCTAssertEqual(report.scoring.meanEffectiveMs, 78, accuracy: 0.01)  // (3×120+7×60)/10
        XCTAssertEqual(report.scoring.medianEffectiveMs, 60, accuracy: 0.01)

        // 提速 = (120-78)/120 = 35%
        XCTAssertEqual(report.speedupPercent, 35, accuracy: 0.05)
    }

    // MARK: - 场景②：B 靠黏性少切，A 每轮横跳

    /// 两个等质量节点延迟交替领先（50/80 互换）：A 每轮易主（9 次切换），
    /// B 分差 ~5 分 < 8 分黏性门槛，一次不切。代价是均值略高（50 vs 65）——
    /// 这是黏性换稳定的诚实取舍，方向断言为负提速。
    func testScoringHoldsThroughJitterWhilePingFlipFlopsEveryRound() {
        let nodes = [
            SelectionReplay.NodeSpec(id: "n1", name: "N1"),
            SelectionReplay.NodeSpec(id: "n2", name: "N2"),
        ]
        let rounds = makeRounds((0..<10).map { i in
            i % 2 == 0
                ? ["n1": obs(50, loss: 0), "n2": obs(80, loss: 0)]
                : ["n1": obs(80, loss: 0), "n2": obs(50, loss: 0)]
        })
        let report = SelectionReplay.replay(nodes: nodes, rounds: rounds)
        XCTAssertEqual(report.ping.switchCount, 9)
        XCTAssertEqual(report.scoring.switchCount, 0)
        XCTAssertEqual(report.switchReduction, 9)
        XCTAssertTrue(report.rounds.allSatisfy { $0.scoringChoice == "n1" })
        XCTAssertLessThan(report.speedupPercent, 0)   // 黏性的代价，诚实呈现
    }

    // MARK: - 场景③：延迟接近时 B 选低倍率省流量

    /// fast2x 45ms/2.0x vs cheap 55ms/0.5x：A 只看延迟永远选 2x；
    /// B 的成本维（0.5x→100 分 vs 2x→40 分）盖过 10ms 延迟差，全程 0.5x。
    /// 省流量 = (10×2.0 − 10×0.5)/(10×2.0) = 75%。
    func testScoringPrefersLowRateWhenLatencyCloseAndSavesTraffic() {
        let nodes = [
            SelectionReplay.NodeSpec(id: "fast2x", name: "HK-2x", rate: 2.0),
            SelectionReplay.NodeSpec(id: "cheap", name: "HK-0.5x", rate: 0.5),
        ]
        let rounds = makeRounds(Array(repeating: [
            "fast2x": obs(45, loss: 0),
            "cheap": obs(55, loss: 0),
        ], count: 10))
        let report = SelectionReplay.replay(nodes: nodes, rounds: rounds)
        XCTAssertTrue(report.rounds.allSatisfy { $0.pingChoice == "fast2x" })
        XCTAssertTrue(report.rounds.allSatisfy { $0.scoringChoice == "cheap" })
        XCTAssertEqual(report.ping.trafficCostUnits, 20, accuracy: 0.001)
        XCTAssertEqual(report.scoring.trafficCostUnits, 5, accuracy: 0.001)
        XCTAssertEqual(report.trafficSavingPercent, 75, accuracy: 0.01)
        XCTAssertEqual(report.scoring.switchCount, 0)
    }

    /// preferLowerRate 关掉 = 倍率完全不参与决策（镜像现网开关语义）→ B 也选 fast2x。
    func testPreferLowerRateOffMakesScoringIgnoreRate() {
        let nodes = [
            SelectionReplay.NodeSpec(id: "fast2x", name: "HK-2x", rate: 2.0),
            SelectionReplay.NodeSpec(id: "cheap", name: "HK-0.5x", rate: 0.5),
        ]
        let rounds = makeRounds(Array(repeating: [
            "fast2x": obs(45, loss: 0),
            "cheap": obs(55, loss: 0),
        ], count: 3))
        var config = SelectionReplay.Config()
        config.preferLowerRate = false
        let report = SelectionReplay.replay(nodes: nodes, rounds: rounds, config: config)
        XCTAssertTrue(report.rounds.allSatisfy { $0.scoringChoice == "fast2x" })
    }

    // MARK: - 有效延迟口径

    /// 有效延迟优先用经代理实测（真实端到端），没有才退直连。
    func testEffectiveLatencyPrefersProxiedOverDirect() {
        let nodes = [SelectionReplay.NodeSpec(id: "x", name: "X")]
        let rounds = makeRounds([["x": obs(30, proxied: 100, loss: 0)]])
        let report = SelectionReplay.replay(nodes: nodes, rounds: rounds)
        XCTAssertEqual(report.rounds[0].pingEffectiveMs ?? -1, 100, accuracy: 0.01)
        XCTAssertEqual(report.rounds[0].scoringEffectiveMs ?? -1, 100, accuracy: 0.01)
    }

    /// 所选节点整轮测不通：按 outagePenaltyMs 计入延迟并单独计数（不算 lossy）。
    func testOutageRoundUsesPenaltyLatencyAndIsCountedSeparately() {
        let nodes = [SelectionReplay.NodeSpec(id: "solo", name: "Solo")]
        let rounds = makeRounds([
            ["solo": obs(50, loss: 0)],
            ["solo": obs(nil, loss: 1.0)],
        ])
        let report = SelectionReplay.replay(nodes: nodes, rounds: rounds)
        XCTAssertEqual(report.ping.outageRoundCount, 1)
        XCTAssertEqual(report.scoring.outageRoundCount, 1)
        XCTAssertEqual(report.ping.lossyRoundCount, 0)
        XCTAssertEqual(report.rounds[1].pingEffectiveMs ?? -1, 1000, accuracy: 0.01)  // 默认罚值
        XCTAssertEqual(report.ping.meanEffectiveMs, 525, accuracy: 0.01)
    }

    // MARK: - 加权与预热

    /// 域名权重接口留口子：每轮延迟权重（P2 域名画像落地后轮内按域名加权，轮间签名不变）。
    func testRoundLatencyWeightsChangeWeightedMeanButNotMedian() {
        let nodes = [SelectionReplay.NodeSpec(id: "x", name: "X")]
        let rounds = makeRounds([["x": obs(100, loss: 0)], ["x": obs(200, loss: 0)]])
        var config = SelectionReplay.Config()
        config.roundLatencyWeights = [3, 1]
        let report = SelectionReplay.replay(nodes: nodes, rounds: rounds, config: config)
        XCTAssertEqual(report.ping.meanEffectiveMs, 125, accuracy: 0.01)   // (3×100+200)/4
        XCTAssertEqual(report.ping.medianEffectiveMs, 150, accuracy: 0.01) // 中位数不加权
    }

    /// 预热轮只喂测量历史（消解稳定性维的冷启动中性分），不计入统计。
    func testWarmupRoundsFeedHistoryButAreExcludedFromStats() {
        let nodes = [SelectionReplay.NodeSpec(id: "x", name: "X")]
        let rounds = makeRounds([["x": obs(500, loss: 0)], ["x": obs(50, loss: 0)]])
        var config = SelectionReplay.Config()
        config.warmupRounds = 1
        let report = SelectionReplay.replay(nodes: nodes, rounds: rounds, config: config)
        XCTAssertEqual(report.ping.statsRoundCount, 1)
        XCTAssertEqual(report.ping.meanEffectiveMs, 50, accuracy: 0.01)
        XCTAssertEqual(report.ping.trafficCostUnits, 1, accuracy: 0.001)
        XCTAssertFalse(report.rounds[0].countedInStats)
        XCTAssertTrue(report.rounds[1].countedInStats)
    }

    // MARK: - 打分必须与 NodeScorer 完全一致（复用而非重写的契约）

    func testRoundDetailScoreMatchesNodeScorerExactly() {
        let nodes = [SelectionReplay.NodeSpec(id: "x", name: "X", rate: 1.5)]
        let rounds = makeRounds([["x": obs(120, loss: 1.0 / 3.0)]])
        let report = SelectionReplay.replay(nodes: nodes, rounds: rounds)
        // 回放内部先落历史再打分（与 autoSelectBestNode 顺序一致）→ 本轮样本在历史里
        let expected = NodeScorer.score(
            NodeScorer.Input(
                directLatencyMs: 120,
                history: [NodeMetricSample(at: rounds[0].at, latencyMs: 120, lossFraction: 1.0 / 3.0)],
                rate: 1.5
            ),
            now: rounds[0].at
        ).total
        XCTAssertEqual(report.rounds[0].scoringChoiceScore ?? -1, expected, accuracy: 0.0001)
    }

    // MARK: - 从 NodeMetricsHistory 构造回放输入

    func testRoundsFromNodeMetricsHistoryClustersSamplesIntoRounds() {
        var history = NodeMetricsHistory()
        history.recordDirect(fingerprint: "a", latencyMs: 40, lossFraction: 0, at: t0)
        history.recordDirect(fingerprint: "b", latencyMs: 60, at: t0.addingTimeInterval(5))
        history.recordProxied(fingerprint: "a", proxiedMs: 120, at: t0.addingTimeInterval(60))  // 同轮并入
        let r2 = t0.addingTimeInterval(1800)
        history.recordDirect(fingerprint: "a", latencyMs: 45, lossFraction: 0, at: r2)
        history.recordDirect(fingerprint: "b", latencyMs: nil, lossFraction: 1.0, at: r2)

        let rounds = SelectionReplay.rounds(from: history)
        XCTAssertEqual(rounds.count, 2)
        XCTAssertEqual(rounds[0].at, t0)
        XCTAssertEqual(rounds[0].observations["a"], obs(40, proxied: 120, loss: 0))
        XCTAssertEqual(rounds[0].observations["b"], obs(60))
        XCTAssertEqual(rounds[1].observations["a"], obs(45, loss: 0))
        XCTAssertEqual(rounds[1].observations["b"], obs(nil, loss: 1.0))
    }

    // MARK: - 综合场景（宣发数字的来源）+ Markdown 报告

    /// 4 节点 12 轮（预热 3）：两个同区低 ping 高丢包节点交替霸榜（超售机场常态），
    /// A 在它们之间每轮横跳且轮轮踩丢包；B 第 4 轮起稳定在低倍率健康节点上。
    /// 断言三个宣发口径的方向与量级：提速 ~27.8%、省流量 50%、少切换 8 次。
    func testCombinedScenarioProducesHeadlineNumbersAndMarkdownReport() {
        let nodes = [
            SelectionReplay.NodeSpec(id: "hk", name: "HK-0.5x", rate: 0.5),
            SelectionReplay.NodeSpec(id: "jp", name: "JP-2x", rate: 2.0),
            SelectionReplay.NodeSpec(id: "sga", name: "SG-A", rate: 1.0),
            SelectionReplay.NodeSpec(id: "sgb", name: "SG-B", rate: 1.0),
        ]
        let rounds = makeRounds((0..<12).map { i in
            [
                "hk": obs(65, loss: 0),
                "jp": obs(40, loss: 0),
                "sga": obs(i % 2 == 0 ? 30 : 45, loss: 2.0 / 3.0),
                "sgb": obs(i % 2 == 0 ? 45 : 30, loss: 2.0 / 3.0),
            ]
        })
        var config = SelectionReplay.Config()
        config.warmupRounds = 3
        let report = SelectionReplay.replay(nodes: nodes, rounds: rounds, config: config)

        XCTAssertEqual(report.ping.meanEffectiveMs, 90, accuracy: 0.01)     // 30/(1-2/3)
        XCTAssertEqual(report.scoring.meanEffectiveMs, 65, accuracy: 0.01)  // HK 直连
        XCTAssertEqual(report.speedupPercent, 27.78, accuracy: 0.05)
        XCTAssertEqual(report.trafficSavingPercent, 50, accuracy: 0.01)     // 9 vs 4.5 单位
        XCTAssertEqual(report.ping.switchCount, 9)
        XCTAssertEqual(report.scoring.switchCount, 1)
        XCTAssertEqual(report.switchReduction, 8)
        XCTAssertEqual(report.ping.lossyRoundCount, 9)
        XCTAssertEqual(report.scoring.lossyRoundCount, 0)

        let md = report.renderMarkdown()
        XCTAssertTrue(md.contains("提速 27.8%、省流量 50.0%、少切换 8 次"), md)
        XCTAssertTrue(md.contains("| 指标 |"))                  // 对比表
        XCTAssertTrue(md.contains("非普适"))                    // 诚实脚注
        XCTAssertTrue(md.contains("仅按 Ping"))                 // 不点竞品名
        XCTAssertTrue(md.contains("HK-0.5x"))                   // 明细用节点名
        print("===== SAMPLE REPLAY REPORT =====\n\(md)\n===== END SAMPLE =====")
    }

    /// 结论负向时措辞不误导（提速为负 → 写「有效延迟 +X%」而不是「提速 -X%」）。
    func testMarkdownPhrasesNegativeOutcomesHonestly() {
        let nodes = [
            SelectionReplay.NodeSpec(id: "n1", name: "N1"),
            SelectionReplay.NodeSpec(id: "n2", name: "N2"),
        ]
        let rounds = makeRounds((0..<10).map { i in
            i % 2 == 0
                ? ["n1": obs(50, loss: 0), "n2": obs(80, loss: 0)]
                : ["n1": obs(80, loss: 0), "n2": obs(50, loss: 0)]
        })
        let report = SelectionReplay.replay(nodes: nodes, rounds: rounds)
        let md = report.renderMarkdown()
        XCTAssertFalse(md.contains("提速 -"), md)
        XCTAssertTrue(md.contains("有效延迟 +"), md)
    }
}
