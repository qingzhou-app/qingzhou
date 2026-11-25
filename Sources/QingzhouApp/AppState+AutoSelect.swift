import Foundation
import QingzhouCore
import QingzhouSpeedTest

extension AppState {
    // MARK: - 自动择优

    /// 自动择优的触发来源：分数黏性只约束定时路径（schedulerLoop）—— 手动点「择优」、
    /// 添加订阅、云恢复都是用户主动动作，一轮采用综合评分结果。
    public enum AutoSelectOrigin: Sendable { case manual, scheduled }

    public func autoSelectBestNode(origin: AutoSelectOrigin = .manual) async {
        await autoSelectBestNode(origin: origin, applySelection: {
            await self.reapplyRunningTunnel(scope: .nodeOnly)
        })
    }

    /// 决策与实际VPN应用之间的窄IO边界；场景回放注入记录器，执行同一套择优流程。
    func autoSelectBestNode(origin: AutoSelectOrigin, applySelection: @MainActor () async -> Void) async {
        guard !nodes.isEmpty, directMeasurementID == nil, !Task.isCancelled else { return }
        let roundID = UUID()
        let networkAtStart = measurementNetworkID
        let evidence = SelectionMeasurementEvidence()
        directMeasurementID = roundID
        let selectionAtStart = currentNodeId
        let probeContextAtStart = proxyProbeContext
        let intentAtStart = selectionIntentGeneration
        for i in nodes.indices where !nodes[i].protocolType.supportsTCPProbe {
            nodes[i].lastLatencyMs = nil; nodes[i].lastTestedAt = nil
        }
        defer { if directMeasurementID == roundID { directMeasurementID = nil; measuringNodeIds = [] } }
        await measureDirectNodes(origin: origin, roundID: roundID, networkID: networkAtStart, evidence: evidence)
        guard !Task.isCancelled else {
            recordSelectionReport(id: roundID, origin: origin, reason: .cancelled, evidence: evidence)
            return
        }
        guard measurementNetworkID == networkAtStart else {
            recordSelectionReport(id: roundID, origin: origin, reason: .networkChanged, evidence: evidence)
            return
        }
        // 用户在测量期间另选节点时，尊重这个更新的意图，不再提交旧的择优请求。
        guard selectionIntentGeneration == intentAtStart, currentNodeId == selectionAtStart else {
            recordSelectionReport(id: roundID, origin: origin, reason: .selectionChanged, evidence: evidence)
            persist(); return
        }
        let previousId = currentNodeId
        var ranking = rankRespectingRegions(from: freshSelectionNodes)
        let shouldProbe = settings.autoSelectUsesProxiedLatency || (ranking == nil && nodes.contains {
            !$0.protocolType.supportsTCPProbe && !isEffectivelyExcluded($0)
        })
        var availabilityRecovery = false
        if shouldProbe, isVPNRunning, !isSwitchingTunnel {
            ranking = await refineWithProxiedLatency(initial: ranking, evidence: evidence,
                intent: intentAtStart, selection: selectionAtStart, origin: origin, context: probeContextAtStart)
            availabilityRecovery = currentNode.map { evidence.confirmedFailures.contains($0.identityFingerprint) } ?? false
        } else if settings.autoSelectUsesProxiedLatency {
            evidence.proxy.state = isVPNRunning ? .switchInProgress : .vpnUnavailable
        }
        guard !Task.isCancelled, selectionIntentGeneration == intentAtStart, currentNodeId == selectionAtStart else {
            recordSelectionReport(id: roundID, origin: origin,
                reason: Task.isCancelled ? .cancelled : .selectionChanged, evidence: evidence)
            persist(); return
        }
        guard measurementNetworkID == networkAtStart else {
            recordSelectionReport(id: roundID, origin: origin, reason: .networkChanged, evidence: evidence)
            return
        }
        if evidence.proxy.keptCurrentSelection {
            resetScoreStreak()
            recordSelectionReport(id: roundID, origin: origin, reason: .proxyUnverified, ranking: ranking, evidence: evidence)
            persist(); return
        }
        if var best = ranking?.node {
            guard !Task.isCancelled, selectionIntentGeneration == intentAtStart, currentNodeId == selectionAtStart else {
                recordSelectionReport(id: roundID, origin: origin,
                    reason: Task.isCancelled ? .cancelled : .selectionChanged, evidence: evidence)
                persist(); return
            }
            guard
                  let liveBest = nodes.first(where: { $0.id == best.id && $0.identityFingerprint == best.identityFingerprint }),
                  !isEffectivelyExcluded(liveBest) else {
                recordSelectionReport(id: roundID, origin: origin, reason: .candidateChanged, evidence: evidence)
                persist(); return
            }
            best = liveBest
            if !availabilityRecovery, shouldHoldForScoreStickiness(origin: origin, challenger: best, incumbent: currentNode) {
                let reason: NodeSelectionReport.Reason
                switch selectionHysteresis.decision {
                case .holdForStreak(let completed, let required): reason = .confirmingLead(completed: completed, required: required)
                default: reason = .insufficientLead
                }
                recordSelectionReport(id: roundID, origin: origin, reason: reason, ranking: ranking,
                    heldChallenger: best, evidence: evidence)
                persist(); return
            }
            currentNodeId = best.id
            recordSelectionReport(id: roundID, origin: origin,
                reason: availabilityRecovery ? .availabilityRecovery : (best.id == previousId ? .alreadyBest : .highestScore),
                ranking: ranking, evidence: evidence)
            logger.info("Auto-selected \(best.name) [\(best.region)] (direct \(best.lastLatencyMs ?? -1)ms / proxied \(best.lastProxiedLatencyMs ?? -1)ms)", category: "app")
            #if DEBUG
            AcceptanceTrace.record(.autoSelected)
            #endif
        } else {
            recordSelectionReport(id: roundID, origin: origin, reason: .noEligibleMeasurement, evidence: evidence)
            logger.warn("Auto-select found no viable node", category: "app")
        }
        persist()
        // 节点变了且 VPN 在跑 → 热切换，立即生效（只换节点 → 走原地换出口快路径）
        if currentNodeId != previousId {
            resetScoreStreak()   // 换人了：旧的挑战者连续计数作废
            await applySelection()
        }
    }

