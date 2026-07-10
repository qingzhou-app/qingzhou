import Foundation

/// 离线回放对比 harness —— 量化「我们的多维打分择优」相对「竞品式纯 Ping 择优」的收益。
///
/// 用同一份每节点的测量历史序列，让两个策略逐轮各自选节点，产出结构化对比 `ReplayReport`
/// （提速% / 省流量% / 少切换次数 + 每轮明细 + Markdown 报告）。竞品对比宣发数字的来源。
///
/// **两个策略**：
/// - 策略 A「纯 Ping 最低」（竞品基线，Clash `url-test` 式）：每轮选**直连延迟最低**者，
///   无黏性、说切就切；某轮该节点测不通就退回上轮选择（竞品行为：保持上次可用出口）。
/// - 策略 B「多维打分」：**直接调 `NodeScorer`**（不重写打分逻辑 —— 回放结论才和线上一致）
///   选总分最高者，叠加**分数黏性**（挑战者领先 ≥`scoreMargin` 分且连续 `scoreStreakRounds`
///   轮才换）与倍率成本维。黏性参数镜像 `AppState.autoSwitchScoreMargin` / `…StreakRounds`。
///
/// **与线上流程的刻意偏离**：回放**不叠加** `autoSwitchWorthRestart`（线上的「隧道重启值不值」
/// ms 幅度闸）。那道闸用**原始直连 ms** 判断，会拦掉「ms 更高但更稳/更省」的切换 —— 正是
/// 本 harness 要量化的多维收益。它是「运行中隧道重启有断流代价」的现网工程约束，离线回放没有
/// 隧道，纳入它反而遮蔽被测收益。故策略 B = 「打分最高 + 分数黏性」，不含 ms 幅度闸。
public enum SelectionReplay {

    // MARK: - 输入

    /// 参与回放的一个节点的静态元数据（打分需要的、每轮不变的部分）。
    public struct NodeSpec: Sendable, Equatable {
        public var id: String
        public var name: String
        public var rate: Double
        public var peakDownBps: Int64?

        public init(id: String, name: String, rate: Double = 1.0, peakDownBps: Int64? = nil) {
            self.id = id
            self.name = name
            self.rate = rate
            self.peakDownBps = peakDownBps
        }
    }

    /// 一个节点在某一轮的测量：直连延迟 / 经代理延迟 / burst 丢包率。
    /// `directMs == nil` = 该轮直连测速失败（节点该轮不可选，但样本仍落史算稳定性）。
    public struct Observation: Sendable, Equatable {
        public var directMs: Int?
        public var proxiedMs: Int?
        public var lossFraction: Double?

        public init(directMs: Int?, proxiedMs: Int? = nil, lossFraction: Double? = nil) {
            self.directMs = directMs
            self.proxiedMs = proxiedMs
            self.lossFraction = lossFraction
        }
    }

    /// 一轮 = 一个时间点上各节点的测量（key = `NodeSpec.id`）。
    public struct Round: Sendable, Equatable {
        public var at: Date
        public var observations: [String: Observation]

        public init(at: Date, observations: [String: Observation]) {
            self.at = at
            self.observations = observations
        }
    }

    /// 回放配置。默认值镜像现网常量，测试可注入覆盖。
    public struct Config: Sendable {
        /// 是否让成本维参与打分（映射现网 `settings.preferLowerRate`；false = 倍率完全不参与）。
        public var preferLowerRate: Bool = true
        /// 打分档位（映射现网三档预设 `settings.scoringProfile`）。
        public var profile: ScoringProfile = .balanced
        /// 分数黏性门槛：挑战者总分须领先在位者 ≥ 该值（镜像 `AppState.autoSwitchScoreMargin`）。
        public var scoreMargin: Double = 8
        /// 分数黏性持续轮数：领先须连续成立的轮数（镜像 `AppState.autoSwitchScoreStreakRounds`）。
        public var scoreStreakRounds: Int = 2
        /// 预热轮数：前 N 轮只喂测量历史（消解稳定性维冷启动的中性分），不计入统计。
        public var warmupRounds: Int = 0
        /// 每轮延迟权重（域名画像加权的接口留口子；P2 落地后按轮内域名分布计算）。
        /// 只作用于**加权均值**，中位数与切换/流量统计不受影响。nil = 等权。
        /// 索引对齐**统计轮**（去掉预热后的顺序），不足按 1.0 补。
        public var roundLatencyWeights: [Double]?
        /// 所选节点整轮测不通时计入延迟的罚值（毫秒）。
        public var outagePenaltyMs: Double = 1000
        /// 单位流量：所选节点倍率 × 该值 = 该轮流量成本代理（等价「每轮固定用量」假设）。
        public var unitTrafficPerRound: Double = 1

