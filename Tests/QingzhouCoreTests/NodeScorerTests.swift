import XCTest
@testable import QingzhouCore

/// NodeScorer：多维打分引擎（纯函数）。锚点归一（不随节点池相对漂移）：
/// 延迟 0.45 / 稳定性 0.30 / 带宽 0.15 / 成本 0.10，各维 0–100，总分 = 加权和。
final class NodeScorerTests: XCTestCase {

    private func input(
        direct: Int? = nil,
        proxied: Int? = nil,
        proxiedAt: Date? = nil,
        history: [NodeMetricSample] = [],
        peakDownBps: Int64? = nil,
        rate: Double = 1.0
    ) -> NodeScorer.Input {
        NodeScorer.Input(
            directLatencyMs: direct,
            proxiedLatencyMs: proxied,
            proxiedTestedAt: proxiedAt,
            history: history,
            peakDownBps: peakDownBps,
            rate: rate
        )
    }

    private func sample(latency: Int?, proxied: Int? = nil, loss: Double? = nil) -> NodeMetricSample {
        NodeMetricSample(at: Date(timeIntervalSince1970: 0), latencyMs: latency,
                         proxiedMs: proxied, lossFraction: loss)
    }

    // MARK: - 延迟维（锚点：≤50→100 · 100→85 · 200→60 · 400→30 · ≥800→0）

    func testLatencyAnchors() {
        XCTAssertEqual(NodeScorer.score(input(proxied: 30)).latency.score, 100)
        XCTAssertEqual(NodeScorer.score(input(proxied: 50)).latency.score, 100)
        XCTAssertEqual(NodeScorer.score(input(proxied: 100)).latency.score, 85)
        XCTAssertEqual(NodeScorer.score(input(proxied: 200)).latency.score, 60)
        XCTAssertEqual(NodeScorer.score(input(proxied: 400)).latency.score, 30)
        XCTAssertEqual(NodeScorer.score(input(proxied: 800)).latency.score, 0)
        XCTAssertEqual(NodeScorer.score(input(proxied: 1200)).latency.score, 0)
    }

    func testLatencyLinearInterpolationBetweenAnchors() {
        XCTAssertEqual(NodeScorer.score(input(proxied: 150)).latency.score, 72.5)
        XCTAssertEqual(NodeScorer.score(input(proxied: 300)).latency.score, 45)
        XCTAssertEqual(NodeScorer.score(input(proxied: 600)).latency.score, 15)
    }

    func testDirectLatencyFallbackCarriesPenalty() {
        // 只有直连：×1.3 惩罚后再归一（直连只量到设备→节点，低估全链路延迟）
        // 100×1.3=130 → 85 + (130−100)/100×(60−85) = 77.5
        XCTAssertEqual(NodeScorer.score(input(direct: 100)).latency.score, 77.5)
        // 50×1.3=65 → 100 − 15×(15/50) = 95.5
        XCTAssertEqual(NodeScorer.score(input(direct: 50)).latency.score, 95.5)
    }

    func testNoLatencyDataScoresZero() {
        XCTAssertEqual(NodeScorer.score(input()).latency.score, 0)
    }

    // MARK: - 延迟维混合（两者都有 → 0.7×经代理分 + 0.3×直连分，各自先锚点归一）

    func testLatencyBlendsProxiedWithDirect() {
        // proxied 100 → 85；direct 100×1.3=130 → 77.5；0.7×85 + 0.3×77.5 = 82.75
        XCTAssertEqual(NodeScorer.score(input(direct: 100, proxied: 100)).latency.score,
                       82.75, accuracy: 0.0001)
        // 归一后再混合、不混原始 ms：direct 1000（→0 分）仍按 0.3 权重拉低总分
        // （旧语义「经代理优先、直连不参与」下这里是 100）
        XCTAssertEqual(NodeScorer.score(input(direct: 1000, proxied: 50)).latency.score,
                       70, accuracy: 0.0001)
    }

    func testLatencyProxiedOnlyGetsFullWeight() {
        // 没有直连值：经代理独占延迟维（不做 0.7 折减）
        XCTAssertEqual(NodeScorer.score(input(proxied: 100)).latency.score, 85)
    }

    func testLatencyStaleProxiedFallsBackToDirectOnly() {
        // 经代理值距今 >24h：不参与混合（陈旧的经代理数字比新鲜直连更误导）→ 只剩直连×1.3
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stale = now.addingTimeInterval(-25 * 3600)
        XCTAssertEqual(
            NodeScorer.score(input(direct: 100, proxied: 100, proxiedAt: stale), now: now).latency.score,
            77.5)
        // ≤24h 仍新鲜：正常混合
        let fresh = now.addingTimeInterval(-3600)
        XCTAssertEqual(
            NodeScorer.score(input(direct: 100, proxied: 100, proxiedAt: fresh), now: now).latency.score,
            82.75, accuracy: 0.0001)
    }

