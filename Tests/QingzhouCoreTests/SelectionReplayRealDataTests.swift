import XCTest
@testable import QingzhouCore

/// D.15 真实数据回放 runner —— 不是常规单测：从环境变量取用户真实测量历史
/// （node-metrics.json）与节点清单（state.json），跑「多维打分 vs 纯延迟」离线回放，
/// 把**脱敏后的**结构化结果写到指定路径。未设环境变量时整体跳过（CI / 常规 swift test 无感）。
///
/// 用法：
///   QZ_REPLAY_DATA=<node-metrics.json> QZ_REPLAY_STATE=<state.json> \
///   QZ_REPLAY_OUT=<输出md路径> swift test --filter SelectionReplayRealDataTests
///
/// ⚠️ 安全：节点 id（身份指纹）形如 `协议://凭据@host:port`，**内嵌凭据** ——
/// 本文件的一切输出只用展示名 / host，绝不落 id。数据文件本身不入 git。
final class SelectionReplayRealDataTests: XCTestCase {

    // MARK: - 输入解码

    /// state.json 的最小切片：只取回放需要的字段，对 Settings 全量结构不敏感。
    private struct StateFile: Decodable {
        var nodes: [Node]
        var settings: SettingsSlice

        struct SettingsSlice: Decodable {
            var preferLowerRate: Bool?
            var scoringProfile: ScoringProfile?
            var excludedRegions: Set<String>?
            var preferredRegion: String?
        }
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, at path: String) throws -> T {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601   // Persistence 落盘口径
        return try decoder.decode(type, from: data)
    }

    // MARK: - 工具

    private static let tz = TimeZone(identifier: "Asia/Shanghai")!  // 报告统一 UTC+8

    private func local(_ d: Date, seconds: Bool = false) -> String {
        let f = DateFormatter()
        f.timeZone = Self.tz
        f.dateFormat = seconds ? "MM-dd HH:mm:ss" : "MM-dd HH:mm"
        return f.string(from: d)
    }

    private func f1(_ x: Double) -> String { String(format: "%.1f", x) }
    private func f2(_ x: Double) -> String { String(format: "%.2f", x) }

    private func stripProxied(_ rounds: [SelectionReplay.Round]) -> [SelectionReplay.Round] {
        rounds.map { r in
            var obs = r.observations
            for (k, o) in obs {
                var o = o
                o.proxiedMs = nil
                obs[k] = o
            }
            return SelectionReplay.Round(at: r.at, observations: obs)
        }
    }

    private func summaryRow(_ label: String, _ r: SelectionReplay.ReplayReport) -> String {
        "| \(label) | \(f1(r.ping.meanEffectiveMs)) / \(f1(r.scoring.meanEffectiveMs)) "
        + "| \(f1(r.ping.medianEffectiveMs)) / \(f1(r.scoring.medianEffectiveMs)) "
        + "| \(f1(r.speedupPercent))% | \(f2(r.ping.trafficCostUnits)) / \(f2(r.scoring.trafficCostUnits)) "
        + "| \(f1(r.trafficSavingPercent))% | \(r.ping.switchCount) / \(r.scoring.switchCount) "
        + "| \(r.ping.lossyRoundCount) / \(r.scoring.lossyRoundCount) "
        + "| \(r.ping.outageRoundCount) / \(r.scoring.outageRoundCount) |\n"
    }

    // MARK: - runner

