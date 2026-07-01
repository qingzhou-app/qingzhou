import Foundation
import Observation
// 不全量 `import SwiftUI` —— SwiftUI 里也有一个叫 Settings 的类型（用于 Settings scene），
// 会和我们的 QingzhouCore.Settings 冲突。只 import 需要的 Binding 类型。
import struct SwiftUI.Binding
import QingzhouCore
import QingzhouProtocols
import QingzhouSubscription
import QingzhouRules
import QingzhouSpeedTest
import QingzhouLogging

/// 应用顶层状态容器。UI 通过 @Bindable 直接读 / 写；所有写入都会自动持久化。
///
/// 设计要点：
/// - `@MainActor` 限定：所有读 / 写都在主线程，避免后台线程改 UI 状态导致 SwiftUI 抱怨。
/// - 服务（Logger / SubscriptionFetcher / NodeSelector）通过初始化注入，便于测试替换。
/// - 调度器（auto-select / auto-refresh / sample-connections）在 `start()` 里起 Task；
///   `stop()` 时取消。生命周期由 app 入口管理。
@MainActor
@Observable
public final class AppState {
    public var subscriptions: [Subscription] = []
    public var nodes: [Node] = []
    public var currentNodeId: UUID?
    public var customRules: [Rule] = []
    public var remoteRules: [Rule] = []
    public var connections: [Connection] = []
    /// 实时流量波形数据（滑动窗口）。appex 经 App Group 上报 `TrafficStats` 喂进来；
    /// 没开 VPN / 没真实上报时为空，UI 显示「等待流量」。
    public var trafficHistory = TrafficHistory(capacity: 60)
    public var settings: Settings = Settings()
    public var lastSpeedTestReport: SpeedTestReport?
    /// 正在测速的节点 id 集合 —— UI 据此在对应行显示旋转 loading。
    public var measuringNodeIds: Set<UUID> = []
    public var isVPNRunning: Bool = false
    /// VPN 启停最近一次错误（拿不到 entitlement / 配置失败等）。UI 用 alert 展示。
    public var tunnelError: String?
    /// 当前 xray-core 版本。由 app 入口注入（QingzhouApp 库本身不依赖 XrayCore，避免拖进 380MB xcframework）。
    public var coreVersion: String?

    /// 公网 IP / 地理信息，由 NetworkInfoService 异步填充。
    public var publicIPInfo: PublicIPInfo?
    /// 不走 VPN 的出口 IP（VPN 关闭时查询到，缓存展示）。
    public var directIPInfo: PublicIPInfo?
    /// 走 VPN / 节点出口的 IP（VPN 开启时查询到）。
    public var proxyIPInfo: PublicIPInfo?
    /// 远程规则源最近一次拉取时间 / 错误。
    public var remoteRulesStatus: RemoteFetchStatus = .idle
    /// 订阅最近一次刷新错误（按 id 索引），仅保留最近一条错误信息。
    public var subscriptionErrors: [UUID: String] = [:]
    /// 轻量 toast 文案（自动择优、订阅添加等非阻塞反馈）。UI 浮层显示，几秒自动消失。
    public var toast: String?

    public let logger: Logger
    public let subscriptionFetcher: SubscriptionFetcher
    public let nodeSelector: NodeSelector
    public let speedTestRunner: SpeedTestRunner
    public let persistence: Persistence
    public let tunnelManager: VPNTunnelManager

    private var schedulerTask: Task<Void, Never>?
    private var trafficPollingTask: Task<Void, Never>?
    private var accessLogPollingTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var ipRefreshTask: Task<Void, Never>?
    /// access log 文件已读到的字节位置（增量读，不重复解析）。
    private var accessLogOffset: UInt64 = 0
    /// appex 写的「假 IP → 域名」映射（FakeDNS），把 access log 的 198.18.x.x 翻回域名。
    private var fakeDNSMap: [String: String] = [:]
    /// content filter 扩展提供的「源端口 → 来源 App bundle id」（仅 macOS）。
    private var sourceAppMap: [String: String] = [:]
    #if os(macOS)
    /// 内容过滤扩展以 root 运行，App Group 文件与用户 App 不通，故通过 XPC 查询端口→App 映射。
    private let filterControl = FilterControlClient()
    #endif

