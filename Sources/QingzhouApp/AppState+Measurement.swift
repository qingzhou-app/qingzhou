import Foundation
import QingzhouCore
import QingzhouSpeedTest

extension AppState {
    // MARK: - 测速与诊断

    /// 手动入口默认全量；调度使用相同预算与缓存，不改变当前选择。
    public func measureAllNodes(origin: AutoSelectOrigin = .manual) async {
        guard directMeasurementID == nil, !Task.isCancelled else { return }
        let roundID = UUID()
        let networkAtStart = measurementNetworkID
        directMeasurementID = roundID
        for i in nodes.indices where !nodes[i].protocolType.supportsTCPProbe {
            nodes[i].lastLatencyMs = nil; nodes[i].lastTestedAt = nil
        }
        defer { if directMeasurementID == roundID { directMeasurementID = nil; measuringNodeIds = [] } }
        await measureDirectNodes(origin: origin, roundID: roundID, networkID: networkAtStart,
                                 evidence: SelectionMeasurementEvidence())
        persist()
    }

    /// 预算没覆盖的旧直连不能作为本轮新赢家；缓存只在同网络的5分钟窗口有效。
    var freshSelectionNodes: [Node] {
        nodes.filter { !$0.protocolType.supportsTCPProbe || DirectProbePlanner.isRecent($0, now: measurementNow()) }
    }

