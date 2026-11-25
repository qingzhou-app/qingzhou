import Foundation
import NetworkExtension
import QingzhouCore

extension AppState {
    // MARK: - 调度器

    /// 启动后台调度：根据设置定期跑自动择优 + 订阅刷新；同时启动示例连接产线（直到真隧道接入）。
    public func startSchedulers() {
        // 截图 demo 模式：一切后台调度短路（测速/择优会覆盖演示数据，adopt 会翻掉
        // 伪造的连接态，iCloud 检查可能弹恢复框），见 ScreenshotDemoMode。
        if ScreenshotDemoMode.isActive { return }
        stopSchedulers()
        measurementNetworkObserver.start { [weak self] in
            self?.measurementNetworkDidChange()
            self?.scheduleIPRefresh()
        }
        wireFailoverNotificationDelegate()   // 故障提醒：挂通知点击回调（幂等）
        #if os(macOS)
        // 「打开 App 自动连」监听器随 app 启动就位（之后由 settings 副作用保持同步）
        syncAppLaunchWatcher()
        #endif
        // 与系统实际 VPN 状态对齐：隧道扩展是独立进程，主 App 被杀重开（或替换安装）后
        // 它可能还在跑 —— isVPNRunning 初值 false 会让开关错误显示「关闭」，实际流量仍在代理。
        Task { @MainActor [weak self] in
            await self?.adoptRunningTunnelState()
            // 启动采认之后挂上实时监听：运行期小组件/系统设置/快捷指令改 VPN 也能同步回来
            await self?.startObservingVPNStatus()
        }
        // iCloud vault 启动检查（云端更新 → 提示恢复；无云端文档 → 镜像上去）
        Task { @MainActor [weak self] in
            await self?.runCloudVaultStartupCheck()
        }
        schedulerTask = Task { @MainActor [weak self] in
            await self?.schedulerLoop()
        }
        trafficPollingTask = Task { @MainActor [weak self] in
            await self?.trafficPollingLoop()
        }
        accessLogPollingTask = Task { @MainActor [weak self] in
            await self?.accessLogPollingLoop()
        }
        // App 内更新提醒：延后到首屏稳定后再静默查一次 App Store（未上架 / 失败都不打扰）。
        // 延迟是为了别和冷启动的其它网络请求（远程规则 / 公网 IP）抢带宽。
        updateCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.checkForAppUpdate()
        }
    }

    public func stopSchedulers() {
        measurementNetworkObserver.stop()
        stopObservingVPNStatus()
        schedulerTask?.cancel()
        schedulerTask = nil
        updateCheckTask?.cancel()
        updateCheckTask = nil
        trafficPollingTask?.cancel()
        trafficPollingTask = nil
        accessLogPollingTask?.cancel()
        accessLogPollingTask = nil
    }

    private func schedulerLoop() async {
        // 不要在启动瞬间跑 auto-select —— 它会对几十上百个节点并发 TCP 探测，
        // 抢主线程 + 网络 + UI 渲染。等 5 秒让 app 完成首屏。
        try? await Task.sleep(for: .seconds(5))
        if Task.isCancelled { return }

        #if os(macOS)
        let splitExitAtLaunch = settings.splitExitEnabled
        #else
        let splitExitAtLaunch = false
        #endif
        if !splitExitAtLaunch,
           settings.autoSelectTrigger == .onAppLaunch || settings.autoSelectTrigger == .onAppLaunchAndInterval {
            await autoSelectBestNode(origin: .scheduled)
        }
        var lastAutoSelect = Date()
        var lastMeasure = Date()
        var lastRefresh = Date()

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            if Task.isCancelled { break }

            let now = Date()

            // 择优包含测速；同一拍两者都到期时只做择优，避免预算被翻倍。
            let measureInterval = settings.autoMeasureIntervalSeconds
            let trigger = settings.autoSelectTrigger
            // 分流方案的出口是手选的，自动择优会把 currentNodeId 改掉、进而把出口也换掉 ——
            // 那就成了「自动换节点」，与「手选、挂了就断」直接冲突。开着分流时跳过择优。
            #if os(macOS)
            let splitExitInLoop = settings.splitExitEnabled
            #else
            let splitExitInLoop = false
            #endif
            if !splitExitInLoop,
               (trigger == .interval || trigger == .onAppLaunchAndInterval)
                && now.timeIntervalSince(lastAutoSelect) >= settings.autoSelectIntervalSeconds {
                await autoSelectBestNode(origin: .scheduled)
                lastAutoSelect = Date()
                lastMeasure = lastAutoSelect
            } else if measureInterval > 0 && now.timeIntervalSince(lastMeasure) >= measureInterval {
                await measureAllNodes(origin: .scheduled)
                lastMeasure = Date()
            }

            // 3) 自动订阅刷新
            let refreshInterval = settings.subscriptionRefreshIntervalSeconds
            if refreshInterval > 0 && now.timeIntervalSince(lastRefresh) >= refreshInterval {
                for sub in subscriptions {
                    await refreshSubscription(sub)
                }
                lastRefresh = Date()
            }

            #if os(macOS)
            // 4) 分流方案的国内名单：24 小时一次（内部自己节流，失败也记时间，不刷屏重试）
            if settings.splitExitEnabled {
                await refreshSplitExitListsIfDue()
            }
            #endif
        }
    }

    /// 每 2 秒增量读 App Group 里 xray 写的 access log，解析成真实连接。
    /// 替代了早期的示例连接产线 —— 现在「连接」页和「域名分析」都吃真实数据。
    private func accessLogPollingLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { break }
            // 先刷新 appex 写的「假 IP → 域名」映射，ingestAccessLog 才能把 198.18.x.x 翻回域名
            if let map = AppGroupStorage.read([String: String].self, from: "fakedns-map") {
                fakeDNSMap = map
            }
            // 核心摄入永远先跑 —— 来源 App 标注只是可选增强，它的 XPC 绝不能阻塞连接列表。
            // （踩过的坑：filter 扩展关闭时 XPC await 悬死，循环卡在第一轮，连接页恒空。
            //   ⚠️ merge 时别把 ingestAccessLog 挪回 XPC 之后，这个顺序丢过一次。）
            ingestAccessLog()
            // 回翻：连接常在 map 落盘（appex 每秒才写一次）之前就被 ingest，只在解析那刻
            // 查一次会让这批连接永远顶着裸 IP（按域名搜不到、开「忽略 IP」时整行被藏）。
            backfillDomainNames()
            // 「仅 IPv6」标注：对新出现的域名后台查一次真实 A/AAAA（DoH 绕开 fakedns
            // 假 IP）。只有 AAAA 的站点需要 IPv6 网络 —— 打标 + 记日志，
            // 用户遇到时连接页能看懂原因（docs/IPV6.md）。
            probeIPv6OnlyCandidates()
            #if os(macOS)
            // 来源 App 标注开启时才走 XPC + 回填（FilterControlClient 带 2 秒超时兜底）。
            if FeatureFlags.sourceAppLabeling {
                // content filter 扩展（root）经 XPC 提供端口→App 映射；没启用/连不上则保持上次的值。
                let fetched = await filterControl.fetchPortMap()
                if let fetched {
                    sourceAppMap = SourceAppMap(raw: fetched)
                }
                // 回填：连接常在 XPC map 就绪前就已 ingest（sourceApp=nil），每轮用最新 map
                // 把已存在连接的来源 App 补上，否则只有「解析那一刻」端口在 map 里的才有标注。
                backfillSourceApps()
            }
            #endif
            // 停止浏览后 ingest 不再产出批次，这里兜底把最后的脏数据补写掉
            flushDomainHistoryIfNeeded()
            flushRuleHitStatsIfNeeded()
            flushNodeMetricsIfNeeded()
        }
    }

    /// 每秒读 App Group 里 appex 上报的真实流量统计，喂进波形。
    ///
    /// **靠数据新鲜度驱动，不靠 isVPNRunning** —— 杀掉 App 重启后 VPN 扩展还在跑、但主 App 的
    /// isVPNRunning 默认是 false，若用它当闸门波形会一直空。改为：只要读到新鲜样本就画；
    /// 连续几秒读不到新鲜数据（VPN 停了或没上报）才清空波形。
    private func trafficPollingLoop() async {
        var staleSeconds = 0
        // 小组件刷新的权威触发器：NEVPNStatus 每一次**真实跃迁**（connecting→connected、
        // disconnecting→disconnected…）都踢一脚 WidgetKit。只盯 isVPNRunning 不够——
        // 开 VPN 时它在「提交」瞬间就翻 true（那一刻还是 connecting），隧道真正 connected
        // 时没有任何事件再刷，widget 会永远停在「切换中」（真机踩过）。
        var lastWidgetStatus = tunnelManager.status
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { break }
            let status = tunnelManager.status
            if status != lastWidgetStatus {
                lastWidgetStatus = status
                WidgetRefresher.reload()
                logger.debug("NEVPNStatus → \(status.description)，已触发小组件刷新", category: "widget")
            }
            if Date().timeIntervalSince(domainTrafficReadAt) >= 10 {
                domainTrafficReadAt = Date()
                await refreshDomainTrafficHistory()
            }
            expireBandwidthObservations()
            syncAutoStopState()   // 定时关闭：刷新倒计时 + 识别「扩展已按定时自停」
            syncTunnelMemory()    // 扩展内存观测：读快照 + 新增告警转写进主 App 日志
            // "traffic-stats" 必须与 XrayCore.TunnelAppGroup.trafficStatsName 一致（两模块互不依赖）
            if let stats = AppGroupStorage.read(TrafficStats.self, from: "traffic-stats"),
               abs(stats.sampledAt.timeIntervalSinceNow) <= 3 {   // 只接受新鲜样本，避免旧文件
                ingestTrafficStats(stats)
                staleSeconds = 0
            } else {
                staleSeconds += 1
                if staleSeconds >= 5, !trafficHistory.samples.isEmpty {
                    trafficHistory.clear()   // 连续 5 秒没新数据 → VPN 停了，清空波形
                    // VPN 不是从本 App 关的（系统设置里关 / 扩展崩溃）也走这里 —— 一并关掉连接
                    markAllConnectionsClosed()
                }
            }
            syncLiveActivity()    // 先让新心跳校验配置身份，再展示实际节点。
            syncNodeHealth()
            // xray per-outbound 拆分（代理/直连占比）。扩展每 2 秒写一次，5 秒新鲜窗口；
            // 过期（VPN 停了 / 本会话没开 metrics）就收起，不显示残留数据。
            // "xray-stats" 与 XrayCore.TunnelAppGroup.xrayStatsName 一致（两模块互不依赖）。
            if let xs = AppGroupStorage.read(XrayOutboundStats.self, from: "xray-stats"),
               abs(xs.sampledAt.timeIntervalSinceNow) <= 5 {
                ingestXrayOutboundStats(xs)
            } else if outboundStats != nil {
                outboundStats = nil
            }
        }
    }
}
