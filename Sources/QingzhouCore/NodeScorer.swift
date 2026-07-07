import Foundation

/// 节点多维打分引擎（纯函数，不做 IO）—— 自动择优的内核。
///
/// `score = Σ w_d × s_d`，每维 s_d ∈ [0,100]，**锚点归一**：分数含义固定
/// （「85 分的延迟」永远指 ~100ms），不随节点池相对漂移，可解释、可跨轮比较 ——
/// 分数黏性（连续 N 轮领先才切换）依赖这一点。
///
/// | 维度 | 权重(均衡档) | 缺数据时 |
/// |---|---|---|
/// | 延迟 | 0.45 | 经代理优先，缺则直连×1.3 惩罚；全缺 → 0 |
/// | 稳定性 | 0.30 | 样本 <3 → 70 中性 |
/// | 带宽 | 0.15 | 无被动观测 → 60 中性（没轮到当当前节点的不惩罚） |
/// | 成本 | 0.10 | 倍率识别不出按 1.0（调用方 `rateForComparison` 已兜底） |
public enum NodeScorer {

    /// 各维权重。P2 的三档预设（速度优先/均衡/省流量）就是三组不同权重；P1 只有均衡档。
    public struct Weights: Sendable, Equatable {
        public var latency: Double
        public var stability: Double
        public var bandwidth: Double
        public var cost: Double

        public init(latency: Double, stability: Double, bandwidth: Double, cost: Double) {
            self.latency = latency
            self.stability = stability
            self.bandwidth = bandwidth
            self.cost = cost
        }

        public static let balanced = Weights(latency: 0.45, stability: 0.30, bandwidth: 0.15, cost: 0.10)
    }

    /// 打分输入 —— 调用方从 Node / NodeMetricsHistory 拼装，引擎本身不认识 Node
    ///（保持纯函数，单测不用构造完整节点）。
    public struct Input: Sendable {
        public var directLatencyMs: Int?
        public var proxiedLatencyMs: Int?
        public var history: [NodeMetricSample]
        public var peakDownBps: Int64?
        public var rate: Double

        public init(
            directLatencyMs: Int? = nil,
            proxiedLatencyMs: Int? = nil,
            history: [NodeMetricSample] = [],
            peakDownBps: Int64? = nil,
            rate: Double = 1.0
        ) {
            self.directLatencyMs = directLatencyMs
            self.proxiedLatencyMs = proxiedLatencyMs
            self.history = history
            self.peakDownBps = peakDownBps
            self.rate = rate
        }
    }

    /// 单维分量：原始分（0–100）+ 实际生效的权重。保留分量而不只给总分 ——
    /// 后续 UI「为什么选它」（分数构成条）要用。
    public struct Component: Sendable, Equatable {
        public var score: Double
        public var weight: Double
        public var weighted: Double { score * weight }
    }

    public struct Score: Sendable, Equatable {
        public var total: Double
        public var latency: Component
        public var stability: Component
        public var bandwidth: Component
        public var cost: Component
    }

    /// 直连延迟的惩罚系数：直连 TCP 握手只量到「设备→节点」，系统性低估全链路延迟，
    /// 与经代理实测值同台比较时要抬一手。
    public static let directLatencyPenalty = 1.3
    /// 稳定性中性分（样本不足时不奖不罚）。
    public static let neutralStability: Double = 70
    /// 带宽中性分（无被动观测时不奖不罚）。
    public static let neutralBandwidth: Double = 60
    /// 稳定性维度的最小样本数，不足按中性分。
    public static let minStabilitySamples = 3

    /// 给一个节点打分。`preferLowerRate == false` 时成本维权重置 0、按比例摊给其余维度
    /// —— 保留「延迟接近时优先低倍率」开关的既有语义：关掉 = 倍率完全不参与决策。
    public static func score(
        _ input: Input,
        preferLowerRate: Bool = true,
        weights: Weights = .balanced
    ) -> Score {
        var w = weights
        if !preferLowerRate {
            let remaining = w.latency + w.stability + w.bandwidth
            if remaining > 0 {
                let scale = (remaining + w.cost) / remaining
                w.latency *= scale
                w.stability *= scale
                w.bandwidth *= scale
            }
            w.cost = 0
        }
        let latency = Component(score: latencyScore(input), weight: w.latency)
        let stability = Component(score: stabilityScore(history: input.history), weight: w.stability)
        let bandwidth = Component(score: bandwidthScore(input.peakDownBps), weight: w.bandwidth)
        let cost = Component(score: costScore(input.rate), weight: w.cost)
        return Score(
            total: latency.weighted + stability.weighted + bandwidth.weighted + cost.weighted,
            latency: latency,
            stability: stability,
            bandwidth: bandwidth,
            cost: cost
        )
    }

    // MARK: - 各维归一（internal 方便聚焦测试，外部只走 score()）

    static func latencyScore(_ input: Input) -> Double {
        let ms: Double
        if let proxied = input.proxiedLatencyMs {
            ms = Double(proxied)                                   // 真实路径，原值使用
        } else if let direct = input.directLatencyMs {
            ms = Double(direct) * directLatencyPenalty
        } else {
            return 0                                               // 全无数据 = 不可用
        }
        return piecewise(ms, anchors: [(50, 100), (100, 85), (200, 60), (400, 30), (800, 0)])
    }

    /// `100 × 成功率 × (1 − 0.5×延迟变异系数)`，抖动项下限 0（极端抖动不出负分）。
    /// 成功 = 该轮直连或经代理任一测通（手动经代理测速的独立样本不能算成直连失败）；
    /// 变异系数只用直连延迟算 —— 直连每轮都测、口径统一，混入经代理值会比错尺度。
    static func stabilityScore(history: [NodeMetricSample]) -> Double {
        guard history.count >= minStabilitySamples else { return neutralStability }
        let successCount = history.count(where: { $0.latencyMs != nil || $0.proxiedMs != nil })
        let successRate = Double(successCount) / Double(history.count)
        let latencies = history.compactMap { $0.latencyMs }.map(Double.init)
        var cv = 0.0
        if latencies.count >= 2 {
            let mean = latencies.reduce(0, +) / Double(latencies.count)
            if mean > 0 {
                let variance = latencies.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                    / Double(latencies.count)
                cv = variance.squareRoot() / mean
            }
        }
        return 100 * successRate * max(0, 1 - 0.5 * cv)
    }

    static func bandwidthScore(_ peakDownBps: Int64?) -> Double {
        guard let peakDownBps else { return neutralBandwidth }
        let mbps = Double(peakDownBps) / Double(1 << 20)
        return piecewise(mbps, anchors: [(0, 0), (0.5, 30), (2, 60), (8, 100)])
    }

    static func costScore(_ rate: Double) -> Double {
        piecewise(rate, anchors: [(0.5, 100), (1, 80), (2, 40), (5, 10)])
    }

    /// 锚点分段线性：x 轴升序锚点，两端夹紧，中间线性插值。
    static func piecewise(_ x: Double, anchors: [(x: Double, y: Double)]) -> Double {
        guard let first = anchors.first, let last = anchors.last else { return 0 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        for i in 1..<anchors.count where x <= anchors[i].x {
            let (x0, y0) = anchors[i - 1]
            let (x1, y1) = anchors[i]
            return y0 + (x - x0) / (x1 - x0) * (y1 - y0)
        }
        return last.y
    }
}