    public init(
        logger: Logger = Logger(),
        persistence: Persistence = Persistence(directory: Persistence.defaultDirectory()),
        subscriptionFetcher: SubscriptionFetcher? = nil,
        nodeSelector: NodeSelector? = nil,
        speedTestRunner: SpeedTestRunner? = nil,
        tunnelManager: VPNTunnelManager? = nil
    ) {
        self.logger = logger
        self.persistence = persistence
        self.subscriptionFetcher = subscriptionFetcher ?? SubscriptionFetcher(logger: logger)
        self.nodeSelector = nodeSelector ?? NodeSelector(logger: logger)
        self.speedTestRunner = speedTestRunner ?? SpeedTestRunner(logger: logger)
        self.tunnelManager = tunnelManager ?? VPNTunnelManager(logger: logger)

        let snapshot = persistence.loadSnapshot()
        self.subscriptions = snapshot.subscriptions
        self.nodes = snapshot.nodes
        self.customRules = snapshot.customRules
        self.settings = snapshot.settings
        self.currentNodeId = snapshot.currentNodeId
        logger.info(
            "AppState restored: \(subscriptions.count) subs, \(nodes.count) nodes, \(customRules.count) custom rules",
            category: "app"
        )
        logger.setMinimumLevel(LogLevel(rawValue: settings.logLevel) ?? .info)
    }

    // MARK: - 持久化

    /// 把当前状态序列化落盘。异步执行 —— 主线程立即返回，编码 + 写盘在后台 utility 队列。
    func persist() {
        let snapshot = Persistence.Snapshot(
            subscriptions: subscriptions,
            nodes: nodes,
            customRules: customRules,
            settings: settings,
            currentNodeId: currentNodeId
        )
        persistence.saveSnapshotAsync(snapshot)
    }

