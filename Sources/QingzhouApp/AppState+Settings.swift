import Foundation
import struct SwiftUI.Binding
import QingzhouCore
import QingzhouLogging

extension AppState {
    /// 代理模式专用 Binding。普通 `setting(\.proxyMode)` 只会改值 + 持久化；这个还会在
    /// VPN 正在运行时自动重启隧道，让新模式立即生效——对称于切换节点的热切换，用户不用手动关开。
    public var proxyModeBinding: Binding<ProxyMode> {
        Binding(get: { self.settings.proxyMode }, set: { self.setProxyMode($0) })
    }

    /// QUIC 策略专用 Binding（三档 Picker 用）。改值 + 持久化；VPN 在跑时热重启隧道，
    /// 让新策略算出的有效 blockQUIC 立即生效（全量重配会重建 routing）。对称于代理模式切换。
    public var quicPolicyBinding: Binding<QUICPolicy> {
        Binding(get: { self.settings.quicPolicy }, set: { self.setQUICPolicy($0) })
    }

    /// 切换 QUIC 策略。改值 + 副作用 + 持久化；VPN 在跑则热重启隧道使新策略即时生效。
    public func setQUICPolicy(_ policy: QUICPolicy) {
        guard settings.quicPolicy != policy else { return }
        settings.quicPolicy = policy
        applySettingsSideEffects()
        persist()
        logger.info("QUIC policy → \(policy.rawValue)", category: "app")
        // VPN 在跑才需要重启（reapply 内部 guard 会在没跑时直接返回）。全量重配重建 routing，
        // 且成功后走 verifyTunnelConnectivity → 触发 auto+hysteria2 的 h3 实测。
        Task { await reapplyRunningTunnel() }
    }

    /// 设置页「当前 QUIC 运行态」状态行（**纯观测**，隧道没开 / 没有当前节点时 nil = 不显示）。
    /// 推导是纯函数 QUICRuntimeStatusResolver.status；探测 / 阻断语义零改动，只加可见性。
    /// 见 docs/QUIC.md「状态可视化」。
    public var quicRuntimeStatus: QUICRuntimeStatus? {
        guard isVPNRunning, let applied = appliedTunnelConfiguration, let node = runningNode,
              effectiveBlockQUIC(for: node) == applied.blockQUIC else { return nil }
        let fingerprint = node.identityFingerprint
        return QUICRuntimeStatusResolver.status(
            policy: settings.quicPolicy,
            protocolType: node.protocolType,
            knownBrokenOnThisNode: quicKnownBrokenNodes.contains(fingerprint),
            probePassedOnThisNode: quicProbePassedNodes.contains(fingerprint)
        )
    }

    /// 当前 QUIC 策略下、给定节点的**有效阻断值**（传给扩展 / compose 的 blockQUIC bool）。
    /// auto：hysteria2 未标记坏 → 放行；标记坏或其余协议 → 挡。见 QUICPolicyResolver / docs/QUIC.md。
    func effectiveBlockQUIC(for node: Node) -> Bool {
        QUICPolicyResolver.shouldBlock(
            policy: settings.quicPolicy,
            protocolType: node.protocolType,
            knownBrokenOnThisNode: quicKnownBrokenNodes.contains(node.identityFingerprint)
        )
    }

    /// 切换代理模式。改值 + 副作用 + 持久化；若 VPN 在跑则热重启隧道使新模式即时生效。
    public func setProxyMode(_ mode: ProxyMode) {
        guard settings.proxyMode != mode else { return }
        guard !isVPNRunning || mode == .direct || currentNode != nil else {
            tunnelError = VPNTunnelManager.TunnelError.noCurrentNode.errorDescription
            return
        }
        settings.proxyMode = mode
        applySettingsSideEffects()
        persist()
        logger.info("Proxy mode → \(mode.rawValue)", category: "app")
        // VPN 在跑才需要重启；没跑时 reapplyRunningTunnel 内部 guard 会直接返回。
        Task { await reapplyRunningTunnel() }
    }

    /// 「择优用经代理延迟精选」开关。关掉时**顺手清空所有节点已存的经代理延迟**——
    /// 否则之前测出的黄/红 chip 会一直挂在列表里，让用户误以为「关了还在测」还挺吓人
    /// （真机反馈）。清空后经代理列干净消失，需要时手动长按某节点再测即可。
    public func setAutoSelectUsesProxiedLatency(_ enabled: Bool) {
        guard settings.autoSelectUsesProxiedLatency != enabled else { return }
        settings.autoSelectUsesProxiedLatency = enabled
        if !enabled {
            for i in nodes.indices {
                nodes[i].lastProxiedLatencyMs = nil
                nodes[i].lastProxiedTestedAt = nil
            }
        }
        persist()
        logger.info("Proxied refine \(enabled ? "enabled" : "disabled (cleared proxied latencies)")", category: "app")
    }

