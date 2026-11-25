import Foundation
import NetworkExtension
import QingzhouCore

extension AppState {
    // MARK: - 流量统计、内存观测、定时关闭与实时活动

    public func refreshDomainTrafficHistory() async {
        domainTrafficReadGeneration += 1
        let generation = domainTrafficReadGeneration
        let result = await Task.detached(priority: .utility) { () -> (DomainTrafficLedger?, Bool) in
            guard let url = AppGroupStorage.fileURL(DomainTrafficLedger.storageName) else { return (nil, false) }
            guard FileManager.default.fileExists(atPath: url.path) else { return (nil, false) }
            let ledger = AppGroupStorage.read(DomainTrafficLedger.self, from: DomainTrafficLedger.storageName)
            return (ledger, ledger == nil)
        }.value
        guard !Task.isCancelled, generation == domainTrafficReadGeneration else { return }
        if let ledger = result.0 { domainTrafficHistory = ledger }
        domainTrafficReadFailed = result.1
    }

    /// Live Activity（灵动岛/锁屏）单一同步入口（E.19）。幂等：
    /// - 设置关 / VPN 没在跑 / 无当前节点 → 结束任何在显示的活动；
    /// - 否则按当前状态起或刷新（`LiveActivityController.start` 内部决定 request/update/换节点）。
    ///
    /// 由 startTunnel 起点、trafficPollingLoop 每秒、设置开关变更三处驱动。速率取波形窗口
    /// 最新样本（无样本按 0），phase 取系统真实 VPN 状态，计时起点复用 `connectedSince`
    /// （与首页倒计时同一口径，扩展写的会话标记）。macOS 上 controller 全 no-op。
    func syncLiveActivity() {
        guard settings.showLiveActivity, isVPNRunning, let applied = appliedTunnelConfiguration else {
            liveActivity.endAll()
            return
        }
        let phase: QingzhouActivityContentState.Phase
        switch tunnelManager.status {
        case .connected:     phase = .connected
        case .disconnecting: phase = .disconnecting
        default:             phase = .connecting   // connecting / reasserting / 其它过渡态
        }
        let traffic = trafficHistory.latest ?? TrafficStats()
        let state = QingzhouActivityContentState(phase: phase, connectedSince: connectedSince, traffic: traffic)
        liveActivity.start(nodeName: applied.nodeName, protocolName: applied.protocolType?.rawValue ?? "direct", state: state)
    }

    /// appex 经 App Group 上报的真实 `TrafficStats` 喂进波形窗口。UI 观察 `trafficHistory` 自动重绘。
    /// 下载评分单独由 ingestXrayOutboundStats 的可归属 proxy 计数驱动。
    public func ingestTrafficStats(_ stats: TrafficStats) {
        trafficHistory.record(stats)
        let previous = appliedTunnelConfiguration?.id
        tunnelSession.ingestHeartbeat(stats)
        if previous != appliedTunnelConfiguration?.id { invalidatePublicIPInfo() }
    }