    /// 给 SwiftUI 用的 `Binding` 包装：每次 set 都自动 persist，并同步 logger 等副作用。
    public func setting<T>(_ keyPath: WritableKeyPath<Settings, T>) -> Binding<T> where T: Equatable {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in
                guard self.settings[keyPath: keyPath] != newValue else { return }
                self.settings[keyPath: keyPath] = newValue
                self.applySettingsSideEffects()
                self.persist()
            }
        )
    }

    /// 代理模式专用 Binding。普通 `setting(\.proxyMode)` 只会改值 + 持久化；这个还会在
    /// VPN 正在运行时自动重启隧道，让新模式立即生效——对称于切换节点的热切换，用户不用手动关开。
    public var proxyModeBinding: Binding<ProxyMode> {
        Binding(get: { self.settings.proxyMode }, set: { self.setProxyMode($0) })
    }

    /// 切换代理模式。改值 + 副作用 + 持久化；若 VPN 在跑则热重启隧道使新模式即时生效。
    public func setProxyMode(_ mode: ProxyMode) {
        guard settings.proxyMode != mode else { return }
        settings.proxyMode = mode
        applySettingsSideEffects()
        persist()
        logger.info("Proxy mode → \(mode.rawValue)", category: "app")
        // VPN 在跑才需要重启；没跑时 reapplyRunningTunnel 内部 guard 会直接返回。
        Task { await reapplyRunningTunnel() }
    }

    /// settings 任意字段变化后调用：把字段的「执行性」副作用真正落地。
    /// 当前涉及：logger 级别。未来可加：macOS 系统代理端口变化时重新应用。
    private func applySettingsSideEffects() {
        if let lvl = LogLevel(rawValue: settings.logLevel) {
            logger.setMinimumLevel(lvl)
        }
    }

    // MARK: - 节点

    public var sortedNodes: [Node] { nodes.sorted(by: settings.nodeSortOrder) }
    public var currentNode: Node? { nodes.first { $0.id == currentNodeId } }

    // MARK: - 地区

    /// 当前所有节点覆盖的地区 → 节点数，按节点数降序。用于设置页地区列表。
    public var regionCounts: [(region: String, count: Int)] {
        var counts: [String: Int] = [:]
        for n in nodes { counts[n.region, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { (region: $0.key, count: $0.value) }
    }

    /// 节点是否被「有效排除」：手动排除 OR 所在地区被排除。
    public func isEffectivelyExcluded(_ node: Node) -> Bool {
        node.isExcluded || settings.excludedRegions.contains(node.region)
    }

    /// 切换某地区的排除状态。排除时若当前节点在该地区，清空当前选择。
    public func toggleRegionExclusion(_ region: String) {
        if settings.excludedRegions.contains(region) {
            settings.excludedRegions.remove(region)
        } else {
            settings.excludedRegions.insert(region)
            if let cur = currentNode, cur.region == region { currentNodeId = nil }
        }
        logger.info("Region \(region) excluded=\(settings.excludedRegions.contains(region))", category: "app")
        persist()
    }

    public func toggleExclusion(_ node: Node) {
        guard let idx = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        nodes[idx].isExcluded.toggle()
        logger.info("Toggled exclusion for \(nodes[idx].name) → \(nodes[idx].isExcluded)", category: "app")
        if nodes[idx].isExcluded && currentNodeId == node.id {
            currentNodeId = nil
        }
        persist()
    }

    public func select(_ node: Node) {
        guard nodes.contains(where: { $0.id == node.id }) else { return }
        let changed = currentNodeId != node.id
        currentNodeId = node.id
        logger.info("Selected node \(node.name)", category: "app")
        persist()
        // 手动切节点时若 VPN 在跑，也热切换立即生效
        if changed {
            Task { await reapplyRunningTunnel() }
        }
    }

    public func addNode(fromURL urlString: String) throws {
        let node = try ProxyURLParser.parse(urlString)
        merge(node: node)
        logger.info("Added node \(node.name)", category: "app")
        persist()
    }

    /// 批量解析输入（多行链接 **或** Clash YAML），成功的入库，失败的回传。
    @discardableResult
    public func addNodes(fromText text: String) -> (added: Int, errors: [(String, Error)]) {
        // Clash YAML 优先识别 —— 看到 `proxies:` 顶层 key 就走 YAML 解析路径
        if ClashConfigParser.isClashConfig(text) {
            do {
                let (parsed, errs) = try ClashConfigParser.parse(text)
                for node in parsed { merge(node: node) }
                if !parsed.isEmpty {
                    logger.info("Imported \(parsed.count) Clash nodes", category: "app")
                    persist()
                }
                let errors = errs.map { ($0.name, NSError(
                    domain: "ClashConfig", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: $0.reason]) as Error) }
                return (parsed.count, errors)
            } catch {
                logger.warn("Clash YAML parse failed: \(error)", category: "app")
                // 失败就退回到链接解析路径
            }
        }
        let (parsed, errors) = ProxyURLParser.parseBatch(text)
        for node in parsed { merge(node: node) }
        if !parsed.isEmpty {
            logger.info("Manually added \(parsed.count) nodes", category: "app")
            persist()
        }
        return (parsed.count, errors)
    }

    /// 节点入库：同身份指纹更新，否则追加。不写日志、不 persist —— 调用方决定。
    private func merge(node: Node) {
        if let idx = nodes.firstIndex(where: { $0.identityFingerprint == node.identityFingerprint }) {
            var existing = nodes[idx]
            existing.name = node.name
            existing.parameters = node.parameters
            nodes[idx] = existing
        } else {
            nodes.append(node)
        }
    }

    public func removeNode(_ node: Node) {
        nodes.removeAll { $0.id == node.id }
        if currentNodeId == node.id { currentNodeId = nil }
        persist()
    }

    // MARK: - VPN 隧道

    /// 给 UI Toggle 用的 Binding：set 时异步启停 tunnel，并把 isVPNRunning 同步成实际状态。
    public var vpnRunningBinding: Binding<Bool> {
        Binding(
            get: { self.isVPNRunning },
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

    /// 启动 tunnel。捕获所有错误写到 `tunnelError`，UI 弹 alert。
    ///
    /// 流程：
    /// 1. 当前节点 → share link 字符串（via `NodeEncoder.shareLink`，纯 Swift）
    /// 2. 把 share link + proxyMode 通过 providerConfiguration 传给 Extension
    /// 3. Extension 自己跑 libXray.ConvertShareLinksToXrayJson + XrayConfigComposer.compose
    ///    把 share link 展开成完整 xray 配置 —— 主 App 因此不需要 link LibXray.xcframework，
    ///    启动不会被 85 MB Go runtime 拖慢。
    public func startTunnel() async {
        guard let node = currentNode else {
            tunnelError = VPNTunnelManager.TunnelError.noCurrentNode.errorDescription
            isVPNRunning = false
            return
        }

        guard let shareLink = NodeEncoder.shareLink(node) else {
            tunnelError = "无法把节点编码成分享链接"
            isVPNRunning = false
            return
        }

        do {
            // description 带节点名，方便用户在「系统设置 → 网络 → VPN」里识别
            try await tunnelManager.configure(
                node: node,
                mode: settings.proxyMode,
                shareLink: shareLink,
                description: "轻舟 · \(node.name)"
            )
            try await tunnelManager.start()
            isVPNRunning = true
            tunnelError = nil
            logger.info("Tunnel started for node \(node.name)", category: "tunnel")
            scheduleIPRefresh()   // 隧道生效后刷新公网 IP → 落到「节点出口」那栏
        } catch {
            isVPNRunning = false
            tunnelError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            logger.error("Tunnel start failed: \(tunnelError ?? "?")", category: "tunnel")
        }
    }

    public func stopTunnel() async {
        tunnelManager.stop()
        isVPNRunning = false
        scheduleIPRefresh()   // 隧道断开后刷新公网 IP → 落回「直连」那栏
    }

    /// 开关 VPN 后延迟刷新公网 IP：隧道建立/断开要几秒才生效，立即查会拿到旧出口。
    private func scheduleIPRefresh() {
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
    /// 必须断开重连才生效。所以这里是 stop → 短暂等连接断开 → start，会有不到 1 秒的断流。
    /// （需真机验证这个时序在你的网络下是否够稳。）
    public func reapplyRunningTunnel() async {
        guard isVPNRunning,
              let node = currentNode,
              let shareLink = NodeEncoder.shareLink(node) else { return }
        do {
            try await tunnelManager.configure(
                node: node,
                mode: settings.proxyMode,
                shareLink: shareLink,
                description: "轻舟 · \(node.name)"
            )
            tunnelManager.stop()
            try? await Task.sleep(for: .milliseconds(300))  // 等旧连接断开
            try await tunnelManager.start()
            logger.info("Hot-switched running tunnel to \(node.name)", category: "tunnel")
        } catch {
            tunnelError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            logger.error("Hot-switch failed: \(tunnelError ?? "?")", category: "tunnel")
        }
    }

    public func autoSelectBestNode() async {
        guard !nodes.isEmpty else { return }
        let testedAt = Date()
        // 跟手动测速一样：待测节点显示 loading，每测完一个摘掉。
        measuringNodeIds = Set(nodes.filter { !$0.isExcluded }.map(\.id))
        defer { measuringNodeIds = [] }
        let measured = await nodeSelector.measure(nodes: nodes) { [weak self] nodeID, result in
            guard let self else { return }
            self.measuringNodeIds.remove(nodeID)
            if let i = self.nodes.firstIndex(where: { $0.id == nodeID }) {
                self.nodes[i].lastLatencyMs = result.latencyMs
                self.nodes[i].lastTestedAt = testedAt
            }
        }
        nodes = measured
        let previousId = currentNodeId
        if let best = pickBestRespectingRegions(from: measured) {
            currentNodeId = best.id
            logger.info("Auto-selected \(best.name) [\(best.region)] (\(best.lastLatencyMs ?? -1)ms)", category: "app")
        } else {
            logger.warn("Auto-select found no viable node", category: "app")
        }
        persist()
        // 节点变了且 VPN 在跑 → 热切换，立即生效
        if currentNodeId != previousId {
            await reapplyRunningTunnel()
        }
    }

    /// 在测速结果里挑最佳节点，应用「地区排除」+「地区优先」：
    /// 1. 先剔除有效排除（手动排除 / 地区排除）和测速失败的节点
    /// 2. 若设了优先地区且该地区有可用节点，从中选延迟最低的
    /// 3. 否则全局选延迟最低的
    func pickBestRespectingRegions(from measured: [Node]) -> Node? {
        let viable = measured.filter { !isEffectivelyExcluded($0) && $0.lastLatencyMs != nil }
        guard !viable.isEmpty else { return nil }
        if let pref = settings.preferredRegion {
            let inPref = viable.filter { $0.region == pref }
            if let best = inPref.min(by: { ($0.lastLatencyMs ?? .max) < ($1.lastLatencyMs ?? .max) }) {
                return best
            }
        }
        return viable.min(by: { ($0.lastLatencyMs ?? .max) < ($1.lastLatencyMs ?? .max) })
    }

    public func measureAllNodes() async {
        let testedAt = Date()
        // 测速开始：把所有待测（非排除）节点标记为"测速中"，UI 显示旋转 loading。
        measuringNodeIds = Set(nodes.filter { !$0.isExcluded }.map(\.id))
        defer { measuringNodeIds = [] }  // 不管正常结束还是取消，都清干净
        // 渐进式：每测完一个节点立刻刷新它那一行的延迟 + 摘掉它的 loading，不用干等全部测完。
        nodes = await nodeSelector.measure(nodes: nodes) { [weak self] nodeID, result in
            guard let self else { return }
            self.measuringNodeIds.remove(nodeID)
            if let i = self.nodes.firstIndex(where: { $0.id == nodeID }) {
                self.nodes[i].lastLatencyMs = result.latencyMs
                self.nodes[i].lastTestedAt = testedAt
            }
        }
        persist()
    }

    // MARK: - 订阅

    public func addSubscription(name: String, url: URL) async {
        let sub = Subscription(name: name.isEmpty ? (url.host ?? "Subscription") : name, url: url)
        subscriptions.append(sub)
        persist()
        await refreshSubscription(sub)
        // 首次拉到节点后自动测速 + 选延迟最优节点，并 toast 告知用户（不打断操作）。
        if subscriptionErrors[sub.id] == nil, !nodes.isEmpty {
            await autoSelectBestNode()
            if let best = currentNode {
                showToast("已为你选择延迟最优节点：\(best.name)")
            }
        }
    }

    /// 轻量非阻塞反馈：设置 toast 文案，3 秒后自动清空。
    public func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    public func refreshSubscription(_ subscription: Subscription) async {
        do {
            let (updated, payload) = try await subscriptionFetcher.refresh(subscription)
            if let idx = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
                subscriptions[idx] = updated
            } else {
                subscriptions.append(updated)
            }
            merge(newNodes: payload.nodes, fromSubscription: updated.id)
            subscriptionErrors[subscription.id] = nil
            persist()
        } catch {
            subscriptionErrors[subscription.id] = "\(error)"
            logger.error("Refresh subscription \(subscription.name) failed: \(error)", category: "subscription")
        }
    }

    public func removeSubscription(_ subscription: Subscription) {
        subscriptions.removeAll { $0.id == subscription.id }
        nodes.removeAll { $0.subscriptionId == subscription.id }
        if let cn = currentNode, cn.subscriptionId == subscription.id { currentNodeId = nil }
        subscriptionErrors[subscription.id] = nil
        persist()
    }

    public func merge(newNodes incoming: [Node], fromSubscription subId: UUID) {
        let oldBySub = nodes.filter { $0.subscriptionId == subId }
        let oldByFingerprint = Dictionary(uniqueKeysWithValues: oldBySub.map { ($0.identityFingerprint, $0) })

        var preserved: [Node] = []
        for n in incoming {
            var merged = n
            if let prev = oldByFingerprint[n.identityFingerprint] {
                merged.id = prev.id
                merged.isExcluded = prev.isExcluded
                merged.lastLatencyMs = prev.lastLatencyMs
                merged.lastTestedAt = prev.lastTestedAt
            }
            preserved.append(merged)
        }
        nodes.removeAll { $0.subscriptionId == subId }
        nodes.append(contentsOf: preserved)

        // 选中的节点可能被上游删了，或它的 host/port/凭据变了 → identityFingerprint 变了
        // → 被当成新节点、老 id 丢失。此时 currentNodeId 会悬空指向一个已不存在的节点
        //（currentNode 变 nil，热切换也察觉不到——id 没"变"，只是指向了空）。
        // 跟 removeSubscription / toggleExclusion 等所有改动路径保持一致：悬空就清掉。
        if let id = currentNodeId, !nodes.contains(where: { $0.id == id }) {
            currentNodeId = nil
            logger.info("Selected node gone after subscription refresh — cleared selection", category: "subscription")
        }
    }

    // MARK: - 规则

    public func addCustomRule(_ rule: Rule) {
        customRules.append(rule)
        logger.info("Added custom rule \(rule.lineForm)", category: "rules")
        persist()
    }

    public func removeCustomRule(_ rule: Rule) {
        customRules.removeAll { $0.id == rule.id }
        persist()
    }

    public func currentRuleEngine() -> RuleEngine {
        RuleEngine(rules: customRules + remoteRules)
    }

    // MARK: - 调度器

    /// 启动后台调度：根据设置定期跑自动择优 + 订阅刷新；同时启动示例连接产线（直到真隧道接入）。
    public func startSchedulers() {
        stopSchedulers()
        schedulerTask = Task { @MainActor [weak self] in
            await self?.schedulerLoop()
        }
        trafficPollingTask = Task { @MainActor [weak self] in
            await self?.trafficPollingLoop()
        }
        accessLogPollingTask = Task { @MainActor [weak self] in
            await self?.accessLogPollingLoop()
        }
    }

    public func stopSchedulers() {
        schedulerTask?.cancel()
        schedulerTask = nil
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

        if settings.autoSelectTrigger == .onAppLaunch || settings.autoSelectTrigger == .onAppLaunchAndInterval {
            await autoSelectBestNode()
        }
        var lastAutoSelect = Date()
        var lastMeasure = Date()
        var lastRefresh = Date()

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            if Task.isCancelled { break }

            let now = Date()

            // 1) 自动测速 —— 周期性刷新延迟列，**不动 currentNodeId**。
            //    如果 autoSelect 在 interval 模式下也运行了，它已经测过一遍，
            //    这里 lastMeasure 跟着重置避免立刻重复测。
            let measureInterval = settings.autoMeasureIntervalSeconds
            if measureInterval > 0 && now.timeIntervalSince(lastMeasure) >= measureInterval {
                await measureAllNodes()
                lastMeasure = Date()
            }

            // 2) 自动择优 —— 测速 + 主动切到最快节点 (改 currentNodeId)
            let trigger = settings.autoSelectTrigger
            if (trigger == .interval || trigger == .onAppLaunchAndInterval)
                && now.timeIntervalSince(lastAutoSelect) >= settings.autoSelectIntervalSeconds {
                await autoSelectBestNode()
                lastAutoSelect = Date()
                lastMeasure = Date()  // autoSelectBestNode 内部已经 measure 过，避免立刻再测
            }

            // 3) 自动订阅刷新
            let refreshInterval = settings.subscriptionRefreshIntervalSeconds
            if refreshInterval > 0 && now.timeIntervalSince(lastRefresh) >= refreshInterval {
                for sub in subscriptions {
                    await refreshSubscription(sub)
                }
                lastRefresh = Date()
            }
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
            #if os(macOS)
            // 来源 App 标注暂时搁置（见 FeatureFlags.sourceAppLabeling）。开启时才走 XPC + 回填。
            if FeatureFlags.sourceAppLabeling {
                // content filter 扩展（root）经 XPC 提供端口→App 映射；没启用/连不上则保持上次的值。
                let fetched = await filterControl.fetchPortMap()
                if let fetched {
                    sourceAppMap = fetched
                }
                // 回填：连接常在 XPC map 就绪前就已 ingest（sourceApp=nil），每轮用最新 map
                // 把已存在连接的来源 App 补上，否则只有「解析那一刻」端口在 map 里的才有标注。
                backfillSourceApps()
            }
            #endif
            ingestAccessLog()
        }
    }

    #if os(macOS)
    /// 用最新的「源端口 → 来源 App」映射，回填所有还没标注来源的连接。
    /// content filter 的 map 常晚于连接 ingest 才就绪，只在解析那刻查一次会漏掉大批连接。
    private func backfillSourceApps() {
        guard !sourceAppMap.isEmpty else { return }
        for i in connections.indices where connections[i].sourceApp == nil {
            if let port = connections[i].sourceAddress.split(separator: ":").last.map(String.init),
               let bundleID = sourceAppMap[port] {
                connections[i].sourceApp = bundleID
            }
        }
    }
    #endif

    private func ingestAccessLog() {
        guard let url = AppGroupStorage.accessLogURL,
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < accessLogOffset { accessLogOffset = 0 }   // 文件被新会话清空/重建 → 重头读
        guard size > accessLogOffset else { return }        // 没有新行
        try? handle.seek(toOffset: accessLogOffset)
        let data = (try? handle.readToEnd()) ?? Data()
        accessLogOffset = size
        guard let text = String(data: data, encoding: .utf8) else { return }
        let entries = AccessLogParser.parse(text)
        guard !entries.isEmpty else { return }
        let proxyName = currentNode?.name
        for entry in entries {
            var conn = entry.makeConnection(proxyDisplayName: proxyName)
            // FakeDNS 的假 IP（198.18.x.x）→ 反查回真域名，连接列表/域名分析才有意义
            if let domain = fakeDNSMap[entry.targetHost] {
                conn.targetHost = domain
                conn.targetAddress = "\(domain):\(entry.targetPort)"
            }
            // 源端口 → 来源 App（macOS content filter 标注的 bundle id）
            if let port = entry.sourceAddress.split(separator: ":").last.map(String.init),
               let bundleID = sourceAppMap[port] {
                conn.sourceApp = bundleID
            }
            connections.insert(conn, at: 0)
        }
        if connections.count > 200 { connections.removeLast(connections.count - 200) }
    }

    /// appex 经 App Group 上报的真实 `TrafficStats` 喂进波形窗口。UI 观察 `trafficHistory` 自动重绘。
    public func ingestTrafficStats(_ stats: TrafficStats) {
        trafficHistory.record(stats)
    }

    /// 每秒读 App Group 里 appex 上报的真实流量统计，喂进波形。
    ///
    /// **靠数据新鲜度驱动，不靠 isVPNRunning** —— 杀掉 App 重启后 VPN 扩展还在跑、但主 App 的
    /// isVPNRunning 默认是 false，若用它当闸门波形会一直空。改为：只要读到新鲜样本就画；
    /// 连续几秒读不到新鲜数据（VPN 停了或没上报）才清空波形。
    private func trafficPollingLoop() async {
        var staleSeconds = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { break }
            // "traffic-stats" 必须与 XrayCore.TunnelAppGroup.trafficStatsName 一致（两模块互不依赖）
            if let stats = AppGroupStorage.read(TrafficStats.self, from: "traffic-stats"),
               abs(stats.sampledAt.timeIntervalSinceNow) <= 3 {   // 只接受新鲜样本，避免旧文件
                ingestTrafficStats(stats)
                staleSeconds = 0
            } else {
                staleSeconds += 1
                if staleSeconds >= 5, !trafficHistory.samples.isEmpty {
                    trafficHistory.clear()   // 连续 5 秒没新数据 → VPN 停了，清空波形
                }
            }
        }
    }
}

/// 远程拉取的轻量状态。
public enum RemoteFetchStatus: Sendable, Equatable {
    case idle
    case loading
    case success(at: Date, count: Int)
    case failure(message: String)
}

/// 公网 IP / 地理信息。
public struct PublicIPInfo: Codable, Sendable, Equatable {
    public var ip: String
    public var country: String?
    public var region: String?
    public var city: String?
    public var isp: String?
    public var fetchedAt: Date

    public init(ip: String, country: String? = nil, region: String? = nil, city: String? = nil, isp: String? = nil, fetchedAt: Date = Date()) {
        self.ip = ip
        self.country = country
        self.region = region
        self.city = city
        self.isp = isp
        self.fetchedAt = fetchedAt
    }
}