    func testLatencyStaleProxiedAloneScoresZero() {
        // 陈旧经代理值整体出局（不只是不混合）：没有直连兜底时延迟维为 0
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stale = now.addingTimeInterval(-25 * 3600)
        XCTAssertEqual(
            NodeScorer.score(input(proxied: 100, proxiedAt: stale), now: now).latency.score, 0)
    }

    func testLatencyProxiedWithoutTimestampTreatedAsFresh() {
        // 经代理精选轮传当轮实测值、不带时间戳 —— 视为新鲜，照常混合
        XCTAssertEqual(NodeScorer.score(input(direct: 100, proxied: 100)).latency.score,
                       82.75, accuracy: 0.0001)
    }

    // MARK: - 稳定性维（100 × 成功率 × (1 − 0.5×变异系数)；样本<3 → 70 中性）

    func testStabilityNeutralWhenFewSamples() {
        XCTAssertEqual(NodeScorer.score(input()).stability.score, 70)
        let two = [sample(latency: 100), sample(latency: 100)]
        XCTAssertEqual(NodeScorer.score(input(history: two)).stability.score, 70)
    }

    func testStabilityPerfectHistoryScoresFull() {
        let history = [sample(latency: 100), sample(latency: 100), sample(latency: 100)]
        XCTAssertEqual(NodeScorer.score(input(history: history)).stability.score, 100)
    }

    func testStabilitySuccessRateHalvesOnHalfFailures() {
        let history = [sample(latency: 100), sample(latency: nil),
                       sample(latency: 100), sample(latency: nil)]
        XCTAssertEqual(NodeScorer.score(input(history: history)).stability.score, 50)
    }

    func testStabilityJitterLowersScore() {
        // [50,150,100]：均值 100，总体标准差 40.82 → CV 0.408 → 100×(1−0.204) ≈ 79.59
        let history = [sample(latency: 50), sample(latency: 150), sample(latency: 100)]
        XCTAssertEqual(NodeScorer.score(input(history: history)).stability.score, 79.59, accuracy: 0.01)
    }

    func testStabilityJitterTermClampedAtZero() {
        // 极端抖动（CV > 2）：抖动项砍到 0，不出负分
        let history = [sample(latency: 1), sample(latency: 1), sample(latency: 1),
                       sample(latency: 1), sample(latency: 1), sample(latency: 100_000)]
        XCTAssertEqual(NodeScorer.score(input(history: history)).stability.score, 0, accuracy: 0.5)
    }

    func testStabilityProxiedOnlySampleCountsAsSuccess() {
        // 手动经代理测速产生的独立样本（latencyMs=nil 但 proxiedMs 有值）是成功，
        // 不能算成直连失败 —— 否则手动测得越勤节点越被冤枉
        let history = [sample(latency: nil, proxied: 100),
                       sample(latency: nil, proxied: 110),
                       sample(latency: nil, proxied: 120)]
        XCTAssertEqual(NodeScorer.score(input(history: history)).stability.score, 100)
    }

    // MARK: - 稳定性维吸收丢包率（成功率细化为 1 − 平均丢包率）

    func testStabilityUsesLossFractionWhenPresent() {
        // burst 3 次每轮丢 1 次（lossFraction=1/3）、延迟恒定：
        // 100 × (1 − 1/3) × 1 ≈ 66.67 —— 旧口径只看「本轮成没成」会给满分
        let history = [sample(latency: 100, loss: 1.0 / 3),
                       sample(latency: 100, loss: 1.0 / 3),
                       sample(latency: 100, loss: 1.0 / 3)]
        XCTAssertEqual(NodeScorer.score(input(history: history)).stability.score,
                       100.0 * 2 / 3, accuracy: 0.01)
    }

    func testStabilityLegacySamplesFallBackToBinaryLoss() {
        // 无 lossFraction 的老样本按旧语义折算：成功 = 丢包 0、整轮失败 = 丢包 1；
        // 有 lossFraction 的按值。avgLoss = (0 + 1 + 2/3)/3 = 5/9 → 100×4/9 ≈ 44.44
        //（延迟 [100,100] 恒定 → cv=0，抖动项不折损）
        let history = [sample(latency: 100),
                       sample(latency: nil),
                       sample(latency: 100, loss: 2.0 / 3)]
        XCTAssertEqual(NodeScorer.score(input(history: history)).stability.score,
                       100.0 * 4 / 9, accuracy: 0.01)
    }