    /// 只用扩展可归属的 proxy outbound 字节差分；TUN / direct 下载绝不参与。
    public func ingestXrayOutboundStats(_ stats: XrayOutboundStats, now: Date = Date()) {
        outboundStats = stats
        guard isVPNRunning, !isSwitchingTunnel,
              stats.sampledAt >= measurementNetworkStartedAt,
              (0...5).contains(now.timeIntervalSince(stats.sampledAt)),
              let applied = appliedTunnelConfiguration, applied.mode != .direct,
              stats.configurationID == applied.id,
              let idx = nodes.firstIndex(where: { applied.matches($0) }) else {
            proxyBandwidthBaseline = nil
            return
        }
        let previous = proxyBandwidthBaseline
        // App 每秒读取同一个 2秒快照，重复读不能变成新样本或覆盖基线。
        if let previous, stats.sampledAt == previous.sampledAt { return }
        proxyBandwidthBaseline = stats
        guard let previous, previous.configurationID == stats.configurationID,
              previous.sampledAt >= measurementNetworkStartedAt else { return }
        let elapsed = stats.sampledAt.timeIntervalSince(previous.sampledAt)
        guard elapsed > 0, elapsed <= 5,
              previous.proxy.downlinkBytes >= 0, stats.proxy.downlinkBytes >= previous.proxy.downlinkBytes else { return }
        let speed = Double(stats.proxy.downlinkBytes - previous.proxy.downlinkBytes) / elapsed
        guard speed.isFinite, speed < Double(Int64.max) else { return }
        let downBps = Int64(speed)
        let fingerprint = nodes[idx].identityFingerprint
        bandwidthWindows = bandwidthWindows.filter { entry in nodes.contains { $0.identityFingerprint == entry.key } }
        bandwidthWindows[fingerprint, default: RecentBandwidth()].record(bytesPerSecond: downBps, at: stats.sampledAt)
        let estimate = recentBandwidth(for: nodes[idx], now: now)
        nodes[idx].observedPeakDownBps = estimate
        if estimate == nil { nodes[idx].observedBandwidthAt = nil }
        else if downBps >= RecentBandwidth.activeFloorBps { nodes[idx].observedBandwidthAt = stats.sampledAt }
    }

    /// 即使已停 VPN，也让界面上的过期观测退回未知；不触发持久化 / 云同步。
    func expireBandwidthObservations() {
        let now = Date()
        for i in nodes.indices where nodes[i].observedPeakDownBps != nil {
            if recentBandwidth(for: nodes[i], now: now) == nil {
                nodes[i].observedPeakDownBps = nil
                nodes[i].observedBandwidthAt = nil
            }
        }
    }

    /// 扩展内存观测的主 App 侧（每秒调，轻量：读一个小 JSON 文件）：
    /// 1. 刷新 `tunnelMemory` 给设置页「诊断」区显示（含 VPN 停后的历史峰值残留）；
    /// 2. 扩展侧新增的 40MB 越限告警转写进主 App 日志（LogsView 可见、可导出）——
    ///    扩展进程的 os_log 用户看不到，这里是它进 App 内日志页的通道。
    func syncTunnelMemory() {
        // "memory-stats" 与 XrayCore.TunnelAppGroup.memoryStatsName 一致（两模块互不依赖）
        guard let stats = AppGroupStorage.read(TunnelMemoryStats.self, from: "memory-stats") else { return }
        tunnelMemory = stats
        if stats.warningCount > loggedMemoryWarningCount {
            #if DEBUG
            AcceptanceTrace.record(.memoryWarning)
            #endif
            // 主 App 不在场时扩展照常计数，这里回放漏掉的告警（合并成一条，别刷屏）
            let missed = stats.warningCount - loggedMemoryWarningCount
            loggedMemoryWarningCount = stats.warningCount
            logger.warn(
                "隧道扩展内存接近上限：footprint \(ByteFormatter.format(stats.footprintBytes))，"
                + "会话峰值 \(ByteFormatter.format(stats.sessionPeakBytes))"
                + "（iOS jetsam 上限 50 MB，本次会话第 \(stats.warningCount) 次越过 40 MB"
                + (missed > 1 ? "，含 \(missed - 1) 次主 App 离线期间的告警" : "") + "）",
                category: "tunnel"
            )
        } else if stats.warningCount < loggedMemoryWarningCount {
            loggedMemoryWarningCount = stats.warningCount   // 扩展重启，计数归零
        }
    }

