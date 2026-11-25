import Foundation
import NetworkExtension
import struct SwiftUI.Binding
import QingzhouCore
import QingzhouProtocols

extension AppState {
    // MARK: - VPN 隧道

    /// 给 UI Toggle 用的 Binding：set 时异步启停 tunnel，并把 isVPNRunning 同步成实际状态。
    /// get 在热切换窗口内返回 false —— 开关跟真实隧道状态走（切换期间确实断着）。
    public var vpnRunningBinding: Binding<Bool> {
        Binding(
            get: { self.isVPNRunning && !self.isSwitchingTunnel },
            set: { newValue in
                Task { @MainActor in
                    if newValue {
                        await self.startTunnel()
                    } else {
                        await self.stopTunnel()
                    }
                }
            }
        )
    }

    /// 启动时采认已在跑的隧道：隧道扩展是独立进程，主 App 被杀重开 / 替换安装后它照常
    /// 转发流量，但本进程的 isVPNRunning 初值是 false —— 开关会错误显示「关闭」。
    /// 这里 load 系统 VPN 配置、按真实 NEVPNStatus 回填。只在启动路径跑一次（幂等）；
    /// 本进程内的启停由各自流程维护，不受影响。
    func adoptRunningTunnelState() async {
        guard !isVPNRunning, !isSwitchingTunnel else { return }
        try? await tunnelManager.load()
        guard Self.isTunnelActive(tunnelManager.status) else { return }
        isVPNRunning = true
        // 会话起点 / 定时截止由轮询从 App Group 会话标记回填。本进程没有 start 记录，
        // 放宽 lastTunnelStartAt 下限：标记 stoppedAt == nil 且系统状态确为连接，标记可信。
        tunnelSession.adoptRunningSession()
        scheduleIPRefresh()
        logger.info("Adopted running tunnel from system (status: \(tunnelManager.status.description))", category: "tunnel")
        #if DEBUG
        AcceptanceTrace.record(.adopted)
        #endif
    }