    /// 设定「定时关闭」时长（秒，0 = 关闭）。改值 + 持久化；VPN 在跑时**热生效**：
    /// 经 providerMessage 让扩展从现在起按新时长重新计时（不重启隧道、不断流），
    /// 并同步 On-Demand 开关（定时开 → On-Demand 关，见 VPNTunnelManager.configure 注释）。
    /// 消息失败（扩展没响应等）降级为「下次连接生效」，toast 如实告知。
    public func setAutoStopSeconds(_ seconds: TimeInterval) {
        guard settings.autoStopSeconds != seconds else { return }
        settings.autoStopSeconds = seconds
        persist()
        logger.info("Auto-stop → \(Int(seconds))s", category: "tunnel")
        guard isVPNRunning, !isSwitchingTunnel else { return }
        Task { @MainActor in
            do {
                if seconds > 0 {
                    // 先关 On-Demand 再武装定时：若反过来，App 在两步之间被杀会留下
                    // 「On-Demand 开 + 定时开」—— 到点自停后被立刻拉回，定时形同虚设。
                    try await tunnelManager.setOnDemandEnabled(false)
                    try await tunnelManager.setAutoStop(seconds: seconds)
                    showToast(L("已重新计时：\(AutoStopPresets.label(for: seconds))后自动断开"))
                } else {
                    try await tunnelManager.setAutoStop(seconds: 0)
                    try await tunnelManager.setOnDemandEnabled(true)
                    autoStopDeadline = nil
                    showToast(L("已取消定时断开"))
                }
            } catch {
                logger.warn("Apply auto-stop to running tunnel failed: \(error)", category: "tunnel")
                showToast(L("定时设置将在下次连接时生效"))
            }
        }
    }

    /// settings 任意字段变化后调用：把字段的「执行性」副作用真正落地。
    /// 当前涉及：logger 级别、macOS「打开 App 自动连」监听器启停。
    func applySettingsSideEffects() {
        if let lvl = LogLevel(rawValue: settings.logLevel) {
            logger.setMinimumLevel(lvl)
        }
        // 语言切换即时生效：动态字符串（toast / 错误）改查对应语种的 lproj 子 bundle
        L10n.setLanguage(settings.language)
        // 「显示实时活动」开关变更即时生效：关掉立即结束在显示的活动，打开且在连则起。
        syncLiveActivity()
        // 「节点故障提醒」打开时才申请通知权限（opt-in）；关掉立即收起横幅。
        if FeatureFlags.autoFailoverAlert, settings.autoFailoverAlert {
            requestFailoverNotificationAuthorizationIfNeeded()
        } else if !settings.autoFailoverAlert, nodeHealthSuspect != nil {
            nodeHealthSuspect = nil
        }
        #if os(macOS)
        syncAppLaunchWatcher()
        #endif
    }

    #if os(macOS)
    /// 同步「打开指定 App 自动连」监听器：开关开且触发列表非空才监听。幂等，可重复调。
    ///
    /// 语义（见 AppLaunchWatcher 头注释）：任一触发 App 启动 → 自动开 VPN；
    /// 最后一个触发 App 退出 → 自动断（仅断由自动连拉起的会话）。
    func syncAppLaunchWatcher() {
        guard settings.autoConnectOnAppLaunch, !settings.autoConnectApps.isEmpty else {
            appLaunchWatcher?.stop()
            return
        }
        if appLaunchWatcher == nil {
            appLaunchWatcher = AppLaunchWatcher(
                onActivate: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, !self.isVPNRunning, !self.isSwitchingTunnel else { return }
                        self.tunnelStartedByAutoConnect = true
                        await self.startTunnel()
                        if self.isVPNRunning {
                            self.showToast(L("已随触发 App 自动连接"))
                        } else {
                            self.tunnelStartedByAutoConnect = false   // 没起来，别把后续手动会话误标
                        }
                    }
                },
                onDeactivate: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.tunnelStartedByAutoConnect, self.isVPNRunning else { return }
                        await self.stopTunnel()
                        self.showToast(L("触发 App 已全部退出，已自动断开"))
                    }
                }
            )
        }
        appLaunchWatcher?.start(triggers: settings.autoConnectApps)
    }
    #endif
}