    /// 定时关闭的主 App 侧收尾（每秒调，轻量：读一个小 JSON 文件）：
    /// 1. 倒计时展示：VPN 开着且扩展标记了本次会话带定时 → 暴露 deadline 给首页；
    /// 2. 到点自停识别：扩展写了 stoppedAt 且隧道确实断了 → 开关归位 + toast。
    ///    这条路**不承担关 VPN 的正确性**（On-Demand 在启用定时的连接上本来就没开，
    ///    扩展 cancelTunnelWithError 后不会被拉回）—— 只是 UI 收尾，主 App 不在场也没事。
    func syncAutoStopState() {
        guard !isSwitchingTunnel else { return }   // 热切换窗口内状态是过渡态，别误判
        // 文件名与 XrayCore.TunnelAppGroup.tunnelSessionName 一致（两模块互不依赖）
        let session = AppGroupStorage.read(TunnelSessionInfo.self, from: "tunnel-session")
        syncAppliedConfiguration(session: session, status: tunnelManager.status)
        if isVPNRunning, let applied = appliedTunnelConfiguration,
           session?.appliedConfiguration?.id == applied.id {
            activeTrafficSessionID = session?.trafficSessionID
        } else {
            activeTrafficSessionID = nil
        }

        if isVPNRunning, let s = session, s.stoppedAt == nil,
           let deadline = s.deadline, deadline > Date() {
            autoStopDeadline = deadline
        } else {
            autoStopDeadline = nil
        }

        // 已连接时长的起点：采纳扩展写的会话起点（xray 真跑起来那刻），但只认不早于
        // 本进程本次 start 的 —— start 后扩展还没写新标记的 1–3 秒里，旧标记会把时长
        // 显示成上次会话的几小时。窗口期内保持 nil（UI 不显示），新标记落盘后自然出现。
        if isVPNRunning, let s = session, s.stoppedAt == nil,
           let floor = lastTunnelStartAt, s.startedAt >= floor.addingTimeInterval(-1) {
            connectedSince = s.startedAt
        } else if !isVPNRunning {
            connectedSince = nil
        }

        if isVPNRunning, let s = session, s.stoppedAt != nil,
           tunnelManager.status == .disconnected || tunnelManager.status == .invalid {
            isVPNRunning = false
            connectedSince = nil
            markAllConnectionsClosed()
            scheduleIPRefresh()
            showToast(L("已按定时自动断开 VPN"))
            logger.info("Auto-stop observed from extension (stoppedAt=\(s.stoppedAt!))", category: "tunnel")
        }

        // 计划外断开侦测（诊断用）：VPN 应在跑、也确实连上过（connectedSince 非 nil），
        // 却发现隧道断了、且不是定时到点（无 stoppedAt）—— 说明扩展进程死了（内存超限
        // 被 jetsam / xray 崩溃 / 系统回收）。On-Demand 开着时系统随后会自动拉起，用户
        // 看到的就是一次「计划外启停」。落一条带系统断开原因的日志，让日志页能把这类
        // 重启和择优切换（"Clean-restart switched…"）分开数 —— 用户报「启停频繁」时有据可查。
        if isVPNRunning, connectedSince != nil,
           tunnelManager.status == .disconnected || tunnelManager.status == .invalid,
           session?.stoppedAt == nil,
           !loggedUnexpectedTunnelDeath {
            loggedUnexpectedTunnelDeath = true
            #if DEBUG
            AcceptanceTrace.record(.unexpectedDisconnect)
            #endif
            Task { @MainActor [weak self] in
                guard let self else { return }
                let reason = await self.tunnelManager.lastDisconnectError()
                self.logger.error(
                    "隧道计划外断开（App 未发起）：\(reason ?? "系统未报告原因")。"
                    + "疑似扩展进程被回收（内存超限 / 崩溃）；On-Demand 开启时系统会自动重连",
                    category: "tunnel")
            }
        } else if tunnelManager.status == .connected {
            loggedUnexpectedTunnelDeath = false
        }
    }

    /// 会话是扩展的提交点，系统已连接才采认；启动窗口中拒绝上次会话的残留。
    func syncAppliedConfiguration(session: TunnelSessionInfo?, status: NEVPNStatus) {
        let previous = appliedTunnelConfiguration?.id
        tunnelSession.update(session: session, status: status)
        if previous != appliedTunnelConfiguration?.id {
            invalidatePublicIPInfo()
            scheduleIPRefresh()
        }
    }

    /// 回执与共享文件独立，写文件失败时不能继续采认旧会话为实际配置。
    func recordAppliedAcknowledgement(_ id: UUID?) {
        tunnelSession.recordAcknowledgement(id)
    }
}