    /// 监听系统 VPN 状态：小组件 / 系统设置 / 快捷指令在 App 之外把隧道开关了，
    /// `isVPNRunning` 也要跟着变 —— 否则用户从小组件开了 VPN 回到 App，开关还显示「关」。
    /// adoptRunningTunnelState 只在启动跑一次，覆盖不到「运行期被外部改动」，故补这条实时通道。
    func startObservingVPNStatus() async {
        guard vpnStatusObserver == nil else { return }
        // load 一次拿到 connection，之后系统会对它 post NEVPNStatusDidChange。
        try? await tunnelManager.load()
        reconcileVPNStatusFromSystem()
        vpnStatusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileVPNStatusFromSystem() }
        }
    }

    func stopObservingVPNStatus() {
        if let vpnStatusObserver {
            NotificationCenter.default.removeObserver(vpnStatusObserver)
            self.vpnStatusObserver = nil
        }
    }

    func reconcileVPNStatusFromSystem() {
        reconcileVPNStatus(with: tunnelManager.status)
    }

    /// 把 isVPNRunning 对齐到给定的系统 NEVPNStatus。热切换窗口内不动（那期间由
    /// performReapply 自己维护状态，stop→start 的中间态不能被误读成「用户关了 VPN」）。
    /// status 作参数注入 —— 决策表可单测（真实 NEVPNStatus 来自不可构造的系统 connection）。
    func reconcileVPNStatus(with status: NEVPNStatus) {
        guard !isSwitchingTunnel else { return }
        if Self.isTunnelActive(status), !isVPNRunning {
            isVPNRunning = true
            if lastTunnelStartAt == nil { tunnelSession.adoptRunningSession() }
            scheduleIPRefresh()
            logger.info("VPN status synced from system: running (\(status.description))", category: "tunnel")
        } else if isVPNRunning, status == .disconnected || status == .invalid {
            // 只在终态翻「关」，.disconnecting 等瞬态不动，避免开关闪烁
            isVPNRunning = false
            logger.info("VPN status synced from system: stopped", category: "tunnel")
            #if os(macOS)
            // 跟随出口地区：断开即还原系统时区（guard 会读指令并还原到原时区）
            if settings.followExitRegion {
                requestSystemTimeZone(nil)
            }
            #endif
        }
    }

    /// NEVPNStatus 里算「隧道在跑」的状态（含建立中 / 网络切换重连中）。
    static func isTunnelActive(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }

    /// 启动 tunnel。捕获所有错误写到 `tunnelError`，UI 弹 alert。
    ///
    /// 流程：
    /// 1. 当前节点 → share link 字符串（via `NodeEncoder.shareLink`，纯 Swift）
    /// 2. 把 share link + proxyMode 通过 providerConfiguration 传给 Extension
    /// 3. Extension 自己跑 libXray.ConvertShareLinksToXrayJson + XrayConfigComposer.compose
    ///    把 share link 展开成完整 xray 配置 —— 主 App 因此不需要 link LibXray.xcframework，
    ///    启动不会被 85 MB Go runtime 拖慢。
    /// 计算当前隧道目标节点对应的有效 `blockQUIC`：分流方案激活时以 `splitExitNode`（海外出口）为准，
    /// 普通模式以 `normalNode`（`currentNode`）为准。
    func effectiveBlockQUICForTunnel(normalNode: Node?, splitExitNode: Node?) -> Bool {
        (splitExitNode ?? normalNode).map { effectiveBlockQUIC(for: $0) } ?? false
    }

    #if os(macOS)
    /// 断网开关的 root 中继（仅 macOS）。开关打开但读不到凭据时**拒绝连接 / 中止重连**而不是静默降级 ——
    /// 静默降级会让用户以为"正在经中继出网"，然后一开 pf 就整机断网，且看不出原因。
    /// `stopOnFailure == true`（首次启动）同步把 `isVPNRunning` 置回 `false`；
    /// `stopOnFailure == false`（热重连）保持 `isVPNRunning` 不变，留住当前健康隧道。
    private func resolveGuardRelayCredentials(
        isSplitExitActive: Bool,
        stopOnFailure: Bool
    ) -> (ok: Bool, credentials: GuardRelayCredentials?) {
        guard isSplitExitActive, settings.guardRelayEnabled else {
            return (true, nil)
        }
        guard let creds = loadGuardRelayCredentials() else {
            tunnelError = L("已开启「经 root 中继出网」，但读不到中继凭据。先安装 guard：sudo sh Tools/qingzhou-guard/install.sh")
            if stopOnFailure {
                isVPNRunning = false
            }
            logger.error("Guard relay enabled but credentials missing", category: "tunnel")
            return (false, nil)
        }
        return (true, creds)
    }
    #endif

    public func startTunnel() async {
        // 截图 demo：模拟器没有 NE，真启动必失败弹错 → 只翻状态位维持「已连接」观感
        if ScreenshotDemoMode.isActive {
            isVPNRunning = true
            tunnelError = nil
            return
        }
        #if os(macOS)
        // 分流方案：出口和跳板都必须在，缺一个就**不连**而不是退回单节点 ——
        // 缺跳板的住宅代理只能从本机直连（国内连不上 + 暴露真实 IP），
        // 缺出口则等于没有海外出口。两种都不是用户要的状态，报清楚让它停在这儿。
        if let blocked = splitExitBlockedReason {
            tunnelError = blocked
            isVPNRunning = false
            logger.error("Split exit blocked: \(blocked)", category: "tunnel")
            return
        }
        let splitExitActive = settings.splitExitEnabled
        let exitNode = splitExitActive ? splitExitExitNode : nil
        let hopNode = splitExitActive ? splitExitHopNode : nil
        let splitExitPolicyGroups = splitExitActive ? settings.splitExitPolicyGroups : []
        let guardResult = resolveGuardRelayCredentials(isSplitExitActive: splitExitActive, stopOnFailure: true)
        guard guardResult.ok else { return }
        let guardRelay = guardResult.credentials
        #else
        let splitExitActive = false
        let exitNode: Node? = nil
        let hopNode: Node? = nil
        let guardRelay: GuardRelayCredentials? = nil
        let splitExitPolicyGroups: [SplitExitPolicyGroup] = []
        #endif
        let node = settings.proxyMode == .direct ? nil : currentNode
        guard settings.proxyMode == .direct || node != nil || splitExitActive else {
            tunnelError = VPNTunnelManager.TunnelError.noCurrentNode.errorDescription
            isVPNRunning = false
            return
        }
        let link = node.flatMap(NodeEncoder.shareLink)
        guard settings.proxyMode == .direct || link != nil || splitExitActive else {
            tunnelError = L("无法把节点编码成分享链接")
            isVPNRunning = false
            return
        }
        let shareLink = link ?? ""
        let effBlockQUIC = effectiveBlockQUICForTunnel(normalNode: node, splitExitNode: exitNode)
        do {
            // description 带节点名，方便用户在「系统设置 → 网络 → VPN」里识别
            try await tunnelManager.configure(
                node: exitNode ?? node,
                mode: settings.proxyMode,
                shareLink: shareLink,
                rules: effectiveUserRules,
                autoStopSeconds: settings.autoStopSeconds,
                blockQUIC: effBlockQUIC,
                description: L("轻舟 · \((exitNode?.name ?? node?.name ?? L("直连")))"),
                splitExitExit: exitNode,
                splitExitHop: hopNode,
                guardRelay: guardRelay,
                splitExitPolicyGroups: splitExitPolicyGroups
            )
            try await tunnelManager.start()
            activeTrafficSessionID = nil
            tunnelSession.startSubmitted(at: Date(), requestID: tunnelManager.configuredRequestID)
            isVPNRunning = true
            tunnelError = nil
            logger.info("Tunnel started for node \((exitNode?.name ?? node?.name ?? L("直连")))", category: "tunnel")
            #if DEBUG
            AcceptanceTrace.record(.startSubmitted)
            #endif
            if settings.autoStopSeconds > 0 {
                showToast(L("已开启定时：\(AutoStopPresets.label(for: settings.autoStopSeconds))后自动断开"))
            }
            syncLiveActivity()    // 起灵动岛/锁屏实时活动（设置开 + iOS 才实际生效）
            scheduleIPRefresh()   // 隧道生效后刷新公网 IP → 落到「节点出口」那栏
            watchTunnelStartFailure()   // 扩展启动失败（配置错误等）→ 把可读原因端给用户
            // 冲突防呆：系统代理（Clash 等）开着会在轻舟之前劫走流量 → 部分 App 联不上。
            // 只读检测、不改系统设置，检出就提示用户去关掉系统代理。
            if let warn = SystemProxyChecker.conflictWarning() {
                logger.warn(warn, category: "tunnel")
                showToast(warn)
            }
        } catch {
            isVPNRunning = false
            tunnelError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            logger.error("Tunnel start failed: \(tunnelError ?? "?")", category: "tunnel")
            // 连接失败干净收尾：configure() 里已开 On-Demand，若不关掉它会拿着坏配置反复重连；
            // 再 stop() 释放可能半开的隧道，让系统回收 TUN / 路由，避免"半死状态卡住全网"。
            try? await tunnelManager.setOnDemandEnabled(false)
            tunnelManager.stop()
        }
    }

    /// 启动后的失败哨兵：`startVPNTunnel()` 只表示「启动请求已提交」，扩展里 xray 配置
    /// 构建失败 / 起不来时 NE **不会**把错误回给主 App，只是状态默默回到 disconnected ——
    /// 这就是「配置错误只能看日志」的根因。这里轮询启动窗口：连上了收工；断开了就用
    /// `fetchLastDisconnectError`（iOS 16+/macOS 13+，系统会保存扩展 completionHandler
    /// 带回的错误）把可读原因端上 UI。
    private func watchTunnelStartFailure() {
        Task { @MainActor [weak self] in
            // 先给 1 秒缓冲：start 刚提交时状态还可能停留在 disconnected，别误判。
            try? await Task.sleep(for: .seconds(1))
            for _ in 0..<40 {   // 最多观察 ~20 秒（规则模式加载 geo 就要几秒）
                guard let self, self.isVPNRunning, !self.isSwitchingTunnel else { return }
                let status = self.tunnelManager.status
                if status == .connected {
                    self.syncAppliedConfiguration(session: AppGroupStorage.read(
                        TunnelSessionInfo.self, from: "tunnel-session"), status: status)
                    self.verifyTunnelConnectivity()
                    return
                }
                if status == .disconnected || status == .invalid {
                    let reason = await self.tunnelManager.lastDisconnectError()
                    self.isVPNRunning = false
                    self.connectedSince = nil
                    self.tunnelError = L("VPN 启动失败：\(reason ?? L("扩展未报告原因，可在设置→日志查看"))")
                    self.logger.error("Tunnel start failed after submit: \(reason ?? "unknown")", category: "tunnel")
                    // 与 startTunnel 失败路径同款收尾：防 On-Demand 拿坏配置反复重连。
                    try? await self.tunnelManager.setOnDemandEnabled(false)
                    self.tunnelManager.stop()
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// 隧道连上后的连通性哨兵。补配置预检的盲区：**配置合法 ≠ 节点可用** ——
    /// 密码错误的 trojan / 已下线的节点，xray 照样正常启动、系统显示「已连接」，
    /// 但所有代理流量石沉大海（trojan 等协议的服务端不回「认证失败」，只是静默丢弃）。
    /// 连上后真实访问一次 generate_204（此刻流量经隧道），两次都失败 → 明确告诉用户
    /// 「连上了但没网」+ 排查建议，别让人对着绿开关干瞪眼（真机验收打回的场景）。
    ///
    /// 直连模式不探测：没有代理链路，墙内访问 google 本来就通不了，会误报。
    private func verifyTunnelConnectivity() {
        guard let applied = appliedTunnelConfiguration, applied.mode != .direct else { return }
        // 并行跑一次 QUIC/HTTP3 实测（仅 auto + hysteria2 + 当前放行 QUIC 时）——
        // 与下面的通用连通性哨兵各自独立。
        probeQUICForCurrentNodeIfNeeded()
        let preferred = settings.proxiedTestTarget
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))   // 给 xray 出站起身时间，降低刚建链的误报
            guard let self, self.isVPNRunning, !self.isSwitchingTunnel, self.appliedTunnelConfiguration?.id == applied.id else { return }
            // 多目标：任一通过即算联网。一个节点出口 reset Google 却能到 Cloudflare 是好节点，
            // 单点探测（旧实现只打 google/generate_204）会把这种节点误判成「无法访问外网」。
            for attempt in 0..<2 {
                if await Self.probeTunnelConnectivity(preferred: preferred) {
                    self.logger.info("Connectivity probe OK", category: "tunnel")
                    return
                }
                if attempt == 0 { try? await Task.sleep(for: .seconds(3)) }
                guard self.isVPNRunning, !self.isSwitchingTunnel, self.appliedTunnelConfiguration?.id == applied.id else { return }
            }
            self.tunnelError = L("VPN 已连接，但多个探测目标（Cloudflare / Apple / Google）都访问不通，当前节点可能已失效或凭据错误。若你确认能正常上网，可能只是探测站点被临时阻断——可在设置→测速里换个探测目标，或直接换节点。")
            self.logger.error("Connectivity probe failed on all targets after tunnel connected", category: "tunnel")
        }
    }

    /// 经隧道**并发**探测多个目标，任一返回 HTTP 响应即算联网（第一个成功即返回）。
    /// 并发而非串行：好节点里任一目标秒回即通过；真坏节点则所有目标一起超时，
    /// 整轮耗时 = 单个超时（~8s）而非串行累加（4×8=32s）—— 坏节点检测从最长 64s 压到 ~16s。
    private static func probeTunnelConnectivity(preferred: String) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)
        let targets = ConnectivityProbe.sentinelTargets(preferred: preferred).compactMap { URL(string: $0) }
        guard !targets.isEmpty else { return false }
        return await withTaskGroup(of: Bool.self) { group in
            for url in targets {
                group.addTask {
                    if let (_, response) = try? await session.data(from: url) {
                        return response is HTTPURLResponse
                    }
                    return false
                }
            }
            for await ok in group where ok {
                group.cancelAll()   // 一个成功即取消其余，尽快返回
                return true
            }
            return false
        }
    }

    // MARK: - QUIC / HTTP3 实测探测（auto 策略下 hysteria2 节点的非对称修正）

    /// 连接 / 换节点后，对**放行着 QUIC 的 hysteria2 节点**实测 HTTP/3 是否真能跑。
    /// 跑不通（回退 h2/h1 或失败）说明该节点没转发 UDP → 标记该节点 QUIC 实测坏 +
    /// 触发一次整实例重配（reapplyRunningTunnel(.full)，让 routing 带上 blockQUIC=true）。
    ///
    /// 触发条件（三者全真才探）：quicPolicy==auto、当前节点是 hysteria2、当前**放行**着 QUIC
    /// （未标记坏）。其余情况（强制档 / TCP 基节点 / 已挡）都无需探测。见 docs/QUIC.md。
    private func probeQUICForCurrentNodeIfNeeded() {
        guard settings.quicPolicy == .auto,
              let applied = appliedTunnelConfiguration, !applied.blockQUIC,
              let node = runningNode,
              currentNode?.identityFingerprint == node.identityFingerprint, settings.proxyMode == applied.mode,
              node.protocolType == .hysteria2,
              !quicKnownBrokenNodes.contains(node.identityFingerprint) else { return }
        let fingerprint = node.identityFingerprint
        let nodeName = node.name
        let intent = selectionIntentGeneration
        // 观测态：新一轮实测开始，该节点回到「实测中」（纯显示，不影响探测/阻断本身）。
        quicProbePassedNodes.remove(fingerprint)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))   // 给 xray 出站起身时间，降低刚建链的误判
            // 探测期间用户可能换了节点 / 关了 VPN / 切了策略 —— 再确认一次前置条件仍成立。
            guard let self, self.isVPNRunning, !self.isSwitchingTunnel,
                  self.settings.quicPolicy == .auto,
                  self.selectionIntentGeneration == intent, self.appliedTunnelConfiguration?.id == applied.id,
                  self.runningNode?.identityFingerprint == fingerprint,
                  !self.quicKnownBrokenNodes.contains(fingerprint) else { return }
            let proto = await Self.probeHTTP3NegotiatedProtocol()
            guard self.settings.quicPolicy == .auto, self.selectionIntentGeneration == intent,
                  self.appliedTunnelConfiguration?.id == applied.id else { return }
            guard QUICProbeDecision.shouldMarkBroken(networkProtocolName: proto) else {
                self.logger.info("QUIC h3 probe OK on \(nodeName) (proto=\(proto ?? "nil")) — keeping QUIC allowed", category: "tunnel")
                // 观测态：仍是同一节点在跑才记「实测通过」（换节点竞态下探测流量走的已是新节点，
                // 结论不能记到旧指纹头上）。纯显示，不影响探测/阻断本身。
                if self.isVPNRunning, self.runningNode?.identityFingerprint == fingerprint {
                    self.quicProbePassedNodes.insert(fingerprint)
                }
                return
            }
            // 判坏。落地前再确认仍是同一节点、仍在跑（避免与用户操作竞态）。
            guard self.isVPNRunning, !self.isSwitchingTunnel,
                  self.runningNode?.identityFingerprint == fingerprint else { return }
            self.quicKnownBrokenNodes.insert(fingerprint)
            self.logger.warn("QUIC h3 probe failed (proto=\(proto ?? "nil")) on \(nodeName) — blocking QUIC + reconfigure", category: "tunnel")
            // 整实例重配：routing 会带上 blockQUIC=true（此刻 effectiveBlockQUIC 已返回 true）。
            await self.reapplyRunningTunnel(scope: .full)
        }
    }

    /// 用 URLSession 对已知 HTTP/3 端点发轻请求，返回**实际协商到的传输协议名**
    /// （h3 / h2 / http/1.1 / nil）。靠 `URLRequest.assumesHTTP3Capable`（iOS15+/macOS12+，
    /// 目标系统均可用）允许首个请求直接尝试 h3（无需先收 Alt-Svc），再从
    /// `URLSessionTaskMetrics.transactionMetrics.last?.networkProtocolName` 读回真正用上的协议。
    /// 多目标：任一目标协商到 h3 即证明该节点能转发 UDP → 立即返回 "h3"；都没 h3 才回退协议 / nil。
    private static func probeHTTP3NegotiatedProtocol() async -> String? {
        let targets = ["https://cloudflare-quic.com/", "https://www.google.com/generate_204"]
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var best: String?
        for urlString in targets {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.assumesHTTP3Capable = true   // 允许无 Alt-Svc 先验就尝试 h3
            let collector = HTTP3ProtocolCollector()
            _ = try? await session.data(for: request, delegate: collector)
            if let proto = collector.protocolName() {
                if proto == "h3" { return "h3" }   // 任一目标走上 h3 → UDP 转发可用，收工
                best = best ?? proto               // 记下首个非 h3 回退协议
            }
        }
        return best
    }

    /// URLSessionTaskDelegate：捕获最后一段 transaction 协商到的传输协议名。
    /// `didFinishCollecting` 在任务完成前于 delegate 队列回调，与 async data 的 await 之间用
    /// NSLock 护栏，`@unchecked Sendable` 手动保证线程安全（满足 Swift 6 严格并发）。
    private final class HTTP3ProtocolCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _protocolName: String?
        func protocolName() -> String? {
            lock.lock(); defer { lock.unlock() }
            return _protocolName
        }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didFinishCollecting metrics: URLSessionTaskMetrics) {
            lock.lock(); defer { lock.unlock() }
            _protocolName = metrics.transactionMetrics.last?.networkProtocolName
        }
    }

    public func stopTunnel() async {
        if ScreenshotDemoMode.isActive {   // 截图 demo：同 startTunnel
            isVPNRunning = false
            return
        }
        // ⚠️ 用户主动关 VPN：必须先关掉 On-Demand 并落盘，否则 On-Demand 的 connect 规则
        // 会在 stop() 之后立刻把隧道重连回来，用户永远关不掉。失败也继续 stop（尽力而为）。
        do {
            try await tunnelManager.setOnDemandEnabled(false)
        } catch {
            logger.warn("Disable on-demand before stop failed: \(error)", category: "tunnel")
        }
        tunnelManager.stop()
        isVPNRunning = false
        #if os(macOS)
        tunnelStartedByAutoConnect = false   // 会话结束，自动连的归属随之失效
        #endif
        autoStopDeadline = nil       // 手动关了，倒计时立即消失（不等下一秒轮询）
        connectedSince = nil         // 已连接时长同理，立即清零
        liveActivity.endAll()        // 结束灵动岛/锁屏实时活动
        markAllConnectionsClosed()   // 隧道停了，活跃连接全部立即归入「已关闭」
        scheduleIPRefresh()   // 隧道断开后刷新公网 IP → 落回「直连」那栏
    }

    /// 开关 VPN 后延迟刷新公网 IP：隧道建立/断开要几秒才生效，立即查会拿到旧出口。
    func scheduleIPRefresh() {
        ipRefreshTask?.cancel()
        ipRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { await self?.refreshPublicIPInfo() }
        }
    }

    /// 当前节点变了、且 VPN 正在运行时，热切换到新节点：重新写配置 + 断开重连。
    /// 这样自动择优 / 手动选节点能立即生效，不用用户手动关开 VPN 开关。
    ///
    /// 注：NetworkExtension 没有「热 reload 配置」的同步 API —— 改了 providerConfiguration
    /// 必须断开重连才生效。所以这里是 stop → 等连接断开 → start，会有短暂断流；
    /// 期间 isSwitchingTunnel = true，UI 开关滑到关 + 显示"切换中…"。
    ///
    /// 防抖：切换进行中再次调用只记 pending；当前轮收尾后发现 pending 就再跑一轮，
    /// 状态里已是最新节点/模式，自动收敛到用户的最终选择。
    public func reapplyRunningTunnel(scope: ReapplyScope = .full) async {
        if isSwitchingTunnel {
            // full 吞并 nodeOnly：窗口里叠加的请求按最重的执行，别丢模式/规则变更
            pendingReapplyScope = (scope == .full || pendingReapplyScope == .full) ? .full : .nodeOnly
            return
        }
        var next: ReapplyScope? = scope
        while let current = next {
            pendingReapplyScope = nil
            await performReapply(scope: current)
            next = pendingReapplyScope
        }
    }

    func performReapply(scope: ReapplyScope) async {
        guard isVPNRunning else { return }
        // Selecting a future proxy node does not change a direct tunnel.
        if scope == .nodeOnly && settings.proxyMode == .direct { return }
        #if os(macOS)
        // 分流方案生效时，出口不是"当前节点"，重连必须带上出口/跳板两个节点。
        // 少了它们，configure() 会把 providerConfiguration 里残留的分流字段清掉，
        // 下一次连接就悄悄退回单节点 —— 用户以为还在分流，其实已经直连住宅代理了。
        let split = activeSplitExit
        let splitExitPolicyGroups = split != nil ? settings.splitExitPolicyGroups : []
        let guardResult = resolveGuardRelayCredentials(isSplitExitActive: split != nil, stopOnFailure: false)
        guard guardResult.ok else { return }
        let guardRelay = guardResult.credentials
        #else
        let split: (exit: Node, hop: Node)? = nil
        let guardRelay: GuardRelayCredentials? = nil
        let splitExitPolicyGroups: [SplitExitPolicyGroup] = []
        #endif
        let node = settings.proxyMode == .direct ? nil : currentNode
        guard settings.proxyMode == .direct || node != nil || split != nil else {
            tunnelError = VPNTunnelManager.TunnelError.noCurrentNode.errorDescription
            return
        }
        let link = node.flatMap(NodeEncoder.shareLink)
        guard settings.proxyMode == .direct || link != nil || split != nil else { return }
        let shareLink = link ?? ""
        #if DEBUG
        AcceptanceTrace.record(scope == .full ? .reapplyFullStarted : .reapplyNodeStarted)
        #endif
        let mode = settings.proxyMode
        let rules = effectiveUserRules
        let autoStopSeconds = settings.autoStopSeconds
        isSwitchingTunnel = true
        // 热切换里 isVPNRunning 不变但节点（providerConfiguration 里的节点名）变了 ——
        // 退出时踢一次小组件刷新，别让 widget 上的节点名停留在旧值。
        defer {
            isSwitchingTunnel = false
            WidgetRefresher.reload()
        }
        // 新节点在当前 QUIC 策略下的有效阻断值（分流方案取出口节点）。
        let effBlockQUIC = effectiveBlockQUICForTunnel(normalNode: node, splitExitNode: split?.exit)
        // 配置预检：趁旧隧道还在跑，先让扩展用同款构建流程校验新节点的配置（libXray
        // TestXray）。配置非法 → 不拆在跑的隧道，直接报错返回 —— 否则坏配置会把好隧道
        // 换成起不来的新会话，用户直接断网。预检本身没跑成（超时等）不拦：尽力而为继续切。
        do {
            try await tunnelManager.testNodeConfig(
                node: node,
                mode: mode,
                shareLink: shareLink,
                rules: rules,
                blockQUIC: effBlockQUIC,
                splitExit: split != nil,
                splitExitExit: split?.exit,
                splitExitHop: split?.hop,
                guardRelay: guardRelay,
                splitExitPolicyGroups: splitExitPolicyGroups
            )
        } catch VPNTunnelManager.TunnelError.configRejected(let reason) {
            tunnelError = L("已保持当前节点连接不变。切换目标节点配置无效：\(reason)")
            logger.error("Pre-switch config test rejected \((split?.exit.name ?? node?.name ?? L("直连"))): \(reason)", category: "tunnel")
            return   // 旧隧道原样保留
        } catch {
            logger.warn("Pre-switch config test unavailable (\(error)) — continuing switch", category: "tunnel")
        }
        // 快路径：只换节点（mode / 规则没变）时先试扩展内原地换出口（libXray
        // SwitchOutbound 热替换 "proxy" handler）—— 隧道 / TUN / 路由 / DNS 全不动，
        // 零断流、系统 VPN 图标不闪。任何失败（xray 没在跑 / 节点构建失败 / 扩展
        // 超时）都回退到下面的全量重启，原安全网不变。
        //
        // ⚠️ 但原地换出口**不重建 routing** —— 若新节点有效阻断值与当前隧道 routing 所用的
        // （扩展确认的blockQUIC）不一致（如 trojan[挡]→hysteria2[放行]，或反向），原地切会留下
        // 过期的 QUIC 路由。此时降级为全量重启（下方路径重建 routing）。一致时才走零断流快路径。
        if scope == .nodeOnly, split == nil, let node, let applied = appliedTunnelConfiguration,
           applied.mode == mode, applied.blockQUIC == effBlockQUIC {
            do {
                // 先落盘新节点配置：扩展若之后被系统回收再由 On-Demand 拉起，用的是
                // providerConfiguration —— 不落盘会复活成旧节点。saveToPreferences
                // 不打扰运行中的隧道。
                try await tunnelManager.configure(
                    node: node,
                    mode: mode,
                    shareLink: shareLink,
                    rules: rules,
                    // 原地切换 = 同一会话延续：定时倒计时不重置（扩展侧计时器没动）
                    autoStopSeconds: autoStopSeconds,
                    blockQUIC: effBlockQUIC,   // == applied.blockQUIC，routing 无需变
                    description: L("轻舟 · \(node.name)"),
                    splitExitExit: split?.exit,
                    splitExitHop: split?.hop
                )
                let confirmedID = try await tunnelManager.switchNodeInPlace(node: node, shareLink: shareLink)
                recordAppliedAcknowledgement(confirmedID)
                tunnelSession.expectRequest(tunnelManager.configuredRequestID)
                syncAppliedConfiguration(session: AppGroupStorage.read(
                    TunnelSessionInfo.self, from: "tunnel-session"), status: tunnelManager.status)
                markAllConnectionsClosed()   // 旧 handler 已关，旧代理连接全部终止
                verifyTunnelConnectivity()   // 新节点未必真可用，哨兵照跑
                logger.info("In-place switched outbound to \(node.name) — tunnel kept alive", category: "tunnel")
                #if DEBUG
                AcceptanceTrace.record(.inPlaceSwitch)
                #endif
                return
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                logger.warn("In-place switch failed (\(reason)) — falling back to full restart", category: "tunnel")
            }
        }
        // ⚠️ 原地无感重配（reconfigureInPlace + 扩展 handleAppMessage）暂时禁用 —— 实测在
        // 某些切换（规则→全局）上会让 xray 卡死、之后连全量重启都救不回来，疑似 xray-core
        // 在同一扩展进程内 stop→run 有全局状态没干净复位。扩展侧代码保留待查，这里先走全量重启。
        do {
            try await tunnelManager.configure(
                node: split?.exit ?? node,
                mode: mode,
                shareLink: shareLink,
                rules: rules,
                // 热切换 = 全量重启 = 新会话：定时按设置的时长**重新计时**（切节点/模式后
                // 从头再数）。不带旧剩余时间过去 —— 语义简单、扩展侧无需额外状态。
                autoStopSeconds: autoStopSeconds,
                blockQUIC: effBlockQUIC,   // 全量重启会重建 routing，带上新有效阻断值
                description: L("轻舟 · \((split?.exit.name ?? node?.name ?? L("直连")))"),
                splitExitExit: split?.exit,
                splitExitHop: split?.hop,
                guardRelay: guardRelay,
                splitExitPolicyGroups: splitExitPolicyGroups
            )
            // 切换窗口先关 On-Demand 再 stop：connect 规则匹配所有流量，stop 后系统
            // 会被任意流量触发抢跑重连 —— 复用半死的旧扩展进程（正是下面轮询要避免的
            // xray 卡死场景），还可能多出一次肉眼可见的假启停。成功 start 后再按
            // configure 的同一规则恢复（定时会话不开）。失败不拦：尽力而为继续切。
            try? await tunnelManager.setOnDemandEnabled(false)
            tunnelManager.stop()
            markAllConnectionsClosed()   // 热切换 = 旧隧道进程整个换掉，旧连接全部已死
            // 等扩展进程**完全断开**再重启 —— 只 sleep 300ms 常常旧进程还没退，start() 复用了
            // 半死的旧进程，xray 在里面 stop→run 状态不干净就会卡死/不通。轮询到 .disconnected
            // （最多 5 秒）确保拿到全新扩展进程（全新 Go runtime + 全新 xray），像首次连接一样干净。
            for _ in 0..<50 {
                if tunnelManager.status == .disconnected { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try await tunnelManager.start()
            activeTrafficSessionID = nil
            tunnelSession.startSubmitted(at: Date(), requestID: tunnelManager.configuredRequestID)
            // start() 只等"启动请求提交成功"，不等隧道真连上 —— 到这里就收窗口的话，
            // 开关会在 xray 还没就绪时就滑回"开"（规则模式加载 geo 那几秒尤其明显）。
            // 继续轮询到 .connected 再结束"切换中"，动画的结束沿才真正跟着真实状态走。
            // 15 秒超时兜底：连不上也先收窗口，不把 UI 卡死在切换态（错误自会走系统 VPN 状态）。
            for _ in 0..<150 {
                if tunnelManager.status == .connected { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard tunnelManager.status == .connected else {
                throw VPNTunnelManager.TunnelError.underlying(NSError(
                    domain: "qingzhou.tunnel", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: L("隧道切换未能在规定时间内连接")]))
            }
            syncAppliedConfiguration(session: AppGroupStorage.read(
                TunnelSessionInfo.self, from: "tunnel-session"), status: tunnelManager.status)
            // 恢复 On-Demand（与 configure 同一规则：定时会话不开）—— 切换窗口结束，
            // 扩展再被系统回收时仍能自动重连。
            if autoStopSeconds <= 0 {
                try? await tunnelManager.setOnDemandEnabled(true)
            }
            verifyTunnelConnectivity()   // 热切换后同样要哨兵：配置合法 ≠ 节点真的可用
            logger.info("Clean-restart switched tunnel to \((node?.name ?? L("直连"))) / \(mode.rawValue)", category: "tunnel")
            #if DEBUG
            AcceptanceTrace.record(.cleanRestart)
            #endif
        } catch {
            tunnelError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            logger.error("Hot-switch failed: \(tunnelError ?? "?")", category: "tunnel")
            // 隧道确实死了：开关诚实地留在关位（修掉旧行为——失败后开关仍显示"开"）。
            // 和 startTunnel 的失败路径一样干净收尾：关 On-Demand 防止拿坏配置反复重连，
            // 再 stop() 让系统回收 TUN / 路由。pending 也作废——VPN 已关，等用户重新开。
            isVPNRunning = false
            connectedSince = nil
            pendingReapplyScope = nil
            try? await tunnelManager.setOnDemandEnabled(false)
            tunnelManager.stop()
        }
    }
}