        public init() {}
    }

    // MARK: - 输出

    /// 单个策略的汇总指标（只统计非预热轮）。
    public struct StrategyResult: Sendable, Equatable {
        /// 有效延迟均值（毫秒，可按 `roundLatencyWeights` 加权）。
        public var meanEffectiveMs: Double
        /// 有效延迟中位数（毫秒，不加权）。
        public var medianEffectiveMs: Double
        /// 累积流量成本（Σ 所选节点倍率 × 单位流量）。
        public var trafficCostUnits: Double
        /// 切换次数（相邻统计轮所选节点变化次数）。
        public var switchCount: Int
        /// 高丢包轮次（所选节点该轮 0<丢包率<1）。
        public var lossyRoundCount: Int
        /// 断流轮次（所选节点该轮直连/经代理全测不通）。
        public var outageRoundCount: Int
        /// 计入统计的轮数。
        public var statsRoundCount: Int
    }

    /// 每轮明细（便于 debug / 明细表）。
    public struct RoundDetail: Sendable, Equatable {
        public var index: Int
        public var at: Date
        public var countedInStats: Bool
        public var pingChoice: String?
        public var pingChoiceName: String?
        public var pingEffectiveMs: Double?
        public var scoringChoice: String?
        public var scoringChoiceName: String?
        public var scoringEffectiveMs: Double?
        public var scoringChoiceScore: Double?
        /// 本轮被分数黏性拦下（领先够但连续轮数没攒满）的挑战者 id —— nil = 未拦或直接放行。
        public var scoringHeldChallenger: String?
        /// 被拦挑战者的展示名 —— 对外渲染一律用名字：id 是身份指纹，可能内嵌凭据。
        public var scoringHeldChallengerName: String?
        /// 两策略选择不同时的归因载荷；同选 / 一方无选择 → nil。
        public var divergence: Divergence?
    }

    /// 分歧轮的归因载荷：双方选择在**打分视角**下的完整分量 —— 报告层据此回答
    /// 「哪个维度改判了选择」（丢包救了谁 / 经代理改判了谁 / 倍率压了谁），不用重放打分。
    public struct Divergence: Sendable, Equatable {
        /// 纯 Ping 所选节点的打分分量。
        public var pingChoiceScore: NodeScorer.Score
        /// 多维打分所选节点的打分分量。
        public var scoringChoiceScore: NodeScorer.Score

        public init(pingChoiceScore: NodeScorer.Score, scoringChoiceScore: NodeScorer.Score) {
            self.pingChoiceScore = pingChoiceScore
            self.scoringChoiceScore = scoringChoiceScore
        }

        public enum Dimension: String, Sendable, CaseIterable {
            case latency, stability, bandwidth, cost
        }

        /// 该维加权分差（打分选择 − Ping 选择）；正 = 该维在把打分选择推上去。
        public func weightedGap(_ d: Dimension) -> Double {
            switch d {
            case .latency:   return scoringChoiceScore.latency.weighted - pingChoiceScore.latency.weighted
            case .stability: return scoringChoiceScore.stability.weighted - pingChoiceScore.stability.weighted
            case .bandwidth: return scoringChoiceScore.bandwidth.weighted - pingChoiceScore.bandwidth.weighted
            case .cost:      return scoringChoiceScore.cost.weighted - pingChoiceScore.cost.weighted
            }
        }

        /// 打分选择领先幅度最大的维度（主要归因）。四维全不占优 → nil ——
        /// 典型场景：黏性把总分已落后的在位者留下了（分歧不来自打分而来自黏性）。
        public var dominantDimension: Dimension? {
            guard let best = Dimension.allCases.max(by: { weightedGap($0) < weightedGap($1) }),
                  weightedGap(best) > 0 else { return nil }
            return best
        }
    }

