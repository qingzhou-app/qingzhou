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
#if canImport(UIKit)
import UIKit
#endif

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
    /// 连接列表（UI 读这里）。写入/老化/关闭统一走 `connectionTracker`，
    /// 它负责「同身份重现刷新活跃时间 + 超时置 closedAt」——否则「已关闭」分组永远为空
    /// （xray access log 只记连接建立，没有关闭事件）。
    public var connections: [Connection] { connectionTracker.connections }
    var connectionTracker = ConnectionTracker()
    /// 按天 × 主域名的聚合历史（域名分析「每日」视图数据源）。connections 只留内存最近
    /// 200 条、重启清零，每日历史必须靠它。⚠️ 访问历史属敏感数据：独立文件落本地
    /// （`Self.domainHistoryFile`），**不进 Persistence.Snapshot**，绝不被 iCloud vault 镜像。
    public private(set) var domainHistory = DomainDailyHistory()
    /// 实时流量波形数据（滑动窗口）。appex 经 App Group 上报 `TrafficStats` 喂进来；
    /// 没开 VPN / 没真实上报时为空，UI 显示「等待流量」。
    public var trafficHistory = TrafficHistory(capacity: 60)
    public var settings: Settings = Settings()
    public var lastSpeedTestReport: SpeedTestReport?
    /// 正在测速的节点 id 集合 —— UI 据此在对应行显示旋转 loading。
    public var measuringNodeIds: Set<UUID> = []
    public var isVPNRunning: Bool = false
    /// 热切换窗口标志：VPN 运行中切节点/模式触发全量重启（stop→start）期间为 true。
    /// UI 用它把开关滑到"关"、显示"切换中…"——跟真实断流窗口一致，不做假动画。
    /// 不翻转 isVPNRunning：那个承载"用户意图上 VPN 是开的"，被 reapply 入口 guard
    /// 和 NetworkInfoService（公网 IP 写哪栏）依赖。internal(set) 供 @testable 测试写入。
    public internal(set) var isSwitchingTunnel: Bool = false
    /// VPN 启停最近一次错误（拿不到 entitlement / 配置失败等）。UI 用 alert 展示。
    public var tunnelError: String?
    /// 「定时关闭」的到点时刻（本次连接启用了定时才非 nil）。首页状态区据此画倒计时。
    /// 数据源是扩展写的 App Group 会话标记（启动时刻 + 时长推算），每秒轮询刷新 ——
    /// 不依赖和扩展的实时通信，主 App 被杀重启后也能恢复显示。
    public internal(set) var autoStopDeadline: Date?
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
    /// iCloud vault 同步状态（设置页展示）。
    public internal(set) var cloudSyncStatus: CloudSyncStatus = .unknown
    /// 待确认的恢复候选（启动检查发现云端更新 / 用户从版本列表选了一份）。非 nil 时 UI 弹
    /// 确认 alert，alert 里会展示来源设备 / 时间 / 内容计数 —— 「0 订阅」一眼可见，防误恢复。
    public internal(set) var cloudRestoreOffer: VaultRestoreCandidate?
    /// 「立即恢复」的版本选择列表（云端当前版 + 最近几份历史版本）。非 nil 时 UI 弹选择 sheet。
    public internal(set) var cloudVersionOptions: [VaultRestoreCandidate]?

    public let logger: Logger
    public let subscriptionFetcher: SubscriptionFetcher
    public let nodeSelector: NodeSelector
    public let speedTestRunner: SpeedTestRunner
    public let persistence: Persistence
    public let tunnelManager: VPNTunnelManager
    /// iCloud Drive vault 的读写层。测试可注入指向临时目录的假容器。
    let cloudVault: CloudVaultStore
    /// 镜像到 iCloud 的防抖任务（连续 persist 只留最后一次）。internal 供测试 await。
    var cloudMirrorTask: Task<Void, Never>?
    /// 云端文档「还在下载中」时的延迟重试任务（新装机首启常见）。
    private var cloudStartupRetryTask: Task<Void, Never>?

    private var schedulerTask: Task<Void, Never>?
    private var trafficPollingTask: Task<Void, Never>?
    private var accessLogPollingTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var ipRefreshTask: Task<Void, Never>?
    /// 热切换进行中又来了新的切换请求（快速连点节点）：记 pending，当前轮收尾后再跑一轮。
    /// 不并发跑两个 reapply —— stop/start 交错会打架。
    private var pendingReapply = false
    /// access log 文件已读到的字节位置（增量读，不重复解析）。
    private var accessLogOffset: UInt64 = 0
    /// matchedRule 回填器（内含 host→规则 缓存）。规则集 / proxyMode 变化时按 key 重建。
    private var matchedRuleResolver: MatchedRuleResolver?
    private var matchedRuleResolverKey: Int = 0
    /// domainHistory 的独立持久化文件名（不进 Snapshot —— 见 domainHistory 注释）。
    static let domainHistoryFile = "domain-history"
    /// domainHistory 上次落盘时间：浏览时每 2 秒都有新批次，逐批全量编码落盘太浪费，
    /// 节流到 ≥saveInterval 一次；停止浏览后由轮询循环把最后的脏数据补写掉
    /// （进程被杀最多丢 saveInterval 秒的聚合，可接受）。
    private var domainHistorySavedAt = Date.distantPast
    private var domainHistoryDirty = false
    /// internal 供测试注入 0 关掉节流做确定性断言。
    var domainHistorySaveInterval: TimeInterval = 10
    /// appex 写的「IP → 域名」映射，把 access log 的裸 IP 翻回域名。里面既有 fakedns
    /// 假 IP（198.18.x.x）也有真实 DNS 应答的 IP（rule 模式下 CN 域名走 AliDNS 拿真实 IP）。
    /// internal 供单测直接注入（backfillDomainNames 用例）。
    var fakeDNSMap: [String: String] = [:]
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
        tunnelManager: VPNTunnelManager? = nil,
        cloudVault: CloudVaultStore? = nil
    ) {
        self.logger = logger
        self.persistence = persistence
        self.subscriptionFetcher = subscriptionFetcher ?? SubscriptionFetcher(logger: logger)
        self.nodeSelector = nodeSelector ?? NodeSelector(logger: logger)
        self.speedTestRunner = speedTestRunner ?? SpeedTestRunner(logger: logger)
        self.tunnelManager = tunnelManager ?? VPNTunnelManager(logger: logger)
        self.cloudVault = cloudVault ?? CloudVaultStore()

        let snapshot = persistence.loadSnapshot()
        self.subscriptions = snapshot.subscriptions
        self.nodes = snapshot.nodes
        self.customRules = snapshot.customRules
        self.settings = snapshot.settings
        self.currentNodeId = snapshot.currentNodeId
        // 域名每日历史：独立文件（敏感访问历史，不进 Snapshot / 不上云），加载后顺手滚动清理
        var history = persistence.load(DomainDailyHistory.self, name: Self.domainHistoryFile)
            ?? DomainDailyHistory()
        history.prune()
        self.domainHistory = history
        logger.info(
            "AppState restored: \(subscriptions.count) subs, \(nodes.count) nodes, \(customRules.count) custom rules",
            category: "app"
        )
        logger.setMinimumLevel(LogLevel(rawValue: settings.logLevel) ?? .info)
    }

    // MARK: - 持久化

    /// 把当前状态序列化落盘。异步执行 —— 主线程立即返回，编码 + 写盘在后台 utility 队列。
    /// 本地落盘后再（防抖地）镜像到 iCloud vault —— 本地是权威源，云端只是镜像。
    func persist() {
        persistence.saveSnapshotAsync(currentSnapshot())
        scheduleCloudMirror()
    }

    /// 当前内存状态的完整快照（本地落盘 / 云端镜像共用）。
    func currentSnapshot() -> Persistence.Snapshot {
        Persistence.Snapshot(
            subscriptions: subscriptions,
            nodes: nodes,
            customRules: customRules,
            settings: settings,
            currentNodeId: currentNodeId
        )
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
                    showToast("已重新计时：\(AutoStopPresets.label(for: seconds))后自动断开")
                } else {
                    try await tunnelManager.setAutoStop(seconds: 0)
                    try await tunnelManager.setOnDemandEnabled(true)
                    autoStopDeadline = nil
                    showToast("已取消定时断开")
                }
            } catch {
                logger.warn("Apply auto-stop to running tunnel failed: \(error)", category: "tunnel")
                showToast("定时设置将在下次连接时生效")
            }
        }
    }

    /// settings 任意字段变化后调用：把字段的「执行性」副作用真正落地。
    /// 当前涉及：logger 级别。未来可加：macOS 系统代理端口变化时重新应用。
    private func applySettingsSideEffects() {
        if let lvl = LogLevel(rawValue: settings.logLevel) {
            logger.setMinimumLevel(lvl)
        }
    }

    // MARK: - iCloud vault（配置的云端镜像，详见 CloudVault.swift 头注释）

    /// 本机同步进度的本地文件名（Persistence 目录，不上云）。
    private static let vaultSyncStateName = "vault-sync-state"
    /// 恢复云端数据前，本地快照的备份文件名。
    private static let restoreBackupName = "state-backup-before-restore"

    /// 启动时的云端检查：无文档 → 镜像本地；云端更新 / 新装机 → 提示恢复；schema 过新 → 拒绝。
    /// app 启动（startSchedulers）和用户打开同步开关时调用。
    public func runCloudVaultStartupCheck() async {
        guard settings.iCloudSyncEnabled else {
            cloudSyncStatus = .disabled
            return
        }
        guard await cloudVault.isAvailable() else {
            cloudSyncStatus = .unavailable
            return
        }
        let header: VaultHeader?
        do {
            header = try await cloudVault.loadHeader()
        } catch let error as CloudVaultStore.StoreError where error == .notYetDownloaded {
            // 云端有文档、本机还没下载完（新装机首启常见）：绝不能当「云端没有」去镜像覆盖。
            // 显示同步中，15 秒后重试。
            cloudSyncStatus = .syncing
            cloudStartupRetryTask?.cancel()
            cloudStartupRetryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await self?.runCloudVaultStartupCheck()
            }
            return
        } catch {
            cloudSyncStatus = .error("\(error)")
            logger.warn("iCloud vault read failed: \(error)", category: "cloud")
            return
        }
        let lastSynced = persistence.load(VaultSyncState.self, name: Self.vaultSyncStateName)
        switch VaultSyncLogic.startupAction(
            cloudHeader: header, lastSyncedRevision: lastSynced?.lastSyncedRevision
        ) {
        case .mirrorLocal:
            // 防呆：本机是空的且从没同步过（新装机）→ 没什么值得镜像的，也避免在 iCloud
            // 元数据尚未同步完时把「空」推上去盖掉真数据。等用户真加了配置，persist 会镜像。
            let snapshot = currentSnapshot()
            let localHasContent = !snapshot.subscriptions.isEmpty || !snapshot.nodes.isEmpty
                || !snapshot.customRules.isEmpty
            if localHasContent || lastSynced != nil {
                await mirrorToCloudNow()
            } else {
                cloudSyncStatus = .idle
            }
        case .offerRestore(let cloud):
            cloudRestoreOffer = VaultRestoreCandidate(header: cloud)
            cloudSyncStatus = lastSynced.map { .synced($0.lastSyncedAt) } ?? .unknown
            logger.info("iCloud vault newer (rev \(cloud.revision) from \(cloud.deviceName)) — offering restore", category: "cloud")
        case .alreadyInSync:
            cloudSyncStatus = .synced(lastSynced?.lastSyncedAt ?? Date())
        case .incompatibleCloud(let version):
            cloudSyncStatus = .incompatibleCloud(schemaVersion: version)
            logger.warn("iCloud vault schema v\(version) is newer than supported — not touching it", category: "cloud")
        }
    }

    /// persist() 后调用：防抖 0.5s 再镜像 —— 连续编辑（批量导入 / 拖排序）只写最后一版。
    private func scheduleCloudMirror() {
        guard settings.iCloudSyncEnabled, cloudRestoreOffer == nil else { return }
        cloudMirrorTask?.cancel()
        cloudMirrorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.mirrorToCloudNow()
        }
    }

    /// 立即把当前状态镜像到云端（revision 盖过云端与本机记录的较大者）。
    ///
    /// 上云内容先经 `VaultSnapshotNormalizer` 剥离瞬态字段（延迟 / 当前节点 / 订阅拉取
    /// 时刻与用量），再与上次镜像的内容哈希比对 —— **内容没变就跳过**：自动测速 /
    /// 自动择优 / 订阅例行刷新不再刷出大量雷同 revision、不再挤掉滚动备份里的有效历史。
    private func mirrorToCloudNow() async {
        guard settings.iCloudSyncEnabled, cloudRestoreOffer == nil else { return }
        guard await cloudVault.isAvailable() else {
            cloudSyncStatus = .unavailable
            return
        }
        let snapshot = VaultSnapshotNormalizer.normalized(currentSnapshot())
        let contentHash = try? VaultSnapshotNormalizer.contentHash(of: snapshot)
        let lastSynced = persistence.load(VaultSyncState.self, name: Self.vaultSyncStateName)

        cloudSyncStatus = .syncing
        do {
            let header = try? await cloudVault.loadHeader()
            if let header, header.schemaVersion > VaultDocument.currentSchemaVersion {
                // 云端是新版 App 写的：别用旧格式盖掉
                cloudSyncStatus = .incompatibleCloud(schemaVersion: header.schemaVersion)
                return
            }
            // 内容去重：云端就是本机上次写的那个 revision、且规范化内容没变 → 什么都不做
            if let header, let lastSynced, let contentHash,
               header.revision == lastSynced.lastSyncedRevision,
               lastSynced.lastMirroredContentHash == contentHash {
                cloudSyncStatus = .synced(lastSynced.lastSyncedAt)
                return
            }
            let revision = VaultSyncLogic.nextRevision(
                cloudRevision: header?.revision,
                lastSyncedRevision: lastSynced?.lastSyncedRevision
            )
            let document = VaultDocument(
                revision: revision,
                modifiedAt: Date(),
                deviceName: Self.deviceName,
                snapshot: snapshot
            )
            try await cloudVault.save(document)
            let now = Date()
            try? persistence.save(
                VaultSyncState(lastSyncedRevision: revision, lastSyncedAt: now, lastMirroredContentHash: contentHash),
                name: Self.vaultSyncStateName
            )
            cloudSyncStatus = .synced(now)
        } catch {
            cloudSyncStatus = .error("\(error)")
            logger.warn("iCloud vault mirror failed: \(error)", category: "cloud")
        }
    }

    /// 用户确认恢复：本地快照先备份，再整体替换为所选版本并落盘。
    /// 候选可能是云端主文档（`candidate == nil` 或 `backupFileName == nil`），
    /// 也可能是 backups/ 里的历史版本。
    ///
    /// ⚠️ **候选必须由调用方显式传入，不能在这里读 `cloudRestoreOffer`** —— 确认 alert 的
    /// 按钮 action 只是 spawn 一个 Task，SwiftUI 会先走 dismiss：isPresented binding 置
    /// false → declineCloudRestore() 把 offer 清成 nil，这一切都发生在 Task 真正执行之前。
    /// 在这里再读 offer 拿到的**恒为 nil**，于是用户在版本列表选的历史版本被忽略、
    /// 永远恢复成云端主文档（真机事故：选了「1 订阅 30 节点」的历史版，恢复出来 0/0，
    /// 因为主文档在该设备视角还是删空后的那份）。
    public func restoreFromCloud(candidate: VaultRestoreCandidate?) async {
        cloudRestoreOffer = nil
        // 恢复期间取消在途的防抖镜像 —— 别让「恢复前的旧状态」在 apply 的 await 间隙被推上云端
        cloudMirrorTask?.cancel()
        cloudMirrorTask = nil

        let document: VaultDocument?
        do {
            if let fileName = candidate?.backupFileName {
                document = try await cloudVault.loadBackupDocument(fileName: fileName)
            } else {
                document = try await cloudVault.loadDocument()
            }
        } catch {
            showToast("读取 iCloud 数据失败：\(error.localizedDescription)")
            logger.error("iCloud vault restore read failed: \(error)", category: "cloud")
            return
        }
        guard let document else {
            showToast("iCloud 上没有找到备份")
            return
        }
        guard document.schemaVersion <= VaultDocument.currentSchemaVersion else {
            cloudSyncStatus = .incompatibleCloud(schemaVersion: document.schemaVersion)
            showToast("iCloud 数据来自更新版本的轻舟，请先升级 App")
            return
        }
        // 覆盖本地前留一份备份 —— 恢复错了还能救
        try? persistence.save(currentSnapshot(), name: Self.restoreBackupName)

        // vault 里剥掉了设备本地的瞬态字段（延迟 / 当前节点 / 订阅拉取时刻与用量），
        // 恢复时从本地按身份回填 —— 别把本机刚测好的延迟、正在用的节点清掉。
        var snapshot = document.snapshot
        let localNodeTransients = Dictionary(
            nodes.map { ($0.identityFingerprint, (latency: $0.lastLatencyMs, testedAt: $0.lastTestedAt)) },
            uniquingKeysWith: { first, _ in first }
        )
        for i in snapshot.nodes.indices {
            if snapshot.nodes[i].lastLatencyMs == nil,
               let local = localNodeTransients[snapshot.nodes[i].identityFingerprint] {
                snapshot.nodes[i].lastLatencyMs = local.latency
                snapshot.nodes[i].lastTestedAt = local.testedAt
            }
        }
        let localSubTransients = Dictionary(
            subscriptions.map { ($0.url, (updatedAt: $0.lastUpdatedAt, used: $0.usedBytes)) },
            uniquingKeysWith: { first, _ in first }
        )
        for i in snapshot.subscriptions.indices {
            if snapshot.subscriptions[i].lastUpdatedAt == nil,
               let local = localSubTransients[snapshot.subscriptions[i].url] {
                snapshot.subscriptions[i].lastUpdatedAt = local.updatedAt
                snapshot.subscriptions[i].usedBytes = local.used
            }
        }
        // 当前节点：新 vault 不带 currentNodeId（设备本地选择）→ 尽量沿用本机的；
        // 旧文档带了就尊重它。恢复后指向的节点不存在则清空。
        let preservedCurrentId = currentNodeId

        subscriptions = snapshot.subscriptions
        nodes = snapshot.nodes
        customRules = snapshot.customRules
        settings = snapshot.settings
        currentNodeId = snapshot.currentNodeId ?? preservedCurrentId
        if let id = currentNodeId, !nodes.contains(where: { $0.id == id }) {
            currentNodeId = nil
        }
        applySettingsSideEffects()
        persistence.saveSnapshotAsync(currentSnapshot())
        // 恢复替换了节点 / 模式 / 规则 —— VPN 在跑就热切换到恢复后的配置（没跑时内部 guard 直接返回）
        Task { await reapplyRunningTunnel() }
        let now = Date()
        logger.info("Restored from iCloud vault rev \(document.revision) (\(document.deviceName))", category: "cloud")
        showToast("已从 iCloud 恢复（\(snapshot.subscriptions.count) 个订阅、\(snapshot.nodes.count) 个节点）")

        if candidate?.backupFileName != nil {
            // 恢复的是历史版本：云端主文档还是那份「更新但错误」的（比如被删空的）。
            // 立刻把恢复出来的状态以更高 revision 回推 —— 云端主文档也被救回。
            await mirrorToCloudNow()
        } else {
            // 恢复的就是云端主文档：记录同步进度即可，不用再镜像（内容一致，白 +1 revision）。
            // 哈希记规范化后的恢复内容 —— 之后无实质变化的 persist 不会再产生新 revision。
            try? persistence.save(
                VaultSyncState(
                    lastSyncedRevision: document.revision,
                    lastSyncedAt: now,
                    lastMirroredContentHash: try? VaultSnapshotNormalizer.contentHash(
                        of: VaultSnapshotNormalizer.normalized(currentSnapshot()))
                ),
                name: Self.vaultSyncStateName
            )
            cloudSyncStatus = .synced(now)
        }
    }

    /// 用户拒绝恢复：只清掉提示（本次会话不再弹）。本地依旧权威 —— 下次本地编辑会覆盖云端。
    public func declineCloudRestore() {
        cloudRestoreOffer = nil
    }

    /// 设置页「立即恢复 iCloud 数据」：列出云端当前版 + 最近几份历史版本（含来源设备 /
    /// 时间 / 内容计数），让用户挑 —— 即使主文档被某台设备的空数据覆盖，旧版本仍可找回。
    public func requestManualCloudRestore() async {
        guard await cloudVault.isAvailable() else {
            showToast("iCloud 不可用（未登录或未开启 iCloud Drive）")
            return
        }
        let mainHeader: VaultHeader?
        do {
            mainHeader = try await cloudVault.loadHeader()
        } catch let error as CloudVaultStore.StoreError where error == .notYetDownloaded {
            showToast("iCloud 数据还在下载中，稍等片刻再试")
            return
        } catch {
            showToast("读取 iCloud 数据失败：\(error.localizedDescription)")
            return
        }
        var options: [VaultRestoreCandidate] = []
        if let mainHeader, mainHeader.schemaVersion <= VaultDocument.currentSchemaVersion {
            options.append(VaultRestoreCandidate(header: mainHeader))
        }
        for backup in await cloudVault.listBackups()
        where backup.header.schemaVersion <= VaultDocument.currentSchemaVersion
            && backup.header.revision != mainHeader?.revision {
            options.append(VaultRestoreCandidate(header: backup.header, backupFileName: backup.fileName))
        }
        switch options.count {
        case 0:
            if mainHeader != nil {
                showToast("iCloud 数据来自更新版本的轻舟，请先升级 App")
            } else {
                showToast("iCloud 上没有找到备份")
            }
        case 1:
            cloudRestoreOffer = options[0]     // 只有一份，直接进确认弹窗
        default:
            cloudVersionOptions = options      // 多份 → 弹版本选择列表
        }
    }

    /// 用户在版本列表里选了一份 → 进入确认弹窗。
    public func chooseCloudRestoreCandidate(_ candidate: VaultRestoreCandidate) {
        cloudVersionOptions = nil
        cloudRestoreOffer = candidate
    }

    /// 关闭版本选择列表。
    public func dismissCloudVersionOptions() {
        cloudVersionOptions = nil
    }

    /// 开关 iCloud 同步。开 → 立刻跑一次启动检查（可能提示恢复 / 补镜像）；关 → 取消在途镜像。
    public func setCloudSyncEnabled(_ enabled: Bool) {
        guard settings.iCloudSyncEnabled != enabled else { return }
        settings.iCloudSyncEnabled = enabled
        if enabled {
            // 只存本地，别直接镜像 —— 云端可能比本机新，让 startup check 先比对：
            // 该提示恢复就提示，确认没冲突它自己会补镜像。
            persistence.saveSnapshotAsync(currentSnapshot())
            Task { @MainActor [weak self] in await self?.runCloudVaultStartupCheck() }
        } else {
            cloudMirrorTask?.cancel()
            cloudMirrorTask = nil
            persistence.saveSnapshotAsync(currentSnapshot())   // 只存本地，不再碰云端
            cloudSyncStatus = .disabled
        }
        logger.info("iCloud sync \(enabled ? "enabled" : "disabled")", category: "cloud")
    }

    /// 云文档里标注的来源设备名（多设备同步时提示「来自哪台」）。
    private static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
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
                rules: effectiveUserRules,
                autoStopSeconds: settings.autoStopSeconds,
                description: "轻舟 · \(node.name)"
            )
            try await tunnelManager.start()
            isVPNRunning = true
            tunnelError = nil
            logger.info("Tunnel started for node \(node.name)", category: "tunnel")
            if settings.autoStopSeconds > 0 {
                showToast("已开启定时：\(AutoStopPresets.label(for: settings.autoStopSeconds))后自动断开")
            }
            scheduleIPRefresh()   // 隧道生效后刷新公网 IP → 落到「节点出口」那栏
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

    public func stopTunnel() async {
        // ⚠️ 用户主动关 VPN：必须先关掉 On-Demand 并落盘，否则 On-Demand 的 connect 规则
        // 会在 stop() 之后立刻把隧道重连回来，用户永远关不掉。失败也继续 stop（尽力而为）。
        do {
            try await tunnelManager.setOnDemandEnabled(false)
        } catch {
            logger.warn("Disable on-demand before stop failed: \(error)", category: "tunnel")
        }
        tunnelManager.stop()
        isVPNRunning = false
        autoStopDeadline = nil       // 手动关了，倒计时立即消失（不等下一秒轮询）
        markAllConnectionsClosed()   // 隧道停了，活跃连接全部立即归入「已关闭」
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
    /// 必须断开重连才生效。所以这里是 stop → 等连接断开 → start，会有短暂断流；
    /// 期间 isSwitchingTunnel = true，UI 开关滑到关 + 显示"切换中…"。
    ///
    /// 防抖：切换进行中再次调用只记 pending；当前轮收尾后发现 pending 就再跑一轮，
    /// 状态里已是最新节点/模式，自动收敛到用户的最终选择。
    public func reapplyRunningTunnel() async {
        if isSwitchingTunnel {
            pendingReapply = true
            return
        }
        repeat {
            pendingReapply = false
            await performReapply()
        } while pendingReapply
    }

    private func performReapply() async {
        guard isVPNRunning,
              let node = currentNode,
              let shareLink = NodeEncoder.shareLink(node) else { return }
        isSwitchingTunnel = true
        defer { isSwitchingTunnel = false }
        // ⚠️ 原地无感重配（reconfigureInPlace + 扩展 handleAppMessage）暂时禁用 —— 实测在
        // 某些切换（规则→全局）上会让 xray 卡死、之后连全量重启都救不回来，疑似 xray-core
        // 在同一扩展进程内 stop→run 有全局状态没干净复位。扩展侧代码保留待查，这里先走全量重启。
        do {
            try await tunnelManager.configure(
                node: node,
                mode: settings.proxyMode,
                shareLink: shareLink,
                rules: effectiveUserRules,
                // 热切换 = 全量重启 = 新会话：定时按设置的时长**重新计时**（切节点/模式后
                // 从头再数）。不带旧剩余时间过去 —— 语义简单、扩展侧无需额外状态。
                autoStopSeconds: settings.autoStopSeconds,
                description: "轻舟 · \(node.name)"
            )
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
            // start() 只等"启动请求提交成功"，不等隧道真连上 —— 到这里就收窗口的话，
            // 开关会在 xray 还没就绪时就滑回"开"（规则模式加载 geo 那几秒尤其明显）。
            // 继续轮询到 .connected 再结束"切换中"，动画的结束沿才真正跟着真实状态走。
            // 15 秒超时兜底：连不上也先收窗口，不把 UI 卡死在切换态（错误自会走系统 VPN 状态）。
            for _ in 0..<150 {
                if tunnelManager.status == .connected { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            logger.info("Clean-restart switched tunnel to \(node.name) / \(settings.proxyMode.rawValue)", category: "tunnel")
        } catch {
            tunnelError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            logger.error("Hot-switch failed: \(tunnelError ?? "?")", category: "tunnel")
            // 隧道确实死了：开关诚实地留在关位（修掉旧行为——失败后开关仍显示"开"）。
            // 和 startTunnel 的失败路径一样干净收尾：关 On-Demand 防止拿坏配置反复重连，
            // 再 stop() 让系统回收 TUN / 路由。pending 也作废——VPN 已关，等用户重新开。
            isVPNRunning = false
            pendingReapply = false
            try? await tunnelManager.setOnDemandEnabled(false)
            tunnelManager.stop()
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

    /// 进入 xray routing 的用户规则全集：**自定义在前 = 自定义优先于远程**
    /// （xray routing.rules 按序 first-match）。
    public var effectiveUserRules: [Rule] { customRules + remoteRules }

    public func addCustomRule(_ rule: Rule) {
        customRules.append(rule)
        logger.info("Added custom rule \(rule.lineForm)", category: "rules")
        persist()
        reapplyForRulesChange()
    }

    public func removeCustomRule(_ rule: Rule) {
        customRules.removeAll { $0.id == rule.id }
        persist()
        reapplyForRulesChange()
    }

    /// 「一键规则」的结果，UI 据此不用再猜发生了什么（toast 文案已在方法内给出）。
    public enum QuickRuleOutcome: Equatable, Sendable {
        case added(domain: String)                                     // 新增了一条规则
        case retargeted(domain: String, from: RuleTarget, to: RuleTarget) // 同域名已有规则，原地改目标
        case unchanged(domain: String)                                 // 同域名同目标，什么都没做
        case notADomain(host: String)                                  // 裸 IP / 无点主机名，DOMAIN-SUFFIX 不适用
    }

    /// 域名分析 / 连接页的「加入直连 / 代理 / 拒绝」一键规则入口。
    ///
    /// - host 先归并成主域名（registrable domain），规则形如 `DOMAIN-SUFFIX,youtube.com,PROXY`；
    /// - 自定义规则里已有同域名的 DOMAIN / DOMAIN-SUFFIX 时**原地改目标**而不是重复添加
    ///   （改目标顺手升级成 SUFFIX，覆盖全部子域名）；同域名同目标则告知「已存在」；
    /// - 走 addCustomRule 同款持久化 + 热切换路径，VPN 在跑且 rule 模式时立即生效；
    /// - 每种结果都有 toast 反馈。
    @discardableResult
    public func quickAddDomainRule(forHost host: String, target: RuleTarget) -> QuickRuleOutcome {
        let domain = DomainAnalyzer.registrableDomain(host)
        guard !HostClassifier.isBareIP(host), domain.contains(".") else {
            showToast("「\(host)」不是域名，无法生成域名规则")
            return .notADomain(host: host)
        }
        let targetName = Self.quickRuleTargetName(target)
        if let idx = customRules.firstIndex(where: {
            ($0.type == .domainSuffix || $0.type == .domain) && $0.value.lowercased() == domain
        }) {
            let old = customRules[idx].target
            guard old != target else {
                showToast("已有规则：\(customRules[idx].lineForm)")
                return .unchanged(domain: domain)
            }
            customRules[idx].target = target
            customRules[idx].type = .domainSuffix
            logger.info("Retargeted custom rule \(customRules[idx].lineForm) (was \(old.rawValue))",
                        category: "rules")
            persist()
            reapplyForRulesChange()
            showToast("\(domain) 已从\(Self.quickRuleTargetName(old))改为\(targetName)，规则已生效")
            return .retargeted(domain: domain, from: old, to: target)
        }
        addCustomRule(Rule(type: .domainSuffix, value: domain, target: target, comment: "一键添加"))
        showToast("已加入\(targetName)：\(domain)，规则已生效")
        return .added(domain: domain)
    }

    private static func quickRuleTargetName(_ t: RuleTarget) -> String {
        switch t {
        case .proxy:  return "代理"
        case .direct: return "直连"
        case .reject: return "拒绝"
        }
    }

    /// 规则集变了：VPN 在跑且是 rule 模式时热切换，让新规则立即对真实流量生效。
    /// global / direct 模式不吃规则，改规则不值得为此断流重启隧道。
    func reapplyForRulesChange() {
        guard settings.proxyMode == .rule else { return }
        // 没跑时 reapplyRunningTunnel 内部 guard 直接返回
        Task { await reapplyRunningTunnel() }
    }

    public func currentRuleEngine() -> RuleEngine {
        RuleEngine(rules: customRules + remoteRules)
    }

    // MARK: - 调度器

    /// 启动后台调度：根据设置定期跑自动择优 + 订阅刷新；同时启动示例连接产线（直到真隧道接入）。
    public func startSchedulers() {
        stopSchedulers()
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
            // 核心摄入永远先跑 —— 来源 App 标注只是可选增强，它的 XPC 绝不能阻塞连接列表。
            // （踩过的坑：filter 扩展关闭时 XPC await 悬死，循环卡在第一轮，连接页恒空。
            //   ⚠️ merge 时别把 ingestAccessLog 挪回 XPC 之后，这个顺序丢过一次。）
            ingestAccessLog()
            // 回翻：连接常在 map 落盘（appex 每秒才写一次）之前就被 ingest，只在解析那刻
            // 查一次会让这批连接永远顶着裸 IP（按域名搜不到、开「忽略 IP」时整行被藏）。
            backfillDomainNames()
            #if os(macOS)
            // 来源 App 标注开启时才走 XPC + 回填（FilterControlClient 带 2 秒超时兜底）。
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
            // 停止浏览后 ingest 不再产出批次，这里兜底把最后一批脏的域名历史补写掉
            flushDomainHistoryIfNeeded()
        }
    }

    #if os(macOS)
    /// 用最新的「源端口 → 来源 App」映射，回填还没标注来源的**活跃**连接。
    /// content filter 的 map 常晚于连接 ingest 才就绪，只在解析那刻查一次会漏掉大批连接。
    /// 只回填活跃的：已关闭连接的源端口可能早被系统回收给了别的 App，再回填就是误标
    /// （见 FeatureFlags.sourceAppLabeling 注释第 2 条）。
    private func backfillSourceApps() {
        guard !sourceAppMap.isEmpty else { return }
        for i in connectionTracker.connections.indices
        where connectionTracker.connections[i].sourceApp == nil && connectionTracker.connections[i].isActive {
            if let port = connectionTracker.connections[i].sourceAddress.split(separator: ":").last.map(String.init),
               let bundleID = sourceAppMap[port] {
                connectionTracker.connections[i].sourceApp = bundleID
            }
        }
    }
    #endif

    /// 用最新的「IP → 域名」映射，把已摄入连接里还是裸 IP 的 targetHost 回翻成域名。
    ///
    /// 为什么需要：appex 的 fakedns-map 每秒才落盘一次，连接（access log 行）常在对应
    /// DNS 应答进 map 之前就被 ingest —— 只在解析那刻查一次，这批连接会永远顶着裸 IP：
    /// 按域名搜不到、开「忽略 IP」时整行被藏（zhihu 验收反馈的可修部分）。
    ///
    /// 只改 targetHost（搜索/聚合用）并重算 matchedRule（host 变了命中会变）；
    /// targetAddress 保留 ip:port 原样 —— 那一行本来就该显示真实地址，
    /// 且 ConnectionTracker 的身份索引 key 是 ingest 时算好的字符串，不受字段就地修改影响。
    /// 已经落进 DomainDailyHistory 的按 IP 记录不回改（历史口径以 ingest 时刻为准）。
    /// internal 供单测直接驱动。
    func backfillDomainNames() {
        guard !fakeDNSMap.isEmpty else { return }
        var resolver: MatchedRuleResolver?
        for i in connectionTracker.connections.indices {
            guard let domain = fakeDNSMap[connectionTracker.connections[i].targetHost] else { continue }
            connectionTracker.connections[i].targetHost = domain
            let r = resolver ?? currentMatchedRuleResolver()
            resolver = r
            connectionTracker.connections[i].matchedRule = r.resolve(
                host: domain,
                route: DomainAnalyzer.routeCategory(connectionTracker.connections[i].route)
            )
        }
    }

    private func ingestAccessLog() {
        defer {
            // 每轮都老化一遍（即使没有新日志行）：xray access log 只记连接建立，
            // 超过 ConnectionTracker.idleTimeout 无活动的连接由这里判定为已关闭。
            connectionTracker.ageOut()
        }
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
        let resolver = currentMatchedRuleResolver()
        var newConnections: [Connection] = []
        newConnections.reserveCapacity(entries.count)
        for entry in entries {
            var conn = entry.makeConnection(proxyDisplayName: proxyName)
            // FakeDNS 的假 IP（198.18.x.x）→ 反查回真域名，连接列表/域名分析才有意义
            if let domain = fakeDNSMap[entry.targetHost] {
                conn.targetHost = domain
                conn.targetAddress = "\(domain):\(entry.targetPort)"
            }
            // matchedRule 回填：用户规则一致才认领，否则推断 xray 内置规则 / 「未命中」哨兵。
            // 必须在 FakeDNS 翻译**之后**做，否则拿假 IP 去匹配域名规则全落空。
            conn.matchedRule = resolver.resolve(
                host: conn.targetHost,
                route: DomainAnalyzer.routeCategory(conn.route)
            )
            // 源端口 → 来源 App（macOS content filter 标注的 bundle id）
            if let port = entry.sourceAddress.split(separator: ":").last.map(String.init),
               let bundleID = sourceAppMap[port] {
                conn.sourceApp = bundleID
            }
            // 同身份（源地址+目标+端口）重现 → 只刷新活跃时间，不重复插入。
            // 域名每日历史只统计 tracker 判定为**新连接**的（UDP/QUIC 同 socket 的重现
            // 不算新访问），否则「连接次数」会被灌水，和连接页的观感也对不上。
            if connectionTracker.ingest(conn) {
                newConnections.append(conn)
            }
        }
        recordDomainHistory(newConnections)
    }

    /// 隧道停止 → 所有仍活跃的连接立即归入「已关闭」。
    func markAllConnectionsClosed(at now: Date = Date()) {
        connectionTracker.closeAll(at: now)
    }

    /// 把一批新摄入的连接并进按天域名聚合，滚动清理后（节流）落盘。
    /// internal 供单测直接喂连接（ingestAccessLog 依赖 App Group 文件，测试环境没有）。
    func recordDomainHistory(_ newConnections: [Connection]) {
        guard !newConnections.isEmpty else { return }
        domainHistory.record(newConnections)
        domainHistory.prune()
        domainHistoryDirty = true
        flushDomainHistoryIfNeeded()
    }

    /// 有脏数据且距上次落盘 ≥ 节流间隔时写盘。摄入时和每轮 access log 轮询都会调 ——
    /// 后者保证停止浏览后最后一批脏数据也会在 ≤10 秒内补写，不会一直悬着。
    private func flushDomainHistoryIfNeeded() {
        guard domainHistoryDirty else { return }
        let now = Date()
        guard now.timeIntervalSince(domainHistorySavedAt) >= domainHistorySaveInterval else { return }
        domainHistorySavedAt = now
        domainHistoryDirty = false
        persistence.saveAsync(domainHistory, name: Self.domainHistoryFile)
    }

    /// 取当前规则集 + 代理模式对应的 matchedRule 回填器；输入没变时复用同一实例
    /// （保住内部 host→规则 缓存），变了才重建。key 用 Hasher 而不是逐条对比 ——
    /// 每 2 秒一次、几千条规则的 hash 是亚毫秒级，逐条 Equatable 对比反而更贵。
    private func currentMatchedRuleResolver() -> MatchedRuleResolver {
        var hasher = Hasher()
        hasher.combine(customRules)
        hasher.combine(remoteRules)
        hasher.combine(settings.proxyMode)
        let key = hasher.finalize()
        if let cached = matchedRuleResolver, key == matchedRuleResolverKey { return cached }
        let fresh = MatchedRuleResolver(rules: customRules + remoteRules, mode: settings.proxyMode)
        matchedRuleResolver = fresh
        matchedRuleResolverKey = key
        return fresh
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
            syncAutoStopState()   // 定时关闭：刷新倒计时 + 识别「扩展已按定时自停」
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
        }
    }

    /// 定时关闭的主 App 侧收尾（每秒调，轻量：读一个小 JSON 文件）：
    /// 1. 倒计时展示：VPN 开着且扩展标记了本次会话带定时 → 暴露 deadline 给首页；
    /// 2. 到点自停识别：扩展写了 stoppedAt 且隧道确实断了 → 开关归位 + toast。
    ///    这条路**不承担关 VPN 的正确性**（On-Demand 在启用定时的连接上本来就没开，
    ///    扩展 cancelTunnelWithError 后不会被拉回）—— 只是 UI 收尾，主 App 不在场也没事。
    private func syncAutoStopState() {
        guard !isSwitchingTunnel else { return }   // 热切换窗口内状态是过渡态，别误判
        // 文件名与 XrayCore.TunnelAppGroup.tunnelSessionName 一致（两模块互不依赖）
        let session = AppGroupStorage.read(TunnelSessionInfo.self, from: "tunnel-session")

        if isVPNRunning, let s = session, s.stoppedAt == nil,
           let deadline = s.deadline, deadline > Date() {
            autoStopDeadline = deadline
        } else {
            autoStopDeadline = nil
        }

        if isVPNRunning, let s = session, s.stoppedAt != nil,
           tunnelManager.status == .disconnected || tunnelManager.status == .invalid {
            isVPNRunning = false
            markAllConnectionsClosed()
            scheduleIPRefresh()
            showToast("已按定时自动断开 VPN")
            logger.info("Auto-stop observed from extension (stoppedAt=\(s.stoppedAt!))", category: "tunnel")
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