    func measureDirectNodes(origin: AutoSelectOrigin, roundID: UUID, networkID: UUID,
                            evidence: SelectionMeasurementEvidence) async {
        synchronizeDirectAliases()
        var targets = nodes.filter { !isEffectivelyExcluded($0) && $0.protocolType.supportsTCPProbe }
        if origin == .scheduled {
            targets.removeAll { $0.id != currentNodeId && nodeProbeCooldown.contains($0.identityFingerprint, now: measurementNow()) }
            let ranked = targets.map { (node: $0, score: scoreForAutoSelect($0).total) }.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.node.identityFingerprint < $1.node.identityFingerprint
            }.map(\.node)
            let plan = DirectProbePlanner.plan(ranked: ranked, incumbentID: currentNodeId, now: measurementNow(),
                                               confirmingIdentity: selectionHysteresis.pendingChallenger)
            let identities = Set(plan.candidates.map(\.identityFingerprint))
            targets = targets.filter { identities.contains($0.identityFingerprint) }
            evidence.directReusedCount = plan.reusedCount
            evidence.directDeferredCount = plan.deferredCount
        }
        let fingerprints = Dictionary(targets.map { ($0.id, $0.identityFingerprint) }, uniquingKeysWith: { first, _ in first })
        measuringNodeIds = Set(targets.map(\.id))
        _ = await nodeSelector.measure(nodes: targets, shouldContinue: { [weak self] in
            guard let self else { return false }
            return self.directMeasurementID == roundID && self.measurementNetworkID == networkID
        }) { [weak self] nodeID, result in
            guard let self, !Task.isCancelled, self.directMeasurementID == roundID,
                  self.measurementNetworkID == networkID else { return }
            self.measuringNodeIds.remove(nodeID)
            guard let i = self.nodes.firstIndex(where: { $0.id == nodeID && $0.identityFingerprint == fingerprints[nodeID] }),
                  !self.isEffectivelyExcluded(self.nodes[i]) else { return }
            guard result.isNodeObservation else { return }
            let testedAt = self.measurementNow()
            self.nodes[i].lastLatencyMs = result.latencyMs
            self.nodes[i].lastTestedAt = testedAt
            // 同配置别名共享观测，不可凭别名数量虚增稳定性样本和成功数。
            if evidence.directRecorded.insert(self.nodes[i].identityFingerprint).inserted {
                if result.latencyMs != nil { evidence.directSucceeded += 1 } else { evidence.directFailed += 1 }
                self.recordNodeDirectMeasurement(self.nodes[i], latencyMs: result.latencyMs,
                                                 lossFraction: result.lossFraction, at: testedAt)
            }
        }
        synchronizeDirectAliases()
    }

    /// 排除某个别名只影响探测/选择资格，不让它保留已被同配置新失败推翻的旧成功。
    private func synchronizeDirectAliases() {
        let now = measurementNow()
        var latest: [String: (at: Date, ms: Int?)] = [:]
        for node in nodes where node.protocolType.supportsTCPProbe {
            guard let at = node.lastTestedAt, at <= now else { continue }
            let identity = node.identityFingerprint
            if let old = latest[identity], old.at > at || (old.at == at && old.ms == nil) { continue }
            latest[identity] = (at, node.lastLatencyMs)
        }
        for i in nodes.indices {
            guard let observation = latest[nodes[i].identityFingerprint] else { continue }
            nodes[i].lastTestedAt = observation.at
            nodes[i].lastLatencyMs = observation.ms
        }
    }

    /// 用户主动触发；沿用已有串行代理探针，不改当前选择、不额外启停 VPN。
    public func diagnoseNode(_ node: Node) async -> NodeDiagnosticReport? {
        let generation = UUID()
        diagnosticGeneration = generation
        proxyProbeContext &+= 1
        let network = measurementNetworkID
        let context = proxyProbeContext
        func isCurrent() -> Bool {
            !Task.isCancelled && diagnosticGeneration == generation && measurementNetworkID == network
                && proxyProbeContext == context
                && nodes.contains { $0.id == node.id && $0.identityFingerprint == node.identityFingerprint }
        }
        guard isCurrent() else { return nil }
        let direct = await nodeSelector.diagnose(node, shouldContinue: { [weak self] in
            guard let self else { return false }
            return self.diagnosticGeneration == generation && self.measurementNetworkID == network
                && self.proxyProbeContext == context
                && self.nodes.contains { $0.id == node.id && $0.identityFingerprint == node.identityFingerprint }
        })
        guard isCurrent() else { return nil }
        let proxy: ProxyProbeOutcome?
        if isVPNRunning && !isSwitchingTunnel {
            proxy = await probeProxiedLatency(node)
        } else { proxy = nil }
        guard isCurrent() else { return nil }
        return NodeDiagnosticReport(node: node, direct: direct, proxy: proxy, at: measurementNow())
    }

    // MARK: - 经代理延迟（VPN 开启时经隧道扩展 libXray Ping 真实走节点测）

    /// 给单个节点测「经代理延迟」：隧道扩展起临时 xray 实例、真实通过该节点发一次
    /// HTTP HEAD，量到的是「本机→节点→目标站点」全链路毫秒数 —— 与直连 TCP 握手 RTT
    ///（lastLatencyMs）是两个维度。只在 VPN 运行时可用（libXray 只在扩展进程里）；
    /// VPN 关闭时 UI 应引导用户用普通测速（直连维度）。
    /// - Returns: 成功时的毫秒数；失败返回 nil（并在 `showToastOnError` 时 toast 错误）。
    /// `targetOverride`：本轮经代理探测目标的显式覆盖（自动择优的域名画像轮换用，见
    /// `refineWithProxiedLatency`）。nil = 沿用 `settings.proxiedTestTarget`（手动单测走这条，
    /// 保持稳定可比的 Cloudflare 目标）。
    @discardableResult
    public func measureProxiedLatency(
        _ node: Node, showToastOnError: Bool = true, targetOverride: String? = nil
    ) async -> Int? {
        proxyProbeContext &+= 1
        return await probeProxiedLatency(node, showToastOnError: showToastOnError, targetOverride: targetOverride).latency
    }

    func probeProxiedLatency(_ node: Node, showToastOnError: Bool = false,
        targetOverride: String? = nil) async -> ProxyProbeOutcome {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard isVPNRunning, !isSwitchingTunnel else { return .failure(.unavailable) }
        guard nodes.contains(where: { $0.id == node.id && $0.identityFingerprint == node.identityFingerprint }) else {
            return .failure(.superseded)
        }
        let generation = UUID()
        let context = proxyProbeContext
        proxyMeasurementGeneration[node.id] = generation
        proxiedMeasuringNodeIds.insert(node.id)
        defer {
            if proxyMeasurementGeneration[node.id] == generation {
                proxyMeasurementGeneration[node.id] = nil
                proxiedMeasuringNodeIds.remove(node.id)
            }
        }
        let outcome: ProxyProbeOutcome
        do {
            let target = targetOverride ?? settings.proxiedTestTarget
            let ms = try await proxiedProber.pingNode(node: node, targetURL: target, timeoutSeconds: 5)
            outcome = (0..<10_000).contains(ms) ? .success(ms) : .failure(.unavailable)
        } catch {
            if Task.isCancelled || error is CancellationError { return .failure(.cancelled) }
            let kind = (error as? ProxyProbeError)?.kind ?? .unavailable
            outcome = .failure(kind)
            if showToastOnError { showToast(L("经代理测速失败：\(error.localizedDescription)")) }
            // 不把内核原始错误或配置指纹写入择优日志。
            logger.warn("Proxied probe did not complete: \(kind.rawValue)", category: "tunnel")
        }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard isVPNRunning, !isSwitchingTunnel else { return .failure(.unavailable) }
        guard proxyProbeContext == context, proxyMeasurementGeneration[node.id] == generation,
              let i = nodes.firstIndex(where: { $0.id == node.id && $0.identityFingerprint == node.identityFingerprint }) else {
            return .failure(.superseded)
        }
        switch outcome {
        case .success(let ms):
            nodes[i].lastProxiedLatencyMs = ms
            nodes[i].lastProxiedTestedAt = measurementNow()
            recordNodeProxiedMeasurement(nodes[i], proxiedMs: ms)
            nodeProbeCooldown.recover(node.identityFingerprint)
            persist()
        case .failure(.probeFailed), .failure(.invalidConfiguration):
            nodes[i].lastProxiedLatencyMs = nil
            nodes[i].lastProxiedTestedAt = measurementNow()
            persist()
        case .failure: break // 资源、通信、取消不能覆盖节点测量。
        }
        return outcome
    }

    /// 批量测所有未排除节点的「经代理延迟」。**串行**逐个测 —— 扩展进程同一时刻只跑
    /// 一个临时 xray 实例（iOS NE 50MB 内存硬上限），并发毫无意义还有 jetsam 风险。
    /// 进度通过 `proxiedMeasuringNodeIds` 递减反映（UI 显示 n/total）。
    public func measureAllProxiedLatencies() async {
        guard isVPNRunning else {
            showToast(L("经代理测速需要 VPN 运行中"))
            return
        }
        let targets = nodes.filter { !$0.isExcluded }
        proxiedMeasuringNodeIds = Set(targets.map(\.id))
        defer { proxiedMeasuringNodeIds = [] }
        for node in targets {
            // 中途 VPN 停了 / 用户切走导致任务取消 → 立刻收工
            if Task.isCancelled || !isVPNRunning { break }
            _ = await measureProxiedLatency(node, showToastOnError: false)
            proxiedMeasuringNodeIds.remove(node.id)
        }
    }
}