    public struct ReplayReport: Sendable, Equatable {
        public var ping: StrategyResult
        public var scoring: StrategyResult
        public var rounds: [RoundDetail]
        public var warmupRounds: Int

        /// 提速%：(纯 Ping 均值 − 打分均值) / 纯 Ping 均值 × 100。正 = 打分更快。
        public var speedupPercent: Double {
            guard ping.meanEffectiveMs > 0 else { return 0 }
            return (ping.meanEffectiveMs - scoring.meanEffectiveMs) / ping.meanEffectiveMs * 100
        }
        /// 省流量%：(纯 Ping 流量 − 打分流量) / 纯 Ping 流量 × 100。正 = 打分更省。
        public var trafficSavingPercent: Double {
            guard ping.trafficCostUnits > 0 else { return 0 }
            return (ping.trafficCostUnits - scoring.trafficCostUnits) / ping.trafficCostUnits * 100
        }
        /// 少切换次数：纯 Ping 切换 − 打分切换。正 = 打分更少无谓切换。
        public var switchReduction: Int { ping.switchCount - scoring.switchCount }
    }

    // MARK: - 从 NodeMetricsHistory 构造回放输入

    /// 把每节点的测量历史聚类成「轮」—— 同一轮内各节点的样本时间相近（≤ `window`，
    /// 默认沿用 `NodeMetricsHistory.sameRoundWindow`），一次全量测速产生一轮。
    /// `Round.at` = 该簇最早样本时间；每节点在一簇里至多一条：直连/丢包取簇内最早的一条，
    /// `proxiedMs` 取簇内**首个非 nil**（真实调度一拍常有两遍全量 pass，经代理精选由
    /// `recordProxied` 并入**后一遍**的样本 —— 只取最早会把经代理数据整批丢掉）。
    public static func rounds(
        from history: NodeMetricsHistory,
        window: TimeInterval = NodeMetricsHistory.sameRoundWindow
    ) -> [Round] {
        var flat: [(fp: String, sample: NodeMetricSample)] = []
        for (fp, ring) in history.samples {
            for s in ring { flat.append((fp, s)) }
        }
        flat.sort { $0.sample.at < $1.sample.at }

        var result: [Round] = []
        var clusterStart: Date?
        var current: [String: Observation] = [:]
        func flush() {
            if let start = clusterStart, !current.isEmpty {
                result.append(Round(at: start, observations: current))
            }
            current = [:]
            clusterStart = nil
        }
        for (fp, s) in flat {
            if let start = clusterStart, s.at.timeIntervalSince(start) > window {
                flush()
            }
            if clusterStart == nil { clusterStart = s.at }
            // 同一簇里该节点已有样本 → 直连/丢包保留最早一条；proxiedMs 补首个非 nil
            if var existing = current[fp] {
                if existing.proxiedMs == nil, let p = s.proxiedMs {
                    existing.proxiedMs = p
                    current[fp] = existing
                }
            } else {
                current[fp] = Observation(directMs: s.latencyMs, proxiedMs: s.proxiedMs, lossFraction: s.lossFraction)
            }
        }
        flush()
        return result
    }

    // MARK: - 回放主流程

