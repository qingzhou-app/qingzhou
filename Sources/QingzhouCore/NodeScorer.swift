import Foundation

/// 节点多维打分引擎（纯函数，不做 IO）—— 自动择优的内核。
///
/// `score = Σ w_d × s_d`，每维 s_d ∈ [0,100]，**锚点归一**：分数含义固定
/// （「85 分的延迟」永远指 ~100ms），不随节点池相对漂移，可解释、可跨轮比较 ——
/// 分数黏性（连续 N 轮领先才切换）依赖这一点。
///
/// | 维度 | 权重(均衡档) | 缺数据时 |
/// |---|---|---|
/// | 延迟 | 0.45 | 两者都有且经代理新鲜(≤24h) → 0.7×经代理分+0.3×直连分（各自先锚点归一再混合）；只有经代理 → 全权重；只有直连 → ×1.3 惩罚；全缺 → 0 |
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

        /// 均衡档（默认）：延迟主导、稳定性次之，成本只做轻微修正 —— P1 起沿用的口径。
        public static let balanced = Weights(latency: 0.45, stability: 0.30, bandwidth: 0.15, cost: 0.10)
        /// 速度优先档：延迟提到 0.60（几乎只看快不快）、成本压到 0.05（近乎不管倍率）。
        /// 稳定性/带宽相应让路 —— 追求「此刻最快」的用户接受多烧点流量。
        public static let speed = Weights(latency: 0.60, stability: 0.25, bandwidth: 0.10, cost: 0.05)
        /// 省流量档：成本提到 0.30（倍率进入主决策项，直接压低高倍率节点得分）、延迟降到 0.35。
        /// 稳定性/带宽与速度档持平 —— 省流量不等于要抖动大，稳定性仍保 0.25。
        public static let saver = Weights(latency: 0.35, stability: 0.25, bandwidth: 0.10, cost: 0.30)
    }

    /// 档位 → 权重组映射（三档预设的常量表）。三组都归一（Σ=1），锚点归一 + 归一权重
    /// 保证不同档位的总分仍在同一 0–100 尺度，可跨档解释。UI 只暴露这三档、不给裸滑杆。
    public static func weights(for profile: ScoringProfile) -> Weights {
        switch profile {
        case .speed:    return .speed
        case .balanced: return .balanced
        case .saver:    return .saver
        }
    }

    /// 打分输入 —— 调用方从 Node / NodeMetricsHistory 拼装，引擎本身不认识 Node
    ///（保持纯函数，单测不用构造完整节点）。
    public struct Input: Sendable {
        public var directLatencyMs: Int?
        public var proxiedLatencyMs: Int?
        /// 经代理值的测量时间 —— 新鲜度门槛用（距 now 超过 `proxiedFreshnessWindow` 的
        /// 经代理值不参与延迟维）。nil = 当轮实测（经代理精选路径），视为新鲜。
        public var proxiedTestedAt: Date?
        public var history: [NodeMetricSample]
        public var peakDownBps: Int64?
        public var rate: Double

        public init(
            directLatencyMs: Int? = nil,
            proxiedLatencyMs: Int? = nil,
            proxiedTestedAt: Date? = nil,
            history: [NodeMetricSample] = [],
            peakDownBps: Int64? = nil,
            rate: Double = 1.0
        ) {
            self.directLatencyMs = directLatencyMs
            self.proxiedLatencyMs = proxiedLatencyMs
            self.proxiedTestedAt = proxiedTestedAt
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
    /// 与经代理实测值同台比较时要抬一手。混合与直连独占两条路径口径统一（都 ×1.3）。
    public static let directLatencyPenalty = 1.3
    /// 延迟维混合权重：两者都有且经代理新鲜时，经代理分占 0.7、直连分占 0.3。
    /// 经代理是真实路径权重大头；直连保留三成 —— 它每轮都测、更新鲜，能拽住
    /// 「上次经代理测完线路已变差」的偏差。
    public static let proxiedBlendWeight = 0.7
    /// 经代理值的新鲜度门槛：`proxiedTestedAt` 距今超过该时长的经代理值不参与延迟维
    /// —— 陈旧的经代理数字比新鲜直连更误导（线路质量以小时尺度漂移）。
    public static let proxiedFreshnessWindow: TimeInterval = 24 * 60 * 60
    /// 稳定性中性分（样本不足时不奖不罚）。
    public static let neutralStability: Double = 70
    /// 带宽中性分（无被动观测时不奖不罚）。
    public static let neutralBandwidth: Double = 60
    /// 稳定性维度的最小样本数，不足按中性分。
    public static let minStabilitySamples = 3

    /// 给一个节点打分。`preferLowerRate == false` 时成本维权重置 0、按比例摊给其余维度
    /// —— 保留「延迟接近时优先低倍率」开关的既有语义：关掉 = 倍率完全不参与决策。
    /// `now` 只用于经代理值的新鲜度判定（单测注入固定时刻）。
    public static func score(
        _ input: Input,
        preferLowerRate: Bool = true,
        weights: Weights = .balanced,
        now: Date = Date()
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
        let latency = Component(score: latencyScore(input, now: now), weight: w.latency)
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

    /// 延迟维：经代理 / 直连各自先过锚点归一，再按 0.7/0.3 混合 —— 不混原始 ms，
    /// 两者量纲锚点不同（直连要 ×1.3 抬升后才可比）。经代理值有新鲜度门槛：
    /// `proxiedTestedAt` 距 now 超过 24h 的整体出局（含「只有陈旧经代理」的情况 → 0），
    /// nil 时间戳 = 当轮实测（经代理精选路径），视为新鲜。
    static func latencyScore(_ input: Input, now: Date = Date()) -> Double {
        let proxiedScore: Double? = input.proxiedLatencyMs.flatMap { proxied in
            if let at = input.proxiedTestedAt, now.timeIntervalSince(at) > proxiedFreshnessWindow {
                return nil                                         // 陈旧经代理值不参与
            }
            return piecewise(Double(proxied), anchors: latencyAnchors)
        }
        let directScore: Double? = input.directLatencyMs.map {
            piecewise(Double($0) * directLatencyPenalty, anchors: latencyAnchors)
        }
        switch (proxiedScore, directScore) {
        case let (proxied?, direct?):
            return proxiedBlendWeight * proxied + (1 - proxiedBlendWeight) * direct
        case let (proxied?, nil):
            return proxied                                         // 只有经代理 → 全权重
        case let (nil, direct?):
            return direct                                          // 只有直连 → ×1.3 惩罚（现状保留）
        case (nil, nil):
            return 0                                               // 全无数据 = 不可用
        }
    }

    static let latencyAnchors: [(x: Double, y: Double)] = [(50, 100), (100, 85), (200, 60), (400, 30), (800, 0)]

    /// `100 × (1 − 平均丢包率) × (1 − 0.5×延迟变异系数)`，抖动项下限 0（极端抖动不出负分）。
    /// 「成功率」细化为丢包率：burst 探测（每轮 3 次握手）的样本带 `lossFraction`，按值
    /// 平均 —— 「3 次成 2 次」的半坏节点不再与全成的同分；无 lossFraction 的老样本按旧
    /// 语义折算：成功（直连或经代理任一测通，手动经代理测速的独立样本不能算成直连失败）
    /// = 丢包 0，整轮失败 = 丢包 1。
    /// 变异系数只用直连延迟（burst 中位数）算 —— 直连每轮都测、口径统一，
    /// 混入经代理值会比错尺度。
    static func stabilityScore(history: [NodeMetricSample]) -> Double {
        guard history.count >= minStabilitySamples else { return neutralStability }
        let totalLoss = history.reduce(0.0) { acc, sample in
            if let loss = sample.lossFraction { return acc + min(max(loss, 0), 1) }
            return acc + ((sample.latencyMs != nil || sample.proxiedMs != nil) ? 0 : 1)
        }
        let avgLoss = totalLoss / Double(history.count)
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
        return 100 * (1 - avgLoss) * max(0, 1 - 0.5 * cv)
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
