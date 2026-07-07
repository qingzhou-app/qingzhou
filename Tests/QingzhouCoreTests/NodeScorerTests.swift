import XCTest
@testable import QingzhouCore

/// NodeScorer：多维打分引擎（纯函数）。锚点归一（不随节点池相对漂移）：
/// 延迟 0.45 / 稳定性 0.30 / 带宽 0.15 / 成本 0.10，各维 0–100，总分 = 加权和。
final class NodeScorerTests: XCTestCase {

    private func input(
        direct: Int? = nil,
        proxied: Int? = nil,
        history: [NodeMetricSample] = [],
        peakDownBps: Int64? = nil,
        rate: Double = 1.0
    ) -> NodeScorer.Input {
        NodeScorer.Input(
            directLatencyMs: direct,
            proxiedLatencyMs: proxied,
            history: history,
            peakDownBps: peakDownBps,
            rate: rate
        )
    }

    private func sample(latency: Int?, proxied: Int? = nil) -> NodeMetricSample {
        NodeMetricSample(at: Date(timeIntervalSince1970: 0), latencyMs: latency, proxiedMs: proxied)
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

    func testProxiedLatencyPreferredOverDirect() {
        // 经代理延迟是真实路径，优先于直连；直连值再差也不参与
        XCTAssertEqual(NodeScorer.score(input(direct: 1000, proxied: 50)).latency.score, 100)
    }

    func testNoLatencyDataScoresZero() {
        XCTAssertEqual(NodeScorer.score(input()).latency.score, 0)
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