    public static func replay(
        nodes: [NodeSpec],
        rounds: [Round],
        config: Config = Config()
    ) -> ReplayReport {
        let weights = NodeScorer.weights(for: config.profile)
        var history = NodeMetricsHistory()
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

        // 选择状态
        var pingCurrent: String?
        var pingPrev: String?
        var scoringCurrent: String?
        var scoringPrev: String?
        // 每节点最近一次经代理实测（值 + 测量时间）—— 镜像线上 node.lastProxiedLatencyMs：
        // 打分轮轮携带，新鲜与否交给 NodeScorer 的 24h 门槛（回放只如实传时间戳）。
        var lastProxied: [String: (ms: Int, at: Date)] = [:]
        // 分数黏性连续状态
        var streakChallenger: String?
        var streakIncumbent: String?
        var streakRounds = 0
        func resetStreak() { streakChallenger = nil; streakIncumbent = nil; streakRounds = 0 }

        // 统计累加器
        var details: [RoundDetail] = []
        var pingEff: [(ms: Double, weight: Double)] = []
        var scoreEff: [(ms: Double, weight: Double)] = []
        var pingTraffic = 0.0, scoreTraffic = 0.0
        var pingSwitches = 0, scoreSwitches = 0
        var pingLossy = 0, pingOutage = 0
        var scoreLossy = 0, scoreOutage = 0
        var statsIndex = 0

        func scoreOf(_ spec: NodeSpec, _ round: Round) -> NodeScorer.Score {
            let ob = round.observations[spec.id]
            // 携带最近一次经代理实测（本轮实测已在步骤 1 回填进 lastProxied，时间 = 本轮
            // → 门槛内必然新鲜）；陈旧值由 NodeScorer 的 24h 新鲜度门槛挡掉。
            let carried = lastProxied[spec.id]
            return NodeScorer.score(
                NodeScorer.Input(
                    directLatencyMs: ob?.directMs,
                    proxiedLatencyMs: carried?.ms,
                    proxiedTestedAt: carried?.at,
                    history: history.samples(for: spec.id),
                    peakDownBps: spec.peakDownBps,
                    rate: spec.rate
                ),
                preferLowerRate: config.preferLowerRate,
                weights: weights,
                now: round.at
            )
        }

        /// 所选节点该轮的有效延迟：优先经代理实测（真实端到端），退直连；按丢包率放大
        /// （base/(1−loss)，模型化重传/重试对真实体感的拖累）；整轮不可用 → 罚值。
        func effective(_ id: String?, _ round: Round) -> (ms: Double, lossy: Bool, outage: Bool) {
            guard let id, let ob = round.observations[id] else {
                return (config.outagePenaltyMs, false, true)
            }
            let loss = min(max(ob.lossFraction ?? 0, 0), 1)
            guard let base = ob.proxiedMs ?? ob.directMs, loss < 1 else {
                return (config.outagePenaltyMs, false, true)
            }
            if loss > 0 { return (Double(base) / (1 - loss), true, false) }
            return (Double(base), false, false)
        }

        for (index, round) in rounds.enumerated() {
            // 1. 先把本轮所有观测落史（镜像线上：测速回调先记样本，再挑最优）。
            for spec in nodes {
                guard let ob = round.observations[spec.id] else { continue }
                history.recordDirect(fingerprint: spec.id, latencyMs: ob.directMs,
                                     lossFraction: ob.lossFraction, at: round.at)
                if let p = ob.proxiedMs {
                    history.recordProxied(fingerprint: spec.id, proxiedMs: p, at: round.at)
                    lastProxied[spec.id] = (p, round.at)
                }
            }

            let viable = nodes.filter { round.observations[$0.id]?.directMs != nil }

            // 2. 策略 A：直连最低（无黏性）。无可选节点 → 保持上轮选择。
            let pingBest = viable.min { a, b in
                let la = a.directMs(round), lb = b.directMs(round)
                if la != lb { return la < lb }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
                    || (a.name == b.name && a.id < b.id)
            }
            let pingChoice = pingBest?.id ?? pingCurrent

            // 3. 策略 B：打分最高 + 分数黏性。
            let scoredViable = viable.map { (spec: $0, score: scoreOf($0, round).total) }
            let scoringBest = scoredViable.min { a, b in
                if a.score != b.score { return a.score > b.score }
                let la = a.spec.directMs(round), lb = b.spec.directMs(round)
                if la != lb { return la < lb }
                return a.spec.name.localizedStandardCompare(b.spec.name) == .orderedAscending
                    || (a.spec.name == b.spec.name && a.spec.id < b.spec.id)
            }
            var scoringChoice = scoringCurrent
            var heldChallenger: String?
            if let best = scoringBest {
                if let inc = scoringCurrent, inc != best.spec.id {
                    let incumbentViable = round.observations[inc]?.directMs != nil
                    if !incumbentViable {
                        scoringChoice = best.spec.id; resetStreak()          // 在位者本轮已坏 → 立即切
                    } else {
                        let incScore = byId[inc].map { scoreOf($0, round).total } ?? -.infinity
                        if best.score - incScore >= config.scoreMargin {
                            if streakChallenger == best.spec.id && streakIncumbent == inc {
                                streakRounds += 1
                            } else {
                                streakChallenger = best.spec.id; streakIncumbent = inc; streakRounds = 1
                            }
                            if streakRounds >= config.scoreStreakRounds {
                                scoringChoice = best.spec.id; resetStreak()  // 连续攒够 → 切
                            } else {
                                heldChallenger = best.spec.id                // 领先够但轮数没满 → 拦
                            }
                        } else {
                            resetStreak()                                    // 领先不够 → 保持
                        }
                    }
                } else {
                    scoringChoice = best.spec.id; resetStreak()              // 首选 / 最优即在位者
                }
            }

            // 4. 更新在位状态 + 有效延迟。
            pingCurrent = pingChoice
            scoringCurrent = scoringChoice
            let pe = effective(pingChoice, round)
            let se = effective(scoringChoice, round)
            let scoringChoiceScore = scoringChoice.flatMap { id in byId[id].map { scoreOf($0, round).total } }
            let divergence: Divergence? = {
                guard let p = pingChoice, let s = scoringChoice, p != s,
                      let pSpec = byId[p], let sSpec = byId[s] else { return nil }
                return Divergence(pingChoiceScore: scoreOf(pSpec, round),
                                  scoringChoiceScore: scoreOf(sSpec, round))
            }()

            let counted = index >= config.warmupRounds
            if counted {
                let w = config.roundLatencyWeights.flatMap { statsIndex < $0.count ? $0[statsIndex] : nil } ?? 1.0
                pingEff.append((pe.ms, w))
                scoreEff.append((se.ms, w))
                pingTraffic += (pingChoice.flatMap { byId[$0]?.rate } ?? 0) * config.unitTrafficPerRound
                scoreTraffic += (scoringChoice.flatMap { byId[$0]?.rate } ?? 0) * config.unitTrafficPerRound
                if pe.lossy { pingLossy += 1 }
                if pe.outage { pingOutage += 1 }
                if se.lossy { scoreLossy += 1 }
                if se.outage { scoreOutage += 1 }
                if index > 0, pingChoice != pingPrev { pingSwitches += 1 }
                if index > 0, scoringChoice != scoringPrev { scoreSwitches += 1 }
                statsIndex += 1
            }
            pingPrev = pingChoice
            scoringPrev = scoringChoice

            details.append(RoundDetail(
                index: index, at: round.at, countedInStats: counted,
                pingChoice: pingChoice, pingChoiceName: pingChoice.flatMap { byId[$0]?.name },
                pingEffectiveMs: pe.ms,
                scoringChoice: scoringChoice, scoringChoiceName: scoringChoice.flatMap { byId[$0]?.name },
                scoringEffectiveMs: se.ms, scoringChoiceScore: scoringChoiceScore,
                scoringHeldChallenger: heldChallenger,
                scoringHeldChallengerName: heldChallenger.flatMap { byId[$0]?.name },
                divergence: divergence
            ))
        }

        let ping = StrategyResult(
            meanEffectiveMs: weightedMean(pingEff), medianEffectiveMs: median(pingEff.map(\.ms)),
            trafficCostUnits: pingTraffic, switchCount: pingSwitches,
            lossyRoundCount: pingLossy, outageRoundCount: pingOutage, statsRoundCount: statsIndex)
        let scoring = StrategyResult(
            meanEffectiveMs: weightedMean(scoreEff), medianEffectiveMs: median(scoreEff.map(\.ms)),
            trafficCostUnits: scoreTraffic, switchCount: scoreSwitches,
            lossyRoundCount: scoreLossy, outageRoundCount: scoreOutage, statsRoundCount: statsIndex)
        return ReplayReport(ping: ping, scoring: scoring, rounds: details, warmupRounds: config.warmupRounds)
    }