    private struct SelectionRanking {
        let node: Node
        let candidate: NodeSelectionReport.Candidate
        let profile: ScoringProfile
        let prefersLowerRate: Bool
        let preferredRegion: String?
        let usedPreferredRegion: Bool
    }

    private func captureSelectionCandidate(_ node: Node, score: NodeScorer.Score? = nil) -> NodeSelectionReport.Candidate {
        .init(id: node.id, name: node.name, region: node.region, directLatencyMs: node.lastLatencyMs,
            score: score ?? scoreForAutoSelect(node),
            stabilitySampleCount: NodeScorer.recentHistory(currentNetworkHistory(for: node), now: measurementNow()).count,
            hasBandwidthObservation: recentBandwidth(for: node) != nil)
    }

    private func captureRanking(_ best: (node: Node, score: NodeScorer.Score), preferredRegion: String?,
        usedPreferredRegion: Bool) -> SelectionRanking {
        .init(node: best.node, candidate: captureSelectionCandidate(best.node, score: best.score),
            profile: settings.scoringProfile, prefersLowerRate: settings.preferLowerRate,
            preferredRegion: preferredRegion, usedPreferredRegion: usedPreferredRegion)
    }

    private func recordSelectionReport(id: UUID, origin: AutoSelectOrigin, reason: NodeSelectionReport.Reason,
        ranking: SelectionRanking? = nil, heldChallenger: Node? = nil, evidence: SelectionMeasurementEvidence) {
        if evidence.proxy.attempted == 0, evidence.proxy.state == .notRequested,
           settings.autoSelectUsesProxiedLatency {
            evidence.proxy.state = isVPNRunning ? (isSwitchingTunnel ? .switchInProgress : .notRequested) : .vpnUnavailable
        }
        let udpMissing = nodes.filter { !$0.protocolType.supportsTCPProbe && !isEffectivelyExcluded($0)
            && !hasUsableSelectionMeasurement($0) }.count
        lastSelectionReport = .init(id: id, completedAt: measurementNow(), origin: origin, reason: reason,
            selected: currentNode.map { node in
                if heldChallenger == nil, let ranking, ranking.node.id == node.id { return ranking.candidate }
                return captureSelectionCandidate(node)
            },
            challenger: heldChallenger.map { captureSelectionCandidate($0) } ?? ranking?.candidate,
            profile: heldChallenger != nil ? settings.scoringProfile : (ranking?.profile ?? settings.scoringProfile),
            prefersLowerRate: heldChallenger != nil ? settings.preferLowerRate : (ranking?.prefersLowerRate ?? settings.preferLowerRate),
            preferredRegion: ranking?.preferredRegion,
            usedPreferredRegion: ranking?.usedPreferredRegion ?? false,
            excludedCount: nodes.filter(isEffectivelyExcluded).count,
            directSucceeded: evidence.directSucceeded, directFailed: evidence.directFailed,
            unmeasuredUDPCount: udpMissing, proxy: evidence.proxy,
            directReusedCount: evidence.directReusedCount, directDeferredCount: evidence.directDeferredCount)
    }