    func testStabilityAllBurstFailedSampleCountsAsFullLoss() {
        // burst 全失败的样本（latency=nil, lossFraction=1.0）与老失败样本等价
        let history = [sample(latency: 100), sample(latency: 100),
                       sample(latency: nil, loss: 1.0)]
        XCTAssertEqual(NodeScorer.score(input(history: history)).stability.score,
                       100.0 * 2 / 3, accuracy: 0.01)
    }

    // MARK: - 带宽维（≥8MB/s→100 · 2MB/s→60 · 0.5MB/s→30 · 无数据→60 中性）

    func testBandwidthAnchors() {
        let mb: Int64 = 1 << 20
        XCTAssertEqual(NodeScorer.score(input(peakDownBps: 8 * mb)).bandwidth.score, 100)
        XCTAssertEqual(NodeScorer.score(input(peakDownBps: 16 * mb)).bandwidth.score, 100)
        XCTAssertEqual(NodeScorer.score(input(peakDownBps: 2 * mb)).bandwidth.score, 60)
        XCTAssertEqual(NodeScorer.score(input(peakDownBps: mb / 2)).bandwidth.score, 30)
        // 中间线性插值：5MB/s → 60 + (3/6)×40 = 80；1.25MB/s → 30 + (0.75/1.5)×30 = 45
        XCTAssertEqual(NodeScorer.score(input(peakDownBps: 5 * mb)).bandwidth.score, 80)
        XCTAssertEqual(NodeScorer.score(input(peakDownBps: mb + mb / 4)).bandwidth.score, 45)
    }

    func testBandwidthNeutralWhenNoData() {
        // 没轮到当当前节点的不惩罚 —— 中性 60
        XCTAssertEqual(NodeScorer.score(input()).bandwidth.score, 60)
    }

    // MARK: - 成本维（≤0.5→100 · 1→80 · 2→40 · ≥5→10）

    func testCostAnchors() {
        XCTAssertEqual(NodeScorer.score(input(rate: 0.3)).cost.score, 100)
        XCTAssertEqual(NodeScorer.score(input(rate: 0.5)).cost.score, 100)
        XCTAssertEqual(NodeScorer.score(input(rate: 1.0)).cost.score, 80)
        XCTAssertEqual(NodeScorer.score(input(rate: 2.0)).cost.score, 40)
        XCTAssertEqual(NodeScorer.score(input(rate: 5.0)).cost.score, 10)
        XCTAssertEqual(NodeScorer.score(input(rate: 9.0)).cost.score, 10)
        // 中间线性插值
        XCTAssertEqual(NodeScorer.score(input(rate: 0.75)).cost.score, 90)
        XCTAssertEqual(NodeScorer.score(input(rate: 1.5)).cost.score, 60)
        XCTAssertEqual(NodeScorer.score(input(rate: 3.5)).cost.score, 25)
    }

    // MARK: - 总分与权重

    func testTotalIsWeightedSumOfComponents() {
        // proxied 100(→85) / 无历史(→70) / 无带宽(→60) / rate 1(→80)
        // 0.45×85 + 0.30×70 + 0.15×60 + 0.10×80 = 76.25
        let score = NodeScorer.score(input(proxied: 100))
        XCTAssertEqual(score.total, 76.25, accuracy: 0.0001)
        XCTAssertEqual(score.latency.weight, 0.45)
        XCTAssertEqual(score.stability.weight, 0.30)
        XCTAssertEqual(score.bandwidth.weight, 0.15)
        XCTAssertEqual(score.cost.weight, 0.10)
        let weightedSum = score.latency.weighted + score.stability.weighted
            + score.bandwidth.weighted + score.cost.weighted
        XCTAssertEqual(score.total, weightedSum, accuracy: 0.0001)
    }

    func testPreferLowerRateOffZeroesCostAndRedistributes() {
        // 关掉「优先低倍率」：成本维权重归 0，按比例摊给其余维度（Σ权重仍为 1）
        let score = NodeScorer.score(input(proxied: 100), preferLowerRate: false)
        XCTAssertEqual(score.cost.weight, 0)
        XCTAssertEqual(score.latency.weight, 0.5, accuracy: 0.0001)
        XCTAssertEqual(score.stability.weight, 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(score.bandwidth.weight, 1.0 / 6, accuracy: 0.0001)
        // (0.45×85 + 0.30×70 + 0.15×60) / 0.9 = 75.8333…
        XCTAssertEqual(score.total, 68.25 / 0.9, accuracy: 0.0001)
    }

    func testPreferLowerRateOffMakesRateIrrelevant() {
        // 既有语义：开关关闭 = 倍率完全不参与决策
        let cheap = NodeScorer.score(input(proxied: 100, rate: 0.5), preferLowerRate: false)
        let pricey = NodeScorer.score(input(proxied: 100, rate: 5.0), preferLowerRate: false)
        XCTAssertEqual(cheap.total, pricey.total, accuracy: 0.0001)
    }
}