    // MARK: - 统计小工具

    static func weightedMean(_ xs: [(ms: Double, weight: Double)]) -> Double {
        let wsum = xs.reduce(0) { $0 + $1.weight }
        guard wsum > 0 else { return 0 }
        return xs.reduce(0) { $0 + $1.ms * $1.weight } / wsum
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}

private extension SelectionReplay.NodeSpec {
    func directMs(_ round: SelectionReplay.Round) -> Int {
        round.observations[id]?.directMs ?? .max
    }
}

// MARK: - Markdown 报告

public extension SelectionReplay.ReplayReport {

    /// 把对比结果渲染成人类可读的 Markdown：三句话结论 + 对比表 + 每轮明细 + 诚实脚注。
    func renderMarkdown() -> String {
        func f1(_ x: Double) -> String { String(format: "%.1f", x) }
        func f2(_ x: Double) -> String { String(format: "%.2f", x) }

        let speedSeg = speedupPercent >= 0
            ? "提速 \(f1(speedupPercent))%"
            : "有效延迟 +\(f1(-speedupPercent))%"
        let saveSeg = trafficSavingPercent >= 0
            ? "省流量 \(f1(trafficSavingPercent))%"
            : "多耗流量 +\(f1(-trafficSavingPercent))%"
        let switchSeg = switchReduction >= 0
            ? "少切换 \(switchReduction) 次"
            : "多切换 \(-switchReduction) 次"
        let headline = "\(speedSeg)、\(saveSeg)、\(switchSeg)"

        var md = ""
        md += "# 择优策略离线回放对比\n\n"
        md += "> 三句话结论：**\(headline)**。\n"
        md += "> 对比对象：我们的多维打分择优 vs **仅按 Ping**（直连延迟最低）择优（Clash `url-test` 式）。\n\n"

        md += "## 对比总览\n\n"
        md += "| 指标 | 仅按 Ping（基线） | 多维打分（本策略） | 差异 |\n"
        md += "|---|---|---|---|\n"
        md += "| 有效延迟·均值 | \(f1(ping.meanEffectiveMs)) ms | \(f1(scoring.meanEffectiveMs)) ms | \(speedSeg) |\n"
        md += "| 有效延迟·中位数 | \(f1(ping.medianEffectiveMs)) ms | \(f1(scoring.medianEffectiveMs)) ms | — |\n"
        md += "| 流量成本（倍率×单位） | \(f2(ping.trafficCostUnits)) | \(f2(scoring.trafficCostUnits)) | \(saveSeg) |\n"
        md += "| 切换次数 | \(ping.switchCount) | \(scoring.switchCount) | \(switchSeg) |\n"
        md += "| 高丢包轮次 | \(ping.lossyRoundCount) | \(scoring.lossyRoundCount) | — |\n"
        md += "| 断流轮次 | \(ping.outageRoundCount) | \(scoring.outageRoundCount) | — |\n"
        md += "| 统计轮次 | \(ping.statsRoundCount) | \(scoring.statsRoundCount) | 预热 \(warmupRounds) 轮不计 |\n\n"

        md += "## 每轮明细\n\n"
        md += "| 轮次 | 仅按 Ping 选择 | 有效延迟 | 多维打分选择 | 有效延迟 | 打分 | 备注 |\n"
        md += "|---|---|---|---|---|---|---|\n"
        for d in rounds {
            let tag = d.countedInStats ? "\(d.index)" : "\(d.index)·预热"
            let pn = d.pingChoiceName ?? d.pingChoice ?? "—"
            let sn = d.scoringChoiceName ?? d.scoringChoice ?? "—"
            let pms = d.pingEffectiveMs.map { "\(f1($0)) ms" } ?? "—"
            let sms = d.scoringEffectiveMs.map { "\(f1($0)) ms" } ?? "—"
            let sc = d.scoringChoiceScore.map { f1($0) } ?? "—"
            // 备注只出名字：id 是身份指纹（协议://凭据@host:port），进 Markdown 会泄凭据
            let note = (d.scoringHeldChallengerName ?? d.scoringHeldChallenger)
                .map { "黏性拦下挑战者 \($0)" } ?? ""
            md += "| \(tag) | \(pn) | \(pms) | \(sn) | \(sms) | \(sc) | \(note) |\n"
        }
        md += "\n"

        md += "## 诚实边界\n\n"
        md += "- 本报告基于**样例数据**（合成序列 / 单设备离线回放），**非普适**承诺 —— 实际收益取决于机场质量与个人使用画像。\n"
        md += "- 对比对象是「**仅按 Ping** 择优」策略本身，不指向、不点名任何具体竞品。\n"
        md += "- 「有效延迟」按丢包率放大直连/经代理实测（重传/重试对体感的拖累），非纯握手 RTT。\n"
        return md
    }
}