    /// 直连延迟的「绿色」阈值（毫秒）—— 节点列表 chip 配色与经代理精选候选池共用同一口径。
    static let directGreenThresholdMs = 200

    /// 当轮成功才允许替换当前选择；代理探测不可用或中断时保留当前选择。
    private func refineWithProxiedLatency(initial: SelectionRanking?, evidence: SelectionMeasurementEvidence,
        intent: UInt64, selection: UUID?, origin: AutoSelectOrigin, context: UInt64) async -> SelectionRanking? {
        let viable = freshSelectionNodes.filter { !isEffectivelyExcluded($0) && ($0.lastLatencyMs != nil || !$0.protocolType.supportsTCPProbe) }
        var pool = viable
        let preferredRegion = settings.preferredRegion
        var usedPreferredRegion = false
        if let pref = preferredRegion {
            let inPref = viable.filter { $0.region == pref }
            if !inPref.isEmpty { pool = inPref; usedPreferredRegion = true }
        }
        let skipped = nodes.filter { !isEffectivelyExcluded($0)
            && (!usedPreferredRegion || $0.region == preferredRegion)
            && origin == .scheduled && $0.id != currentNodeId
            && nodeProbeCooldown.contains($0.identityFingerprint, now: measurementNow()) }
        pool.removeAll { n in skipped.contains(where: { $0.id == n.id }) }
        // 不再用 TCP <200ms 硬筛；高握手延迟或没有 TCP 的 UDP 节点也能获得探索机会。
        let ranked = pool.map { (node: $0, score: scoreForAutoSelect($0).total) }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.node.name != $1.node.name { return $0.node.name < $1.node.name }
            return $0.node.id.uuidString < $1.node.id.uuidString
        }.map(\.node)
        let incumbent = currentNode.flatMap { isEffectivelyExcluded($0) ? nil : $0 }
        nodeProbePlanner.prune(keeping: Set(nodes.map(\.identityFingerprint)))
        let plan = nodeProbePlanner.plan(ranked: ranked, incumbent: incumbent)
        let candidates = plan.candidates
        let roundTarget = settings.proxiedTestTarget.isEmpty
            ? ProxiedProbePlanner.probeTarget(from: domainHistory, roundIndex: proxiedProbeRound) : nil
        if roundTarget != nil { proxiedProbeRound &+= 1 }
        let target = roundTarget ?? (settings.proxiedTestTarget.isEmpty ? ConnectivityProbe.defaultProxiedTarget : settings.proxiedTestTarget)
        let candidateSnapshot = candidates
        let round = await ProxySelectionRound.run(candidates: candidateSnapshot, incumbentID: currentNodeId,
            initialID: initial?.node.id, target: target,
            shouldContinue: { self.isVPNRunning && !self.isSwitchingTunnel
                && self.selectionIntentGeneration == intent && self.currentNodeId == selection
                && self.proxyProbeContext == context
                && candidateSnapshot.allSatisfy { candidate in
                    self.nodes.contains { $0.id == candidate.id && $0.identityFingerprint == candidate.identityFingerprint
                        && !self.isEffectivelyExcluded($0) }
                } },
            probe: { node, target in await self.probeProxiedLatency(node, targetOverride: target) })
        evidence.proxy = round.evidence
        evidence.proxy.coolingDownCount = Set(skipped.map(\.identityFingerprint)).count
        evidence.proxy.candidateCount = candidates.count
        evidence.proxy.explorationCount = plan.explorationCount
        let validFailures = round.confirmedFailures.filter { fingerprint in
            nodes.contains { $0.identityFingerprint == fingerprint && !isEffectivelyExcluded($0) }
        }
        nodeProbeCooldown.confirm(validFailures, now: measurementNow())
        evidence.confirmedFailures = validFailures
        evidence.proxy.confirmedFailureCount = validFailures.count
        let measured = round.measurements.filter { sample in
            (!usedPreferredRegion || sample.node.region == preferredRegion) &&
            nodes.contains { $0.id == sample.node.id && $0.identityFingerprint == sample.node.identityFingerprint && !isEffectivelyExcluded($0) }
        }
        if let best = bestByScore(measured.map(\.node),
            latency: { node in measured.first { $0.node.id == node.id }?.ms ?? .max },
            score: { node in NodeScorer.score(.init(directLatencyMs: node.lastLatencyMs,
                proxiedLatencyMs: measured.first { $0.node.id == node.id }?.ms,
                history: currentNetworkHistory(for: node),
                peakDownBps: recentBandwidth(for: node), rate: node.rateForComparison),
                preferLowerRate: settings.preferLowerRate, weights: NodeScorer.weights(for: settings.scoringProfile), now: measurementNow()) }
        ) {
            return captureRanking(best, preferredRegion: preferredRegion, usedPreferredRegion: usedPreferredRegion)
        }
        evidence.proxy.keptCurrentSelection = true
        return initial // 只保留初选作为诊断候选；调用者禁止发布它。
    }

    /// 从候选里选 `NodeScorer` 总分最高者 —— 自动择优的内核。旧「延迟最低 + 接近时
    /// 优先低倍率（tieBand）」被打分吸收：成本维连续参与加权，不再需要档位判定；
    /// 稳定性 / 带宽维度让「延迟低但抖动大」的节点不再稳赢。
    /// 平分时延迟低者优先，再平比名字 —— 选择结果必须确定，测试和用户观感都依赖这一点。
    private func bestByScore(
        _ candidates: [Node],
        latency: (Node) -> Int,
        score: (Node) -> NodeScorer.Score
    ) -> (node: Node, score: NodeScorer.Score)? {
        // 同一次排序冻结每个输入的实际分数，不在异步探测结束后重新计算过去的排名。
        let evaluated = candidates.map { (node: $0, score: score($0)) }
        return evaluated.min { a, b in
            if a.score.total != b.score.total { return a.score.total > b.score.total }
            if latency(a.node) != latency(b.node) { return latency(a.node) < latency(b.node) }
            return a.node.name.localizedStandardCompare(b.node.name) == .orderedAscending
        }
    }

    /// 在测速结果里挑最佳节点，应用「地区排除」+「地区优先」+ NodeScorer 总分：
    /// 1. 先剔除有效排除（手动排除 / 地区排除）和测速失败的节点
    /// 2. 若设了优先地区且该地区有可用节点，从中选总分最高者
    /// 3. 否则全局选
    func pickBestRespectingRegions(from measured: [Node]) -> Node? {
        rankRespectingRegions(from: measured)?.node
    }

    private func rankRespectingRegions(from measured: [Node]) -> SelectionRanking? {
        let viable = measured.filter { !isEffectivelyExcluded($0) && hasUsableSelectionMeasurement($0) }
        guard !viable.isEmpty else { return nil }
        let latency: (Node) -> Int = { $0.lastLatencyMs ?? .max }
        if let pref = settings.preferredRegion {
            let inPref = viable.filter { $0.region == pref }
            if let best = bestByScore(inPref, latency: latency, score: scoreForAutoSelect) {
                return captureRanking(best, preferredRegion: settings.preferredRegion, usedPreferredRegion: true)
            }
        }
        return bestByScore(viable, latency: latency, score: scoreForAutoSelect).map {
            captureRanking($0, preferredRegion: settings.preferredRegion, usedPreferredRegion: false)
        }
    }

    /// 同网络历史和近期带宽；代理权重 / 稳定性置信度按时间衰减，24h 后退出。
    func scoreForAutoSelect(_ node: Node) -> NodeScorer.Score {
        NodeScorer.score(
            NodeScorer.Input(
                directLatencyMs: node.lastLatencyMs,
                proxiedLatencyMs: node.lastProxiedLatencyMs,
                proxiedTestedAt: node.lastProxiedTestedAt,
                history: currentNetworkHistory(for: node),
                peakDownBps: recentBandwidth(for: node),
                rate: node.rateForComparison
            ),
            preferLowerRate: settings.preferLowerRate,
            weights: NodeScorer.weights(for: settings.scoringProfile), now: measurementNow()
        )
    }

    static let autoSwitchScoreMargin = NodeSelectionHysteresis.defaultMargin
    static let autoSwitchScoreStreakRounds = NodeSelectionHysteresis.defaultRounds

    func hasUsableSelectionMeasurement(_ node: Node, now date: Date? = nil) -> Bool {
        let now = date ?? measurementNow()
        guard !nodeProbeCooldown.contains(node.identityFingerprint, now: now) else { return false }
        if node.protocolType.supportsTCPProbe { return node.lastLatencyMs != nil }
        guard node.lastProxiedLatencyMs != nil, let at = node.lastProxiedTestedAt else { return false }
        return (0...NodeScorer.proxiedFreshnessWindow).contains(now.timeIntervalSince(at))
    }

    /// 手动请求立即采用综合分数；自动请求使用与回放同一份分数黏性。
    func shouldHoldForScoreStickiness(origin: AutoSelectOrigin, challenger: Node, incumbent: Node?) -> Bool {
        guard origin == .scheduled, isVPNRunning, !isSwitchingTunnel else {
            if origin == .scheduled { resetScoreStreak() }
            return false
        }
        return selectionHysteresis.shouldHold(
            challenger: challenger.identityFingerprint, incumbent: incumbent?.identityFingerprint,
            challengerScore: scoreForAutoSelect(challenger).total,
            incumbentScore: incumbent.map { scoreForAutoSelect($0).total } ?? 0,
            incumbentViable: incumbent.map { !isEffectivelyExcluded($0) && hasUsableSelectionMeasurement($0) } ?? false
        )
    }

    private func resetScoreStreak() { selectionHysteresis.reset() }

    /// 路径事件是新的测量上下文，不能推断它仍是上次的 Wi-Fi。
    func measurementNetworkDidChange(at date: Date? = nil) {
        let now = date ?? measurementNow()
        measurementNetworkID = UUID()
        invalidatePublicIPInfo()
        measurementNetworkStartedAt = now
        proxyProbeContext &+= 1
        nodeProbeCooldown.reset()
        resetScoreStreak()
        bandwidthWindows.removeAll()
        proxyBandwidthBaseline = nil
        nodeProbePlanner = NodeProbePlanner()
        for i in nodes.indices {
            nodes[i].lastLatencyMs = nil; nodes[i].lastTestedAt = nil
            nodes[i].lastProxiedLatencyMs = nil; nodes[i].lastProxiedTestedAt = nil
            nodes[i].observedPeakDownBps = nil; nodes[i].observedBandwidthAt = nil
        }
    }

    private func currentNetworkHistory(for node: Node) -> [NodeMetricSample] {
        nodeMetricsHistory.samples(for: node.identityFingerprint, networkID: measurementNetworkID)
    }

    public func recentBandwidth(for node: Node, now: Date? = nil) -> Int64? {
        bandwidthWindows[node.identityFingerprint]?.estimate(at: now ?? measurementNow())
    }
}