    func testReplayRealMetricsAndDumpReport() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dataPath = env["QZ_REPLAY_DATA"], let statePath = env["QZ_REPLAY_STATE"] else {
            throw XCTSkip("QZ_REPLAY_DATA / QZ_REPLAY_STATE 未设置 —— 真实数据回放只手动触发")
        }
        let outPath = env["QZ_REPLAY_OUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("replay-dump.md").path

        // ---- 输入 ----
        let history = try decodeJSON(NodeMetricsHistory.self, at: dataPath)
        let state = try decodeJSON(StateFile.self, at: statePath)
        XCTAssertFalse(history.isEmpty, "测量历史为空")

        let fingerprints = Set(history.samples.keys)
        let known = state.nodes.filter { fingerprints.contains($0.identityFingerprint) }
        XCTAssertEqual(known.count, fingerprints.count,
                       "有测量历史但 state.json 里找不到的节点：\(fingerprints.count - known.count) 个")

        func spec(_ n: Node) -> SelectionReplay.NodeSpec {
            SelectionReplay.NodeSpec(id: n.identityFingerprint, name: n.name,
                                     rate: n.rateForComparison, peakDownBps: n.observedPeakDownBps)
        }
        let excludedRegions = state.settings.excludedRegions ?? []
        let allSpecs = known.sorted { $0.name < $1.name }.map(spec)
        let mainSpecs = known.filter { !excludedRegions.contains($0.region) && !$0.isExcluded }
            .sorted { $0.name < $1.name }.map(spec)

        let rounds = SelectionReplay.rounds(from: history)
        XCTAssertGreaterThan(rounds.count, 10, "轮数太少，回放没意义")

        // ---- 配置（镜像用户真实设置；黏性参数镜像 AppState 常量）----
        var config = SelectionReplay.Config()
        config.preferLowerRate = state.settings.preferLowerRate ?? true
        config.profile = state.settings.scoringProfile ?? .balanced
        config.warmupRounds = 3   // 稳定性维 ≥3 样本激活，前 3 轮只喂历史

        // ---- 主跑 + 反事实变体 ----
        let main = SelectionReplay.replay(nodes: mainSpecs, rounds: rounds, config: config)
        let noProxied = SelectionReplay.replay(nodes: mainSpecs, rounds: stripProxied(rounds), config: config)
        var costOff = config; costOff.preferLowerRate = false
        let noCost = SelectionReplay.replay(nodes: mainSpecs, rounds: rounds, config: costOff)
        let withHK = SelectionReplay.replay(nodes: allSpecs, rounds: rounds, config: config)
        var noSticky = config; noSticky.scoreMargin = 0; noSticky.scoreStreakRounds = 1
        let noStick = SelectionReplay.replay(nodes: mainSpecs, rounds: rounds, config: noSticky)

        // ---- 数据概况（观测空间 = 簇合并后）----
        var obsTotal = 0, obsDirect = 0, obsProxied = 0, obsLoss = 0
        for r in rounds {
            for (_, o) in r.observations {
                obsTotal += 1
                if o.directMs != nil { obsDirect += 1 }
                if o.proxiedMs != nil { obsProxied += 1 }
                if o.lossFraction != nil { obsLoss += 1 }
            }
        }
        let gaps = zip(rounds.dropFirst(), rounds).map { $0.at.timeIntervalSince($1.at) / 60 }
        let sortedGaps = gaps.sorted()

        // ---- dump ----
        var md = "# D.15 真实数据回放 dump（脱敏）\n\n"
        md += "- 生成：\(local(Date(), seconds: true))（UTC+8）；数据文件不入库，本 dump 无凭据\n"
        md += "- 回放窗口：\(local(rounds.first!.at)) → \(local(rounds.last!.at))（UTC+8），"
        md += "\(rounds.count) 轮；轮间隔 min/median/max = "
        md += "\(f1(sortedGaps.first ?? 0)) / \(f1(sortedGaps[sortedGaps.count / 2])) / \(f1(sortedGaps.last ?? 0)) 分钟\n"
        md += "- 观测覆盖（簇合并后）：\(obsTotal) 条；直连成功 \(obsDirect)（\(f1(Double(obsDirect) / Double(obsTotal) * 100))%）、"
        md += "经代理 \(obsProxied)（\(f1(Double(obsProxied) / Double(obsTotal) * 100))%）、"
        md += "丢包率字段 \(obsLoss)（\(f1(Double(obsLoss) / Double(obsTotal) * 100))%）\n"
        md += "- 候选池：全部 \(allSpecs.count) 节点；主跑剔除地区 \(excludedRegions.sorted()) 后 \(mainSpecs.count) 节点\n"
        md += "- 配置：profile=\(config.profile.rawValue)、preferLowerRate=\(config.preferLowerRate)、"
        md += "margin=\(config.scoreMargin)、streak=\(config.scoreStreakRounds)、warmup=\(config.warmupRounds)\n\n"

        md += "## 节点清单（名字 | 倍率 | 峰值带宽 | 直连成功/轮数 | 经代理样本数）\n\n"
        for s in allSpecs {
            var ok = 0, px = 0, n = 0
            for r in rounds {
                guard let o = r.observations[s.id] else { continue }
                n += 1
                if o.directMs != nil { ok += 1 }
                if o.proxiedMs != nil { px += 1 }
            }
            let bw = s.peakDownBps.map { f1(Double($0) / 1_048_576) + " MB/s" } ?? "—"
            let inMain = mainSpecs.contains { $0.id == s.id } ? "" : "（主跑剔除）"
            md += "- \(s.name)\(inMain) | \(s.rate)x | \(bw) | \(ok)/\(n) | 经代理 \(px)\n"
        }
        md += "\n"

        md += "## 变体总表（均为 纯Ping / 多维打分）\n\n"
        md += "| 变体 | 均值ms | 中位ms | 提速% | 流量成本 | 省流% | 切换 | 高丢包轮 | 断流轮 |\n"
        md += "|---|---|---|---|---|---|---|---|---|\n"
        md += summaryRow("主跑（镜像真实设置）", main)
        md += summaryRow("V1 无经代理", noProxied)
        md += summaryRow("V2 成本维关闭", noCost)
        md += summaryRow("V3 含被排除地区", withHK)
        md += summaryRow("V4 无黏性", noStick)
        md += "\n"

        // 反事实逐轮 diff：经代理 / 成本维分别改判了哪些轮
        func choiceDiff(_ a: SelectionReplay.ReplayReport, _ b: SelectionReplay.ReplayReport,
                        label: String) -> String {
            var out = ""
            var count = 0
            for (da, db) in zip(a.rounds, b.rounds) where da.scoringChoice != db.scoringChoice {
                count += 1
                out += "  - r\(da.index)（\(local(da.at))）：\(da.scoringChoiceName ?? "—") ↔ \(db.scoringChoiceName ?? "—")\n"
            }
            return "- \(label)：改判 \(count) 轮\n" + out
        }
        md += "## 反事实归因（主跑 vs 变体，逐轮打分选择 diff）\n\n"
        md += choiceDiff(main, noProxied, label: "经代理延迟（主跑 ↔ V1 无经代理）")
        md += choiceDiff(main, noCost, label: "倍率成本维（主跑 ↔ V2 成本关）")
        md += choiceDiff(main, noStick, label: "分数黏性（主跑 ↔ V4 无黏性）")
        md += "\n"

        // 黏性台账
        md += "## 黏性台账（主跑）\n\n"
        var held = 0, transient = 0
        for d in main.rounds where d.scoringHeldChallenger != nil {
            held += 1
            let next = main.rounds.indices.contains(d.index + 1) ? main.rounds[d.index + 1] : nil
            let realized = next?.scoringChoice == d.scoringHeldChallenger
            if !realized { transient += 1 }
            md += "- r\(d.index)（\(local(d.at))）拦下 \(d.scoringHeldChallengerName ?? "?")，"
            md += realized ? "次轮兑现切换\n" : "挑战者次轮已非首选（转瞬即逝，拦对了）\n"
        }
        md += "- 合计拦截 \(held) 次，其中 \(transient) 次挑战者转瞬即逝\n"
        md += "- V4（无黏性）打分切换 \(noStick.scoring.switchCount) 次 vs 主跑 \(main.scoring.switchCount) 次"
        md += " → 黏性净省 \(noStick.scoring.switchCount - main.scoring.switchCount) 次切换\n\n"

        // 分歧明细（主跑）
        md += "## 两策略分歧明细（主跑，逐轮归因）\n\n"
        var divCount = 0
        var dimTally: [SelectionReplay.Divergence.Dimension: Int] = [:]
        var stickyTally = 0
        for d in main.rounds {
            guard let dv = d.divergence else { continue }
            divCount += 1
            let dom = dv.dominantDimension
            if let dom { dimTally[dom, default: 0] += 1 } else { stickyTally += 1 }
            let pOb = rounds[d.index].observations[d.pingChoice ?? ""]
            let sOb = rounds[d.index].observations[d.scoringChoice ?? ""]
            func obDesc(_ o: SelectionReplay.Observation?) -> String {
                guard let o else { return "无观测" }
                var parts: [String] = []
                parts.append(o.directMs.map { "直连\($0)ms" } ?? "直连失败")
                if let p = o.proxiedMs { parts.append("经代理\(p)ms") }
                if let l = o.lossFraction, l > 0 { parts.append("丢包\(f1(l * 100))%") }
                return parts.joined(separator: " ")
            }
            md += "- r\(d.index)（\(local(d.at))）Ping 选 **\(d.pingChoiceName ?? "—")**（\(obDesc(pOb))，"
            md += "总分 \(f1(dv.pingChoiceScore.total))）；打分选 **\(d.scoringChoiceName ?? "—")**"
            md += "（\(obDesc(sOb))，总分 \(f1(dv.scoringChoiceScore.total))）。"
            md += "加权分差 延迟\(f1(dv.weightedGap(.latency))) 稳定\(f1(dv.weightedGap(.stability))) "
            md += "带宽\(f1(dv.weightedGap(.bandwidth))) 成本\(f1(dv.weightedGap(.cost)))"
            md += " → 主因：\(dom.map { $0.rawValue } ?? "黏性/平局保持")\n"
        }
        md += "- 分歧轮合计 \(divCount)/\(main.rounds.count)；主因分布："
        md += "延迟 \(dimTally[.latency, default: 0])、稳定性 \(dimTally[.stability, default: 0])、"
        md += "带宽 \(dimTally[.bandwidth, default: 0])、成本 \(dimTally[.cost, default: 0])、"
        md += "黏性保持 \(stickyTally)\n\n"

        // 主跑逐轮时间线
        md += "## 主跑逐轮时间线\n\n"
        md += "| 轮 | 本地时间 | Ping 选择 | 有效ms | 打分选择 | 有效ms | 总分 | 备注 |\n"
        md += "|---|---|---|---|---|---|---|---|\n"
        for d in main.rounds {
            let tag = d.countedInStats ? "\(d.index)" : "\(d.index)·预热"
            let note = d.scoringHeldChallengerName.map { "黏性拦 \($0)" }
                ?? (d.divergence != nil ? "分歧" : "")
            md += "| \(tag) | \(local(d.at)) | \(d.pingChoiceName ?? "—") | \(f1(d.pingEffectiveMs ?? -1)) "
            md += "| \(d.scoringChoiceName ?? "—") | \(f1(d.scoringEffectiveMs ?? -1)) "
            md += "| \(d.scoringChoiceScore.map { f1($0) } ?? "—") | \(note) |\n"
        }
        md += "\n"

        // V3 含被排除地区的时间线摘要（只列与主跑候选不同带来的差异统计）
        md += "## V3（含被排除地区）补充\n\n"
        let hkPingRounds = withHK.rounds.filter { d in
            guard let n = d.pingChoiceName else { return false }
            return !mainSpecs.contains { $0.name == n }
        }.count
        let hkScoreRounds = withHK.rounds.filter { d in
            guard let n = d.scoringChoiceName else { return false }
            return !mainSpecs.contains { $0.name == n }
        }.count
        md += "- 被排除地区节点当选轮数：纯Ping \(hkPingRounds) 轮、多维打分 \(hkScoreRounds) 轮\n"

        // 凭据红线自检：dump 里不得出现任何身份指纹（id 含凭据）
        for s in allSpecs {
            XCTAssertFalse(md.contains(s.id), "dump 泄漏节点身份指纹！")
        }

        try md.data(using: .utf8)!.write(to: URL(fileURLWithPath: outPath))
        print("REPLAY DUMP WRITTEN: \(outPath)")

        // 基本合理性断言（真实数据上两策略都必须真的在选节点）
        XCTAssertTrue(main.rounds.allSatisfy { $0.pingChoice != nil })
        XCTAssertTrue(main.rounds.allSatisfy { $0.scoringChoice != nil })
        XCTAssertEqual(main.ping.statsRoundCount, rounds.count - config.warmupRounds)
    }
}
