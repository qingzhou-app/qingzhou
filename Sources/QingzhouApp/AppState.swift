import Foundation
import NetworkExtension
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

/// 顶层页面标识：iOS 是 TabView 的选中 tab，macOS 是侧栏选中项。
/// 放进 AppState 是为了让任意视图能编程式切页 —— 首页空态的「去节点页选择」等
/// 按钮要能跨 tab 跳转。不持久化（每次启动回到首页）。
public enum AppSection: String, CaseIterable, Hashable, Sendable {
    case home, nodes, subscriptions, rules, connections, logs, settings
}

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
    /// 当前展示的顶层页面（iOS tab / macOS 侧栏选中项）。视图直接双向绑定；
    /// 首页空态按钮等通过改它实现「跳到节点页 / 订阅页」。
    public var activeSection: AppSection = .home
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
    /// 自定义规则的命中计数（近 30 天，规则页「命中 N 次 / 可考虑删除」数据源）。
    /// ⚠️ 同 domainHistory：独立文件落本地，**不进 Snapshot**、不上 iCloud。
    public private(set) var ruleHitStats = RuleHitStats()
    /// 每节点环形测量历史（100 条/节点）—— NodeScorer 稳定性维度的数据源。key 用
    /// identityFingerprint（订阅刷新后 UUID 可能变、指纹稳定）。⚠️ 同 domainHistory：
    /// 独立文件落本地（`Self.nodeMetricsFile`），**不进 Snapshot**、不上 iCloud
    /// （测量值跨设备/网络不可比）。internal(set) 供单测直接灌历史。
    public internal(set) var nodeMetricsHistory = NodeMetricsHistory()
    /// 实时流量波形数据（滑动窗口）。appex 经 App Group 上报 `TrafficStats` 喂进来；
    /// 没开 VPN / 没真实上报时为空，UI 显示「等待流量」。
    public var trafficHistory = TrafficHistory(capacity: 60)
    /// 隧道扩展内存快照（iOS 对 NE 扩展有 50MB jetsam 硬上限 —— 超限即"断流"）。
    /// 最近一次从 App Group 读到的值：VPN 停着时是上次会话的残留（历史峰值仍有展示价值），
    /// 新鲜与否用 `tunnelMemoryIsLive` 区分。设置页「诊断」区显示。
    public internal(set) var tunnelMemory: TunnelMemoryStats?
    /// tunnelMemory 是否是活数据（扩展 3 秒内刚写的）。
    public var tunnelMemoryIsLive: Bool {
        guard let m = tunnelMemory else { return false }
        return abs(m.sampledAt.timeIntervalSinceNow) <= 3
    }
    /// 上次已在主 App 日志里记过的扩展内存告警数 —— 只对新增告警写日志，不重复刷。
    private var loggedMemoryWarningCount = 0
    /// 「隧道计划外断开」日志的去重闸：断一次只记一条，重新连上后复位。
    private var loggedUnexpectedTunnelDeath = false

    /// 已判定为「仅 IPv6」的域名（只有 AAAA、没有 A）。连接页据此打「仅 IPv6」徽标 ——
    /// 轻舟全链路 IPv4（保护 fakedns 分流，见 docs/IPV6.md），这类站点直连不可达，
    /// 标注出来让用户遇到时不迷惑。
    public private(set) var ipv6OnlyHosts: Set<String> = []
    private let ipv6Prober = IPv6OnlyProber()
    /// 已排队探测过的域名（成败都算），防重复调度；上限同 prober 的会话上限。
    private var ipv6ProbeScheduled: Set<String> = []
    public var settings: Settings = Settings()
    /// App 内「发现新版本」提示的数据源（非 nil 时 RootView 弹更新 alert）。
    /// App Store 版启动时静默查一次 iTunes Lookup API；未上架 / 失败 → 保持 nil，不打扰。
    public internal(set) var availableUpdate: AvailableUpdate?
    public var lastSpeedTestReport: SpeedTestReport?
    /// 正在测速的节点 id 集合 —— UI 据此在对应行显示旋转 loading。
    public var measuringNodeIds: Set<UUID> = []
    /// 正在测「经代理延迟」的节点 id 集合（VPN 开启时经隧道扩展 libXray Ping 真实走节点测）。
    /// 与 measuringNodeIds 独立 —— 两个维度可以各测各的。
    public var proxiedMeasuringNodeIds: Set<UUID> = []
    /// xray 内置 per-outbound 流量统计快照（代理/直连/拒绝拆分）。扩展每 2 秒经 App Group
    /// 上报；VPN 停了或数据过期时为 nil。与 TUN 层总量（trafficHistory）口径不同：
    /// 这里是应用层 payload 字节，供占比展示，不驱动波形。
    public internal(set) var outboundStats: XrayOutboundStats?
    /// didSet 是小组件的主刷新时机：连接成功 / 断开 / 定时自停 / 启动采认……所有改到
    /// 这个值的路径都会踢一脚 WidgetKit（拉模型，不踢它 30 分钟才兜底刷新）。
    public var isVPNRunning: Bool = false {
        didSet { if oldValue != isVPNRunning { WidgetRefresher.reload() } }
    }
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
    /// 本次隧道会话的起点（xray 真正跑起来那刻，非「用户按下开关」那刻）。首页据此显示
    /// 「已连接 1:23:45」。数据源与 autoStopDeadline 同一个 App Group 会话标记
    /// （扩展在 xray 起来后写 startedAt），每秒轮询刷新；断开清 nil。
    /// 热切换 = 全量重启 = 新会话，从新会话起点重新计时（与定时关闭的口径一致）。
    public internal(set) var connectedSince: Date?
    /// 本进程内最近一次提交隧道启动的时刻。用来过滤 App Group 里**上一次会话**的残留
    /// 标记文件：start 提交后到扩展写新标记之间有 1–3 秒窗口，旧文件的 startedAt 会让
    /// 「已连接时长」瞬间显示成几小时。只采纳不早于本次启动的 startedAt。
    private var lastTunnelStartAt: Date?
    /// 灵动岛 / 锁屏实时活动管家（E.19）。跨平台门面，macOS 上所有方法 no-op。
    /// 由 startTunnel 起、trafficPollingLoop 每秒推进、stopTunnel 结束。
    private let liveActivity = LiveActivityController()
    #if os(macOS)
    /// 「打开指定 App 自动连」的监听器（见 AppLaunchWatcher.swift）。settings 驱动启停。
    private var appLaunchWatcher: AppLaunchWatcher?
    /// 当前隧道是否由自动连拉起 —— 只有自动拉起的会话才在触发 App 全退出时自动断开，
    /// 用户手动开的 VPN 不能因为关掉某个 App 被误断。任何 stop 都会清掉。
    private var tunnelStartedByAutoConnect = false
    #endif
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
    /// 「浏览器可能在用 DoH」提示被用户点掉（连接页/域名分析共用）。
    /// 只在内存 —— 本会话不再弹，下次启动条件仍满足会再提示。
    public var dohNoticeDismissed = false
    /// iCloud vault 同步状态（设置页展示）。
    public internal(set) var cloudSyncStatus: CloudSyncStatus = .unknown
    /// 待确认的恢复候选（启动检查发现云端更新 / 用户从版本列表选了一份）。非 nil 时 UI 弹
    /// 确认 alert，alert 里会展示来源设备 / 时间 / 内容计数 —— 「0 订阅」一眼可见，防误恢复。
    public internal(set) var cloudRestoreOffer: VaultRestoreCandidate?
    /// 版本选择 sheet 是否在屏。⚠️ 专用稳定 Bool，与加载态解耦 —— sheet 的 isPresented
    /// binding **只依赖它**。之前 binding 读 `cloudVersionLoad != nil`，而 .loading →
    /// .loaded/.failed 的写入恰落在 sheet 呈现动画进行中（iCloud 元数据有缓存时 fetch
    /// 很快返回）→ mid-transition 重渲染打断呈现簿记，sheet 弹出后立即自己沉下去
    /// （真机复验 #18 二次打回）。加载完成 / 失败**绝不能**碰这个开关。
    public internal(set) var isCloudVersionSheetPresented = false
    /// 「立即恢复」的版本选择 sheet 内容态：点击瞬间置 .loading（sheet 同时呈现，iCloud
    /// 读取要 coordinated read / 可能触发下载，秒级 —— 不能让用户对着按钮干等），读取
    /// 完成再变 .loaded / .failed（失败在 sheet 内展示 + 可重试）。只驱动内容，不驱动呈现。
    public internal(set) var cloudVersionLoad: CloudVersionLoadState?
    /// 已加载出的版本列表（.loaded 时非 nil）。选择 / 关闭逻辑与测试读这个，别自己解包枚举。
    public var cloudVersionOptions: [VaultRestoreCandidate]? {
        if case .loaded(let options) = cloudVersionLoad { return options }
        return nil
    }
    /// 版本选择 sheet 里刚点选、等 sheet 完全收起后再进确认弹窗的候选。
    /// ⚠️ 不能在点选的同一刻直接置 `cloudRestoreOffer`：iOS 上 alert 会在 sheet 收起动画
    /// 进行中呈现 → 呈现层冲突，alert 被系统吞掉（真机现象：确认弹窗第一次自动消失、
    /// 第二次才正常）。sheet 的 onDismiss 回调 `presentPendingCloudRestoreOffer()` 接棒。
    public internal(set) var pendingCloudRestoreCandidate: VaultRestoreCandidate?

    public let logger: Logger
    public let subscriptionFetcher: SubscriptionFetcher
    public let nodeSelector: NodeSelector
    public let speedTestRunner: SpeedTestRunner
    public let persistence: Persistence
    public let tunnelManager: VPNTunnelManager
    /// 完整版 geo 数据的下载/版本管理（主备源 + sha256 校验）。测试可注入假下载器。
    public let geoData: GeoDataManager
    /// App Store 版本查询器（App 内更新提醒用）。测试可注入假实现跳过真实出网。
    let updateFetcher: any AppStoreVersionLookup
    /// iCloud Drive vault 的读写层。测试可注入指向临时目录的假容器。
    let cloudVault: CloudVaultStore
    /// 镜像到 iCloud 的防抖任务（连续 persist 只留最后一次）。internal 供测试 await。
    var cloudMirrorTask: Task<Void, Never>?
    /// 云端文档「还在下载中」时的延迟重试任务（新装机首启常见）。
    private var cloudStartupRetryTask: Task<Void, Never>?

    private var schedulerTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var trafficPollingTask: Task<Void, Never>?
    private var accessLogPollingTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var ipRefreshTask: Task<Void, Never>?
    /// 热切换进行中又来了新的切换请求（快速连点节点）：记 pending，当前轮收尾后再跑一轮。
    /// 不并发跑两个 reapply —— stop/start 交错会打架。
    /// 热切换的范围：nodeOnly = 只换节点（mode / 规则没变，可走扩展内原地换出口，
    /// 零断流）；full = 模式 / 规则 / 恢复等也变了，必须全量重启隧道。
    public enum ReapplyScope { case nodeOnly, full }
    /// 热切换进行中又来一次请求时的合并暂存：nil = 无 pending；full 吞并 nodeOnly。
    private var pendingReapplyScope: ReapplyScope?
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
    /// ruleHitStats 的独立持久化（节流模式与 domainHistory 完全一致）。
    static let ruleHitStatsFile = "rule-hit-stats"
    private var ruleHitStatsSavedAt = Date.distantPast
    private var ruleHitStatsDirty = false
    /// internal 供测试注入 0 关掉节流做确定性断言。
    var ruleHitStatsSaveInterval: TimeInterval = 10
    /// nodeMetricsHistory 的独立持久化（节流模式与 domainHistory 完全一致）。
    static let nodeMetricsFile = "node-metrics"
    private var nodeMetricsSavedAt = Date.distantPast
    private var nodeMetricsDirty = false
    /// internal 供测试注入 0 关掉节流做确定性断言。
    var nodeMetricsSaveInterval: TimeInterval = 10
    /// 分数黏性（自动择优）的连续轮次状态：挑战者要对**同一在位者**连续
    /// `autoSwitchScoreStreakRounds` 轮总分领先 ≥ `autoSwitchScoreMargin` 才放行切换。
    /// 内存态，重启清零（可接受：顶多多等一轮）。记录在位者指纹 —— 手动切换 / 恢复等
    /// 改变当前节点后，配对对不上号自动作废，无需在各切换入口埋钩子。
    private var scoreStreakChallenger: String?
    private var scoreStreakIncumbent: String?
    private var scoreStreakRounds = 0
    /// appex 写的「IP → 域名」映射，把 access log 的裸 IP 翻回域名。里面既有 fakedns
    /// 假 IP（198.18.x.x）也有真实 DNS 应答的 IP（rule 模式下 CN 域名走 AliDNS 拿真实 IP）。
    /// internal 供单测直接注入（backfillDomainNames 用例）。
    var fakeDNSMap: [String: String] = [:]
    /// content filter 扩展提供的「源端口 → 来源 App」映射（仅 macOS 使用）。
    /// 带时间戳的条目按「端口+时间窗」认领，端口复用不误标（SourceAppMap 注释有全景）。
    /// internal 供单测直接注入（SourceAppBackfillTests）。
    var sourceAppMap = SourceAppMap()
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
        cloudVault: CloudVaultStore? = nil,
        geoDataManager: GeoDataManager? = nil,
        updateFetcher: (any AppStoreVersionLookup)? = nil
    ) {
        self.logger = logger
        self.persistence = persistence
        self.subscriptionFetcher = subscriptionFetcher ?? SubscriptionFetcher(logger: logger)
        self.nodeSelector = nodeSelector ?? NodeSelector(logger: logger)
        self.speedTestRunner = speedTestRunner ?? SpeedTestRunner(logger: logger)
        self.tunnelManager = tunnelManager ?? VPNTunnelManager(logger: logger)
        self.cloudVault = cloudVault ?? CloudVaultStore()
        self.geoData = geoDataManager ?? GeoDataManager()
        self.updateFetcher = updateFetcher ?? AppStoreUpdateFetcher(logger: logger)

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
        // 规则命中计数：同 domainHistory 的隐私/落盘约定，首次运行从现在起跟踪
        var hits = persistence.load(RuleHitStats.self, name: Self.ruleHitStatsFile)
            ?? RuleHitStats()
        hits.prune()
        self.ruleHitStats = hits
        // 节点测量历史：同 domainHistory 的落盘约定。加载时清掉已不存在节点的指纹 ——
        // 订阅换代留下的孤儿历史别在文件里越攒越多
        var metrics = persistence.load(NodeMetricsHistory.self, name: Self.nodeMetricsFile)
            ?? NodeMetricsHistory()
        metrics.prune(keeping: Set(snapshot.nodes.map(\.identityFingerprint)))
        self.nodeMetricsHistory = metrics
        logger.info(
            "AppState restored: \(subscriptions.count) subs, \(nodes.count) nodes, \(customRules.count) custom rules",
            category: "app"
        )
        logger.setMinimumLevel(LogLevel(rawValue: settings.logLevel) ?? .info)
        // 语言选项只放出 zhHans / en：存量老值（跟随系统 / 繁中 / 日语）一次性迁移到简中，
        // 否则 Picker 无匹配 tag、显示为空（旧值来自下架前的版本或手改 JSON）
        if settings.language != .zhHans && settings.language != .en {
            settings.language = .zhHans
        }
        // 动态字符串（toast / 错误文案）的语言跟随 App 语言设置（静态 UI 靠 \.locale 环境值）
        L10n.setLanguage(settings.language)
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
    private func applySettingsSideEffects() {
        if let lvl = LogLevel(rawValue: settings.logLevel) {
            logger.setMinimumLevel(lvl)
        }
        // 语言切换即时生效：动态字符串（toast / 错误）改查对应语种的 lproj 子 bundle
        L10n.setLanguage(settings.language)
        // 「显示实时活动」开关变更即时生效：关掉立即结束在显示的活动，打开且在连则起。
        syncLiveActivity()
        #if os(macOS)
        syncAppLaunchWatcher()
        #endif
    }

    #if os(macOS)
    /// 同步「打开指定 App 自动连」监听器：开关开且触发列表非空才监听。幂等，可重复调。
    ///
    /// 语义（见 AppLaunchWatcher 头注释）：任一触发 App 启动 → 自动开 VPN；
    /// 最后一个触发 App 退出 → 自动断（仅断由自动连拉起的会话）。
    private func syncAppLaunchWatcher() {
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
        let localContentHash = try? VaultSnapshotNormalizer.contentHash(
            of: VaultSnapshotNormalizer.normalized(currentSnapshot()))
        // 旧版云文档头部没有 contentHash → 回退读全文计算一次（下次本机镜像后头部就有了）。
        // 只在「不比对就会弹窗」的情形下才多读这一次全文。
        var cloudContentHash = header?.contentHash
        if cloudContentHash == nil, let header,
           header.schemaVersion <= VaultDocument.currentSchemaVersion,
           header.revision > (lastSynced?.lastSyncedRevision ?? Int.min),
           let document = try? await cloudVault.loadDocument() {
            cloudContentHash = try? VaultSnapshotNormalizer.contentHash(
                of: VaultSnapshotNormalizer.normalized(document.snapshot))
        }
        switch VaultSyncLogic.startupAction(
            cloudHeader: header,
            lastSyncedRevision: lastSynced?.lastSyncedRevision,
            lastDeclinedRevision: lastSynced?.lastDeclinedRevision,
            cloudContentHash: cloudContentHash,
            localContentHash: localContentHash
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
            // 差异摘要在生成 offer 时就算好 —— alert 的 message 在呈现瞬间定格，事后补不进去
            var candidate = VaultRestoreCandidate(header: cloud)
            candidate.diffSummary = await cloudRestoreDiffSummary(for: candidate)
            cloudRestoreOffer = candidate
            cloudSyncStatus = Self.syncedStatus(from: lastSynced) ?? .unknown
            logger.info("iCloud vault newer (rev \(cloud.revision) from \(cloud.deviceName)) — offering restore", category: "cloud")
        case .adoptCloudRevision(let cloud):
            // 云端 revision 更高但用户内容与本机一致 → 静默跟进同步记录，不打扰用户
            let now = Date()
            try? persistence.save(
                VaultSyncState(lastSyncedRevision: cloud.revision, lastSyncedAt: now, lastMirroredContentHash: localContentHash),
                name: Self.vaultSyncStateName
            )
            cloudSyncStatus = .synced(now)
            logger.info("iCloud vault rev \(cloud.revision) has identical content — adopted silently", category: "cloud")
        case .skipDeclinedRevision(let cloud):
            cloudSyncStatus = Self.syncedStatus(from: lastSynced) ?? .unknown
            logger.info("iCloud vault rev \(cloud.revision) was declined before — not prompting again", category: "cloud")
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
                snapshot: snapshot,
                contentHash: contentHash
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
            showToast(L("读取 iCloud 数据失败：\(error.localizedDescription)"))
            logger.error("iCloud vault restore read failed: \(error)", category: "cloud")
            return
        }
        guard let document else {
            showToast(L("iCloud 上没有找到备份"))
            return
        }
        guard document.schemaVersion <= VaultDocument.currentSchemaVersion else {
            cloudSyncStatus = .incompatibleCloud(schemaVersion: document.schemaVersion)
            showToast(L("iCloud 数据来自更新版本的轻舟，请先升级 App"))
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
        if snapshot.nodes.isEmpty {
            showToast(L("已从 iCloud 恢复（\(snapshot.subscriptions.count) 个订阅、0 个节点）"))
        } else {
            showToast(L("已恢复（\(snapshot.subscriptions.count) 个订阅、\(snapshot.nodes.count) 个节点），正在测速择优…"))
        }

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

        // 恢复回来的节点没有本机延迟数据（上云前瞬态字段已剥离）—— 跟「首次添加订阅」
        // 一致：自动全量测速 + 择优，别留一列裸节点让用户手动挨个测。
        // 择优只改瞬态字段，persist 的防抖镜像会被内容去重跳过，不产生新 revision。
        // VPN 在跑且择优命中不同节点会热切换 —— 预期行为。
        if !nodes.isEmpty {
            await autoSelectBestNode()
            if let best = currentNode {
                showToast(L("已为你选择延迟最优节点：\(best.name)"))
            }
        }
    }

    /// 拒绝过 / 弹过没同步记录时，恢复提示场景下的状态展示：
    /// 没真正同步过（decline-only 的哨兵记录 lastSyncedRevision == 0）不能显示「最近同步」。
    private static func syncedStatus(from state: VaultSyncState?) -> CloudSyncStatus? {
        guard let state, state.lastSyncedRevision > 0 else { return nil }
        return .synced(state.lastSyncedAt)
    }

    /// 用户拒绝恢复：清掉提示，并把「拒绝过这个云端 revision」持久化 —— 否则只要云端
    /// 更新、本机又没编辑过，**每次启动都会重新弹**。本地依旧权威 —— 下次本地编辑会覆盖云端。
    public func declineCloudRestore() {
        if let offer = cloudRestoreOffer, offer.backupFileName == nil {
            // lastSyncedRevision == 0 是「从没同步过、但拒绝过恢复」的哨兵值
            // （nextRevision 用 max(...)+1，0 不影响；状态展示经 syncedStatus 过滤）。
            var syncState = persistence.load(VaultSyncState.self, name: Self.vaultSyncStateName)
                ?? VaultSyncState(lastSyncedRevision: 0, lastSyncedAt: .distantPast)
            syncState.lastDeclinedRevision = offer.header.revision
            try? persistence.save(syncState, name: Self.vaultSyncStateName)
        }
        cloudRestoreOffer = nil
    }

    /// 设置页「立即恢复 iCloud 数据」：列出云端当前版 + 最近几份历史版本（含来源设备 /
    /// 时间 / 内容计数），让用户挑 —— 即使主文档被某台设备的空数据覆盖，旧版本仍可找回。
    ///
    /// sheet **立即**呈现（.loading），iCloud 读取异步填充 —— 之前在呈现前同步 await
    /// 读取，真机上按钮点了却要等一两秒 sheet 才出现（复验 #18 反馈）。
    public func requestManualCloudRestore() async {
        isCloudVersionSheetPresented = true    // 先呈现 sheet，别让用户干等
        cloudVersionLoad = .loading
        await loadCloudVersionOptions()
    }

    /// 读取云端版本列表填充 sheet；sheet 内「重试」也走这里。
    /// 结果只在 sheet 还在屏时落地 —— 用户中途关掉 sheet，迟到的结果不能把 sheet 复活。
    /// ⚠️ 这里只写 `cloudVersionLoad`（内容态），绝不碰 `isCloudVersionSheetPresented`
    /// （呈现开关）—— 加载完成落在呈现动画中，动开关会把呈现中的 sheet 顶掉。
    public func loadCloudVersionOptions() async {
        guard isCloudVersionSheetPresented else { return }   // sheet 已被关掉
        cloudVersionLoad = .loading
        let result = await fetchCloudVersionOptions()
        guard isCloudVersionSheetPresented else { return }   // await 期间被关掉 → 丢弃迟到结果
        cloudVersionLoad = result
    }

    /// 纯读取：把云端主文档 + 历史备份拼成候选列表，不碰 UI 状态。
    private func fetchCloudVersionOptions() async -> CloudVersionLoadState {
        guard await cloudVault.isAvailable() else {
            return .failed(L("iCloud 不可用（未登录或未开启 iCloud Drive）"))
        }
        let mainHeader: VaultHeader?
        do {
            mainHeader = try await cloudVault.loadHeader()
        } catch let error as CloudVaultStore.StoreError where error == .notYetDownloaded {
            return .failed(L("iCloud 数据还在下载中，稍等片刻再试"))
        } catch {
            return .failed(L("读取 iCloud 数据失败：\(error.localizedDescription)"))
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
        guard !options.isEmpty else {
            // 也走 .failed 留在 sheet 内展示（带重试）—— iCloud 元数据可能还没同步完，
            // 稍后重试常常就有了；比 toast 一闪而过可操作性强。
            return .failed(mainHeader != nil
                ? L("iCloud 数据来自更新版本的轻舟，请先升级 App")
                : L("iCloud 上没有找到备份"))
        }
        // 差异摘要在这里（sheet 的异步加载）就算好：候选经 pending → onDismiss 原样进
        // 确认弹窗，与启动路径汇流到同一 alert；alert 呈现后 message 定格，事后补不进去。
        // 最多主文档 + maxBackups 份全文读取，都是本地已下载的小 JSON，可接受。
        for i in options.indices {
            options[i].diffSummary = await cloudRestoreDiffSummary(for: options[i])
        }
        // 只有一份也在列表里展示（点一下即进确认弹窗）——sheet 已经在屏了，
        // 自动收起再弹 alert 反而突兀。
        return .loaded(options)
    }

    /// 读取候选对应的云端全文，算「与本机配置的差异」一行摘要（确认弹窗展示）。
    /// 读不到 / schema 过新 → nil，弹窗降级为只显示云端计数 —— 摘要是锦上添花，不挡恢复。
    private func cloudRestoreDiffSummary(for candidate: VaultRestoreCandidate) async -> String? {
        let document: VaultDocument?
        if let fileName = candidate.backupFileName {
            document = try? await cloudVault.loadBackupDocument(fileName: fileName)
        } else {
            document = try? await cloudVault.loadDocument()
        }
        guard let document, document.schemaVersion <= VaultDocument.currentSchemaVersion else {
            return nil
        }
        return VaultDiff.between(local: currentSnapshot(), cloud: document.snapshot).summaryText
    }

    /// 用户在版本列表里选了一份 → 先收起 sheet，候选暂存；等 sheet 的 onDismiss
    /// （收起动画完成、呈现层空闲）再经 `presentPendingCloudRestoreOffer()` 进确认弹窗。
    ///
    /// ⚠️ 不能在这里直接置 `cloudRestoreOffer`：确认 alert 挂在 RootView，sheet 还在收起
    /// 时呈现 alert 会撞呈现层 —— iOS 上 alert 被系统吞掉 / 自动消失，且系统 dismiss 会经
    /// isPresented binding 的 set(false) 调 declineCloudRestore() 把候选也清掉，用户得再
    /// 走一遍流程（真机踩过：确认弹窗第一次自动消失，第二次才正常）。
    public func chooseCloudRestoreCandidate(_ candidate: VaultRestoreCandidate) {
        pendingCloudRestoreCandidate = candidate
        isCloudVersionSheetPresented = false
        cloudVersionLoad = nil
    }

    /// 版本选择 sheet 的 onDismiss 回调：呈现层已空闲，暂存的候选此刻才进确认弹窗。
    /// 取消关闭（没点选任何版本）时没有暂存候选，这里自然是 no-op。
    public func presentPendingCloudRestoreOffer() {
        guard let candidate = pendingCloudRestoreCandidate else { return }
        pendingCloudRestoreCandidate = nil
        cloudRestoreOffer = candidate
    }

    /// 关闭版本选择列表（含加载中 / 失败态）。在途的读取结果会被 loadCloudVersionOptions
    /// 的 guard 丢弃，不会把 sheet 复活。
    public func dismissCloudVersionOptions() {
        isCloudVersionSheetPresented = false
        cloudVersionLoad = nil
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
        // 手动切节点时若 VPN 在跑，也热切换立即生效（只换节点 → 走原地换出口快路径）
        if changed {
            Task { await reapplyRunningTunnel(scope: .nodeOnly) }
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
        lastTunnelStartAt = .distantPast
        scheduleIPRefresh()
        logger.info("Adopted running tunnel from system (status: \(tunnelManager.status.description))", category: "tunnel")
    }

    /// 系统 VPN 状态变化的实时监听 token（NEVPNStatusDidChange）。
    private var vpnStatusObserver: NSObjectProtocol?

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

    private func stopObservingVPNStatus() {
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
            if lastTunnelStartAt == nil { lastTunnelStartAt = .distantPast }
            scheduleIPRefresh()
            logger.info("VPN status synced from system: running (\(status.description))", category: "tunnel")
        } else if isVPNRunning, status == .disconnected || status == .invalid {
            // 只在终态翻「关」，.disconnecting 等瞬态不动，避免开关闪烁
            isVPNRunning = false
            logger.info("VPN status synced from system: stopped", category: "tunnel")
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
    public func startTunnel() async {
        // 截图 demo：模拟器没有 NE，真启动必失败弹错 → 只翻状态位维持「已连接」观感
        if ScreenshotDemoMode.isActive {
            isVPNRunning = true
            tunnelError = nil
            return
        }
        guard let node = currentNode else {
            tunnelError = VPNTunnelManager.TunnelError.noCurrentNode.errorDescription
            isVPNRunning = false
            return
        }

        guard let shareLink = NodeEncoder.shareLink(node) else {
            tunnelError = L("无法把节点编码成分享链接")
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
                description: L("轻舟 · \(node.name)")
            )
            try await tunnelManager.start()
            isVPNRunning = true
            lastTunnelStartAt = Date()   // 之后只认不早于此刻的会话标记（滤掉上次会话残留）
            tunnelError = nil
            logger.info("Tunnel started for node \(node.name)", category: "tunnel")
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
        guard settings.proxyMode != .direct else { return }
        let preferred = settings.proxiedTestTarget
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))   // 给 xray 出站起身时间，降低刚建链的误报
            guard let self, self.isVPNRunning, !self.isSwitchingTunnel else { return }
            // 多目标：任一通过即算联网。一个节点出口 reset Google 却能到 Cloudflare 是好节点，
            // 单点探测（旧实现只打 google/generate_204）会把这种节点误判成「无法访问外网」。
            for attempt in 0..<2 {
                if await Self.probeTunnelConnectivity(preferred: preferred) {
                    self.logger.info("Connectivity probe OK", category: "tunnel")
                    return
                }
                if attempt == 0 { try? await Task.sleep(for: .seconds(3)) }
                guard self.isVPNRunning, !self.isSwitchingTunnel else { return }
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

    private func performReapply(scope: ReapplyScope) async {
        guard isVPNRunning,
              let node = currentNode,
              let shareLink = NodeEncoder.shareLink(node) else { return }
        isSwitchingTunnel = true
        // 热切换里 isVPNRunning 不变但节点（providerConfiguration 里的节点名）变了 ——
        // 退出时踢一次小组件刷新，别让 widget 上的节点名停留在旧值。
        defer {
            isSwitchingTunnel = false
            WidgetRefresher.reload()
        }
        // 快路径：只换节点（mode / 规则没变）时先试扩展内原地换出口（libXray
        // SwitchOutbound 热替换 "proxy" handler）—— 隧道 / TUN / 路由 / DNS 全不动，
        // 零断流、系统 VPN 图标不闪。任何失败（xray 没在跑 / 节点构建失败 / 扩展
        // 超时）都回退到下面的全量重启，原安全网不变。
        if scope == .nodeOnly {
            do {
                // 先落盘新节点配置：扩展若之后被系统回收再由 On-Demand 拉起，用的是
                // providerConfiguration —— 不落盘会复活成旧节点。saveToPreferences
                // 不打扰运行中的隧道。
                try await tunnelManager.configure(
                    node: node,
                    mode: settings.proxyMode,
                    shareLink: shareLink,
                    rules: effectiveUserRules,
                    // 原地切换 = 同一会话延续：定时倒计时不重置（扩展侧计时器没动）
                    autoStopSeconds: settings.autoStopSeconds,
                    description: L("轻舟 · \(node.name)")
                )
                try await tunnelManager.switchNodeInPlace(node: node, shareLink: shareLink)
                markAllConnectionsClosed()   // 旧 handler 已关，旧代理连接全部终止
                verifyTunnelConnectivity()   // 新节点未必真可用，哨兵照跑
                logger.info("In-place switched outbound to \(node.name) — tunnel kept alive", category: "tunnel")
                return
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                logger.warn("In-place switch failed (\(reason)) — falling back to full restart", category: "tunnel")
            }
        }
        // 配置预检：趁旧隧道还在跑，先让扩展用同款构建流程校验新节点的配置（libXray
        // TestXray）。配置非法 → 不拆在跑的隧道，直接报错返回 —— 否则坏配置会把好隧道
        // 换成起不来的新会话，用户直接断网。预检本身没跑成（超时等）不拦：尽力而为继续切。
        do {
            try await tunnelManager.testNodeConfig(
                node: node, mode: settings.proxyMode, shareLink: shareLink, rules: effectiveUserRules
            )
        } catch VPNTunnelManager.TunnelError.configRejected(let reason) {
            tunnelError = L("已保持当前节点连接不变。切换目标节点配置无效：\(reason)")
            logger.error("Pre-switch config test rejected \(node.name): \(reason)", category: "tunnel")
            return   // 旧隧道原样保留
        } catch {
            logger.warn("Pre-switch config test unavailable (\(error)) — continuing switch", category: "tunnel")
        }
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
                description: L("轻舟 · \(node.name)")
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
            lastTunnelStartAt = Date()   // 新会话：时长从新会话标记重新计（滤掉旧标记残留）
            // start() 只等"启动请求提交成功"，不等隧道真连上 —— 到这里就收窗口的话，
            // 开关会在 xray 还没就绪时就滑回"开"（规则模式加载 geo 那几秒尤其明显）。
            // 继续轮询到 .connected 再结束"切换中"，动画的结束沿才真正跟着真实状态走。
            // 15 秒超时兜底：连不上也先收窗口，不把 UI 卡死在切换态（错误自会走系统 VPN 状态）。
            for _ in 0..<150 {
                if tunnelManager.status == .connected { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            // 恢复 On-Demand（与 configure 同一规则：定时会话不开）—— 切换窗口结束，
            // 扩展再被系统回收时仍能自动重连。
            if settings.autoStopSeconds <= 0 {
                try? await tunnelManager.setOnDemandEnabled(true)
            }
            verifyTunnelConnectivity()   // 热切换后同样要哨兵：配置合法 ≠ 节点真的可用
            logger.info("Clean-restart switched tunnel to \(node.name) / \(settings.proxyMode.rawValue)", category: "tunnel")
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

    /// 自动择优的触发来源：分数黏性只约束定时路径（schedulerLoop）—— 手动点「择优」、
    /// 添加订阅、云恢复都是用户主动动作，一轮就换（仍受 autoSwitchWorthRestart 幅度闸）。
    public enum AutoSelectOrigin: Sendable { case manual, scheduled }

    public func autoSelectBestNode(origin: AutoSelectOrigin = .manual) async {
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
                // 成功失败都落测量历史（含 burst 丢包率）—— 稳定性维度靠失败样本算
                self.recordNodeDirectMeasurement(
                    self.nodes[i], latencyMs: result.latencyMs,
                    lossFraction: result.lossFraction, at: testedAt)
            }
        }
        nodes = measured
        let previousId = currentNodeId
        if var best = pickBestRespectingRegions(from: measured) {
            // 分数黏性（仅自动路径）：挑战者总分须领先 ≥8 且连续 2 轮 —— 单轮领先大概率
            // 是测量抖动，为它整条隧道重启不值当（用户反馈过启停频繁）。测速结果照常落盘。
            if shouldHoldForScoreStickiness(origin: origin, challenger: best, incumbent: currentNode) {
                persist()
                return
            }
            // 黏性滞后：VPN 在跑且当前节点本轮仍可用时，新最优要显著更好才值得为它
            // 整条隧道重启。不够好就整轮收工 —— 连经代理精选也省了（少起临时 xray
            // 实例，扩展内存压力更小）。测速结果照常落盘，延迟列仍然是新的。
            if isVPNRunning, !isSwitchingTunnel, best.id != currentNodeId,
               let current = currentNode, !isEffectivelyExcluded(current),
               !Self.autoSwitchWorthRestart(currentMs: current.lastLatencyMs,
                                            bestMs: best.lastLatencyMs ?? .max) {
                logger.info("Auto-select keeps \(current.name) (\(current.lastLatencyMs ?? -1)ms): candidate \(best.name) (\(best.lastLatencyMs ?? -1)ms) not better enough to restart tunnel", category: "app")
                persist()
                return
            }
            // 经代理精选（VPN 在跑且开关开着）：直连绿色候选逐个真实走节点测，
            // 避开「直连快但出口绕路 / 已失效」的假好节点。VPN 没开时测不了，直接用直连结果。
            if settings.autoSelectUsesProxiedLatency, isVPNRunning, !isSwitchingTunnel {
                best = await refineWithProxiedLatency(fallback: best)
            } else if settings.autoSelectUsesProxiedLatency {
                // 静默跳过会让用户以为精选没跑（真机反馈过）—— 至少留下日志可查
                logger.info("Proxied refine skipped — VPN not running", category: "app")
            }
            currentNodeId = best.id
            logger.info("Auto-selected \(best.name) [\(best.region)] (direct \(best.lastLatencyMs ?? -1)ms / proxied \(best.lastProxiedLatencyMs ?? -1)ms)", category: "app")
        } else {
            logger.warn("Auto-select found no viable node", category: "app")
        }
        persist()
        // 节点变了且 VPN 在跑 → 热切换，立即生效（只换节点 → 走原地换出口快路径）
        if currentNodeId != previousId {
            resetScoreStreak()   // 换人了：旧的挑战者连续计数作废
            await reapplyRunningTunnel(scope: .nodeOnly)
        }
    }

    /// 直连延迟的「绿色」阈值（毫秒）—— 节点列表 chip 配色与经代理精选候选池共用同一口径。
    static let directGreenThresholdMs = 200
    /// 没有绿色候选时的退化候选数（取直连最快的前几个，别让精选完全没得跑）。
    private static let proxiedRefineFallbackCount = 3

    /// 经代理精选轮次计数（进程内，不持久化）—— 域名画像探测目标的 round-robin 推进用：
    /// 每次启用 Top-3 域名轮换的精选轮 +1，跨 3 轮覆盖 Top-3。重启归零无妨（只需推进）。
    private var proxiedProbeRound = 0

    /// 用「经代理延迟」在**直连为绿色**的候选池里精选最优（用户口径：不限前 5，
    /// 绿色列表全员参赛 —— 绿色说明到节点的线路健康，值得花时间实测出口质量；
    /// 黄/红直连本身已说明线路差，不浪费实测名额）。
    ///
    /// 直连延迟只反映「设备→节点」的距离：出口绕路的节点直连照样漂亮、密码错的节点
    /// 直连也测不出来。逐个真实走节点测全链路延迟（串行 —— 扩展 50MB 内存约束），
    /// 选最低者；**测不通的候选直接淘汰**（失效节点进不了当前节点）。
    /// 全部失败 → 退回直连最优，并 toast 说明（不能无声回退，用户会以为精选没跑）。
    private func refineWithProxiedLatency(fallback: Node) async -> Node {
        let viable = nodes.filter { !isEffectivelyExcluded($0) && $0.lastLatencyMs != nil }
        var pool = viable
        if let pref = settings.preferredRegion {
            let inPref = viable.filter { $0.region == pref }
            if !inPref.isEmpty { pool = inPref }
        }
        var candidates = pool
            .filter { ($0.lastLatencyMs ?? .max) < Self.directGreenThresholdMs }
            .sorted { ($0.lastLatencyMs ?? .max) < ($1.lastLatencyMs ?? .max) }
        if candidates.isEmpty {
            // 一个绿色都没有（网络差 / 节点普遍远）：退化取直连前几名，精选仍有意义
            candidates = Array(pool
                .sorted { ($0.lastLatencyMs ?? .max) < ($1.lastLatencyMs ?? .max) }
                .prefix(Self.proxiedRefineFallbackCount))
        }
        // 本轮经代理探测目标：用户未指定固定目标时，改用「Top-3 代理域名」轮换
        //（每轮换一个，成本与固定目标一致 —— 见 ProxiedProbePlanner），让经代理延迟反映
        // 真实访问的站点而非 generate_204；数据不足或用户指定了固定目标 → 回退固定目标。
        let roundTarget: String? = settings.proxiedTestTarget.isEmpty
            ? ProxiedProbePlanner.probeTarget(from: domainHistory, roundIndex: proxiedProbeRound)
            : nil
        if let roundTarget {
            proxiedProbeRound &+= 1
            logger.info("Proxied refine probing against user top domain: \(roundTarget)", category: "app")
        }
        var measured: [(node: Node, ms: Int)] = []
        var failedCount = 0
        for candidate in candidates {
            guard isVPNRunning, !isSwitchingTunnel else { break }   // 中途关了 VPN 就停
            if let ms = await measureProxiedLatency(candidate, showToastOnError: false,
                                                    targetOverride: roundTarget) {
                measured.append((candidate, ms))
            } else {
                failedCount += 1
            }
        }
        // 精选内核同样按总分选：延迟维用**当轮经代理实测值**（不带时间戳 = 新鲜，
        // 0.7 权重）与本轮直连（0.3）按分数混合，其余维度与直连轮同一口径。
        if var best = bestByScore(
            measured.map(\.node),
            latency: { node in measured.first { $0.node.id == node.id }?.ms ?? .max },
            score: { node in
                NodeScorer.score(
                    NodeScorer.Input(
                        directLatencyMs: node.lastLatencyMs,
                        proxiedLatencyMs: measured.first { $0.node.id == node.id }?.ms,
                        history: nodeMetricsHistory.samples(for: node.identityFingerprint),
                        peakDownBps: node.observedPeakDownBps,
                        rate: node.rateForComparison
                    ),
                    preferLowerRate: settings.preferLowerRate,
                    weights: NodeScorer.weights(for: settings.scoringProfile)
                )
            }
        ) {
            var bestMs = measured.first { $0.node.id == best.id }?.ms ?? -1
            // 黏性滞后（经代理维度）：精选想换掉当前节点、而当前节点本轮也实测过且
            // 没坏时，同样要求显著更好 —— 不为经代理延迟的抖动重启隧道。
            if best.id != currentNodeId,
               let current = measured.first(where: { $0.node.id == currentNodeId }),
               !Self.autoSwitchWorthRestart(currentMs: current.ms, bestMs: bestMs) {
                logger.info("Proxied refine keeps \(current.node.name) (\(current.ms)ms): \(best.name) (\(bestMs)ms) not better enough to restart tunnel", category: "app")
                best = current.node
                bestMs = current.ms
            }
            logger.info("Proxied refine picked \(best.name) (\(bestMs)ms, rate \(best.rateForComparison)) from \(candidates.count) green candidates (\(failedCount) failed)", category: "app")
            if failedCount > 0 {
                showToast(L("经代理精选完成：实测 \(candidates.count) 个候选，避开 \(failedCount) 个不可用节点"))
            }
            return best
        }
        logger.warn("Proxied refine: all \(candidates.count) candidates failed — falling back to direct best", category: "app")
        showToast(L("经代理精选：\(candidates.count) 个候选实测均失败，本次按直连结果选择"))
        return fallback
    }

    /// 自动择优的黏性滞后：VPN 运行中切换节点 = 全量隧道重启 = 图标闪烁 + 数秒断流，
    /// 所以当前节点仍健康时，新最优必须**显著**更快才值得切 —— 绝对值至少快
    /// `autoSwitchMinImprovementMs`，且相对当前延迟的降幅不低于 `autoSwitchImprovementRatio`
    /// （两条取较严者）。延迟抖动导致的「最优每轮易主」不再触发重启（用户反馈：启停频繁）。
    static let autoSwitchMinImprovementMs = 50
    static let autoSwitchImprovementRatio = 0.3

    /// 「为这个新最优重启隧道值不值」。当前节点本轮测速失败（nil）= 已坏，无条件放行。
    /// 只约束 VPN 运行中的切换 —— 没跑时改 currentNodeId 不花钱，调用方不该走这里。
    static func autoSwitchWorthRestart(currentMs: Int?, bestMs: Int) -> Bool {
        guard let currentMs else { return true }
        let floor = max(autoSwitchMinImprovementMs, Int(Double(currentMs) * autoSwitchImprovementRatio))
        return currentMs - bestMs >= floor
    }

    /// 从候选里选 `NodeScorer` 总分最高者 —— 自动择优的内核。旧「延迟最低 + 接近时
    /// 优先低倍率（tieBand）」被打分吸收：成本维连续参与加权，不再需要档位判定；
    /// 稳定性 / 带宽维度让「延迟低但抖动大」的节点不再稳赢。
    /// 平分时延迟低者优先，再平比名字 —— 选择结果必须确定，测试和用户观感都依赖这一点。
    private func bestByScore(
        _ candidates: [Node],
        latency: (Node) -> Int,
        score: (Node) -> NodeScorer.Score
    ) -> Node? {
        candidates.min { a, b in
            let sa = score(a).total
            let sb = score(b).total
            if sa != sb { return sa > sb }
            if latency(a) != latency(b) { return latency(a) < latency(b) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// 在测速结果里挑最佳节点，应用「地区排除」+「地区优先」+ NodeScorer 总分：
    /// 1. 先剔除有效排除（手动排除 / 地区排除）和测速失败的节点
    /// 2. 若设了优先地区且该地区有可用节点，从中选总分最高者
    /// 3. 否则全局选
    func pickBestRespectingRegions(from measured: [Node]) -> Node? {
        let viable = measured.filter { !isEffectivelyExcluded($0) && $0.lastLatencyMs != nil }
        guard !viable.isEmpty else { return nil }
        let latency: (Node) -> Int = { $0.lastLatencyMs ?? .max }
        if let pref = settings.preferredRegion {
            let inPref = viable.filter { $0.region == pref }
            if let best = bestByScore(inPref, latency: latency, score: scoreForAutoSelect) {
                return best
            }
        }
        return bestByScore(viable, latency: latency, score: scoreForAutoSelect)
    }

    /// 直连轮的节点总分。经代理延迟**带时间戳**喂进打分：NodeScorer 的 24h 新鲜度门槛
    /// 把陈旧值挡在延迟维之外 —— 「各节点 lastProxiedLatencyMs 新鲜度参差不公平」的
    /// 老顾虑由门槛统一解决，新鲜的经代理值（0.7 权重）与直连（0.3）按分数混合。
    func scoreForAutoSelect(_ node: Node) -> NodeScorer.Score {
        NodeScorer.score(
            NodeScorer.Input(
                directLatencyMs: node.lastLatencyMs,
                proxiedLatencyMs: node.lastProxiedLatencyMs,
                proxiedTestedAt: node.lastProxiedTestedAt,
                history: nodeMetricsHistory.samples(for: node.identityFingerprint),
                peakDownBps: node.observedPeakDownBps,
                rate: node.rateForComparison
            ),
            preferLowerRate: settings.preferLowerRate,
            weights: NodeScorer.weights(for: settings.scoringProfile)
        )
    }

    /// 分数黏性的门槛：挑战者总分须领先在位者的分数（锚点归一保证跨轮可比）。
    static let autoSwitchScoreMargin: Double = 8
    /// 分数黏性的持续轮数：领先须**连续**成立的自动择优轮数。
    static let autoSwitchScoreStreakRounds = 2

    /// 「分数黏性」判定 + 连续轮次状态推进。返回 true = 本轮按兵不动（保持当前节点）。
    ///
    /// 挑战者总分须比在位者高 ≥ `autoSwitchScoreMargin`，且对**同一在位者**连续
    /// `autoSwitchScoreStreakRounds` 轮成立才放行 —— 幅度 + 持续双滞后，抖动导致的
    /// 「最优每轮易主」不再频繁触发重启。三类直接放行：手动路径（用户主动要换，一轮
    /// 就换）、VPN 没跑（改 currentNodeId 不花钱）、在位者本轮测量失败或已被排除
    /// （可用性 > 稳定，沿用 autoSwitchWorthRestart 的 nil 放行语义）。
    /// 放行 ≠ 必切：下游还叠着 autoSwitchWorthRestart 的幅度闸。
    func shouldHoldForScoreStickiness(
        origin: AutoSelectOrigin,
        challenger: Node,
        incumbent: Node?
    ) -> Bool {
        guard origin == .scheduled, isVPNRunning, !isSwitchingTunnel,
              let incumbent, challenger.id != incumbent.id else {
            // 没有挑战局（手动 / VPN 没跑 / 最优就是在位者）：定时路径下连续性已中断
            if origin == .scheduled { resetScoreStreak() }
            return false
        }
        guard !isEffectivelyExcluded(incumbent), incumbent.lastLatencyMs != nil else {
            resetScoreStreak()
            return false
        }
        let challengerScore = scoreForAutoSelect(challenger).total
        let incumbentScore = scoreForAutoSelect(incumbent).total
        guard challengerScore - incumbentScore >= Self.autoSwitchScoreMargin else {
            resetScoreStreak()
            logger.info(
                "Score stickiness keeps \(incumbent.name) (\(String(format: "%.1f", incumbentScore))): challenger \(challenger.name) (\(String(format: "%.1f", challengerScore))) not ahead by \(Int(Self.autoSwitchScoreMargin))",
                category: "app"
            )
            return true
        }
        if scoreStreakChallenger == challenger.identityFingerprint,
           scoreStreakIncumbent == incumbent.identityFingerprint {
            scoreStreakRounds += 1
        } else {
            scoreStreakChallenger = challenger.identityFingerprint
            scoreStreakIncumbent = incumbent.identityFingerprint
            scoreStreakRounds = 1
        }
        if scoreStreakRounds >= Self.autoSwitchScoreStreakRounds {
            resetScoreStreak()
            return false
        }
        logger.info(
            "Score stickiness keeps \(incumbent.name) (\(String(format: "%.1f", incumbentScore))): challenger \(challenger.name) (\(String(format: "%.1f", challengerScore))) ahead, round \(scoreStreakRounds)/\(Self.autoSwitchScoreStreakRounds)",
            category: "app"
        )
        return true
    }

    private func resetScoreStreak() {
        scoreStreakChallenger = nil
        scoreStreakIncumbent = nil
        scoreStreakRounds = 0
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
                // 定时/手动测速轮同样落测量历史（含 burst 丢包率）—— 稳定性维度的免费
                // 样本源，不然只有择优轮攒数据，历史积累慢一半（两者默认同为 30 分钟档）。
                self.recordNodeDirectMeasurement(
                    self.nodes[i], latencyMs: result.latencyMs,
                    lossFraction: result.lossFraction, at: testedAt)
            }
        }
        persist()
    }

    // MARK: - 经代理延迟（VPN 开启时经隧道扩展 libXray Ping 真实走节点测）

    /// 给单个节点测「经代理延迟」：隧道扩展起临时 xray 实例、真实通过该节点发一次
    /// HTTP HEAD，量到的是「本机→节点→目标站点」全链路毫秒数 —— 与直连 TCP 握手 RTT
    ///（lastLatencyMs）是两个维度。只在 VPN 运行时可用（libXray 只在扩展进程里）；
    /// VPN 关闭时 UI 应引导用户用普通测速（直连维度）。
    /// - Returns: 成功时的毫秒数；失败返回 nil（并在 `showToastOnError` 时 toast 错误）。
    @discardableResult
    /// `targetOverride`：本轮经代理探测目标的显式覆盖（自动择优的域名画像轮换用，见
    /// `refineWithProxiedLatency`）。nil = 沿用 `settings.proxiedTestTarget`（手动单测走这条，
    /// 保持稳定可比的 Cloudflare 目标）。
    public func measureProxiedLatency(
        _ node: Node, showToastOnError: Bool = true, targetOverride: String? = nil
    ) async -> Int? {
        guard isVPNRunning else {
            if showToastOnError { showToast(L("经代理测速需要 VPN 运行中（直连延迟请用普通测速）")) }
            return nil
        }
        proxiedMeasuringNodeIds.insert(node.id)
        defer { proxiedMeasuringNodeIds.remove(node.id) }
        do {
            let target = targetOverride ?? settings.proxiedTestTarget
            let ms = try await tunnelManager.pingNode(node: node, targetURL: target)
            if let i = nodes.firstIndex(where: { $0.id == node.id }) {
                nodes[i].lastProxiedLatencyMs = ms
                nodes[i].lastProxiedTestedAt = Date()
                // 经代理实测并入同轮直连样本（打分/稳定性的历史数据源）
                recordNodeProxiedMeasurement(nodes[i], proxiedMs: ms)
            }
            persist()
            return ms
        } catch {
            // 失败也记录测试时间、清掉旧值 —— 「上次测出 80ms」挂在已坏节点上会误导。
            if let i = nodes.firstIndex(where: { $0.id == node.id }) {
                nodes[i].lastProxiedLatencyMs = nil
                nodes[i].lastProxiedTestedAt = Date()
            }
            persist()
            if showToastOnError {
                showToast(L("经代理测速失败：\((error as? LocalizedError)?.errorDescription ?? "\(error)")"))
            }
            logger.warn("Proxied ping failed for \(node.name): \(error)", category: "tunnel")
            return nil
        }
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
                showToast(L("已为你选择延迟最优节点：\(best.name)"))
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
            // 0 节点且原文格式无法识别（既不是 Clash / SIP008、也不是链接列表）：
            // 多半是链接填错 / 返回了 HTML 登录页，给醒目提示，别让用户对着空列表懵。
            // 订阅确实为空（Clash proxies:[] / SIP008 servers:[]）不算错误，走正常清空路径。
            if payload.nodes.isEmpty, !payload.formatRecognized {
                let msg = L("订阅格式无法识别，请确认链接正确（能否在浏览器里直接打开）")
                subscriptionErrors[subscription.id] = msg
                showToast(msg)
                logger.error("Subscription \(subscription.name): 格式无法识别（0 节点）", category: "subscription")
            } else {
                subscriptionErrors[subscription.id] = nil
            }
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
            showToast(L("「\(host)」不是域名，无法生成域名规则"))
            return .notADomain(host: host)
        }
        let targetName = Self.quickRuleTargetName(target)
        if let idx = customRules.firstIndex(where: {
            ($0.type == .domainSuffix || $0.type == .domain) && $0.value.lowercased() == domain
        }) {
            let old = customRules[idx].target
            guard old != target else {
                showToast(L("已有规则：\(customRules[idx].lineForm)"))
                return .unchanged(domain: domain)
            }
            customRules[idx].target = target
            customRules[idx].type = .domainSuffix
            logger.info("Retargeted custom rule \(customRules[idx].lineForm) (was \(old.rawValue))",
                        category: "rules")
            persist()
            reapplyForRulesChange()
            showToast(L("\(domain) 已从\(Self.quickRuleTargetName(old))改为\(targetName)，规则已生效"))
            return .retargeted(domain: domain, from: old, to: target)
        }
        addCustomRule(Rule(type: .domainSuffix, value: domain, target: target, comment: "一键添加"))
        showToast(L("已加入\(targetName)：\(domain)，规则已生效"))
        return .added(domain: domain)
    }

    /// 「可合并规则」建议的一键应用：删掉同域名的散规则，在第一条被替换规则的位置
    /// 插入一条 `DOMAIN-SUFFIX,主域名,目标`（保住 first-match 优先级），
    /// 走 addCustomRule 同款持久化 + 热切换路径。
    /// 建议已过期（规则被删/被改）时不动任何东西，返回 false。
    @discardableResult
    public func applyRuleMerge(_ suggestion: RuleMergeSuggestion) -> Bool {
        let ids = Set(suggestion.rules.map(\.id))
        // 过期检查：建议里的规则必须**全部**还在且目标未变 —— 部分失效时语义已经变了
        //（比如其中一条被改成了 REJECT），按过期处理让 UI 重新计算建议。
        let live = customRules.filter { ids.contains($0.id) }
        guard live.count == suggestion.rules.count,
              live.allSatisfy({ $0.target == suggestion.target }),
              let firstIdx = customRules.firstIndex(where: { ids.contains($0.id) }) else {
            showToast(L("规则已变化，建议已过期"))
            return false
        }
        customRules.removeAll { ids.contains($0.id) }
        let merged = Rule(type: .domainSuffix, value: suggestion.domain,
                          target: suggestion.target, comment: "合并自 \(suggestion.rules.count) 条规则")
        customRules.insert(merged, at: min(firstIdx, customRules.count))
        logger.info("Merged \(suggestion.rules.count) rules into \(merged.lineForm)", category: "rules")
        persist()
        reapplyForRulesChange()
        showToast(L("已合并 \(suggestion.rules.count) 条为 \(merged.lineForm)，规则已生效"))
        return true
    }

    private static func quickRuleTargetName(_ t: RuleTarget) -> String {
        switch t {
        case .proxy:  return L("代理")
        case .direct: return L("直连")
        case .reject: return L("拒绝")
        }
    }

    /// 规则集变了：VPN 在跑且是 rule 模式时热切换，让新规则立即对真实流量生效。
    /// global / direct 模式不吃规则，改规则不值得为此断流重启隧道。
    func reapplyForRulesChange() {
        guard settings.proxyMode == .rule else { return }
        // 没跑时 reapplyRunningTunnel 内部 guard 直接返回
        Task { await reapplyRunningTunnel() }
    }

    /// 下载完整版 geo 数据；成功后走规则变更同款热切换 —— 扩展重启时发现 App Group
    /// 里的完整版，datDir 切过去并解锁外国 GEOIP 码规则，用户不用手动关开 VPN。
    public func downloadFullGeoData() async {
        let ok = await geoData.downloadFullGeoIP()
        if ok {
            logger.info("完整版 geo 数据下载完成（来源：\(geoData.info?.sourceName ?? "?")）", category: "geo")
            reapplyForRulesChange()
        } else if case .failed(let message) = geoData.phase {
            logger.error("完整版 geo 数据下载失败：\(message)", category: "geo")
        }
    }

    public func currentRuleEngine() -> RuleEngine {
        RuleEngine(rules: customRules + remoteRules)
    }

    // MARK: - 调度器

    /// 启动后台调度：根据设置定期跑自动择优 + 订阅刷新；同时启动示例连接产线（直到真隧道接入）。
    public func startSchedulers() {
        // 截图 demo 模式：一切后台调度短路（测速/择优会覆盖演示数据，adopt 会翻掉
        // 伪造的连接态，iCloud 检查可能弹恢复框），见 ScreenshotDemoMode。
        if ScreenshotDemoMode.isActive { return }
        stopSchedulers()
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

        if settings.autoSelectTrigger == .onAppLaunch || settings.autoSelectTrigger == .onAppLaunchAndInterval {
            await autoSelectBestNode(origin: .scheduled)
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
                await autoSelectBestNode(origin: .scheduled)
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
            // 「仅 IPv6」标注：对新出现的域名后台查一次真实 A/AAAA（DoH 绕开 fakedns
            // 假 IP）。只有 AAAA 的站点在全 IPv4 链路下直连不可达 —— 打标 + 记日志，
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

    #if os(macOS)
    /// 用最新的「源端口 → 来源 App」映射，回填还没标注来源的**活跃**连接。
    /// content filter 的 map 常晚于连接 ingest 才就绪，只在解析那刻查一次会漏掉大批连接。
    /// 两道防误标：只回填活跃连接（已关闭的源端口可能早被回收给别的 App）；
    /// 带时间戳的条目还要过「flow 观测时刻 ≈ openedAt」的时间窗（SourceAppMap）。
    /// internal 供单测直接驱动。
    func backfillSourceApps() {
        guard !sourceAppMap.isEmpty else { return }
        for i in connectionTracker.connections.indices
        where connectionTracker.connections[i].sourceApp == nil && connectionTracker.connections[i].isActive {
            if let port = connectionTracker.connections[i].sourceAddress.split(separator: ":").last.map(String.init),
               let bundleID = sourceAppMap.bundleID(forPort: port, openedAt: connectionTracker.connections[i].openedAt) {
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
            let res = r.resolveDetailed(
                host: domain,
                route: DomainAnalyzer.routeCategory(connectionTracker.connections[i].route)
            )
            // 命中计数补记：ingest 时这条还是裸 IP（多半没认领任何用户规则），翻译成域名后
            // 才命中域名规则。只在回填**改变了**认领结果时补记，避免同一连接重复计数。
            if res.userRuleID != nil, res.ruleText != connectionTracker.connections[i].matchedRule {
                recordRuleHit(res.userRuleID, at: connectionTracker.connections[i].openedAt)
            }
            connectionTracker.connections[i].matchedRule = res.ruleText
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
            let resolution = resolver.resolveDetailed(
                host: conn.targetHost,
                route: DomainAnalyzer.routeCategory(conn.route)
            )
            conn.matchedRule = resolution.ruleText
            // 源端口 → 来源 App（macOS content filter 标注的 bundle id）。
            // openedAt 就是本次 ingest 时刻，时间窗校验挡掉「map 里还留着上一个占用
            // 该端口的 App」的陈旧条目。
            if let port = entry.sourceAddress.split(separator: ":").last.map(String.init),
               let bundleID = sourceAppMap.bundleID(forPort: port, openedAt: conn.openedAt) {
                conn.sourceApp = bundleID
            }
            // 同身份（源地址+目标+端口）重现 → 只刷新活跃时间，不重复插入。
            // 域名每日历史只统计 tracker 判定为**新连接**的（UDP/QUIC 同 socket 的重现
            // 不算新访问），否则「连接次数」会被灌水，和连接页的观感也对不上。
            if connectionTracker.ingest(conn) {
                newConnections.append(conn)
                // 命中计数：与域名历史同口径，只算 tracker 判定的新连接（重现不灌水）
                recordRuleHit(resolution.userRuleID, at: conn.openedAt)
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

    /// 记一次用户规则命中（id 为 nil = 这条连接没认领任何用户规则，直接忽略）。
    /// 节流落盘同 domainHistory 模式。internal 供单测直接驱动（ingest 依赖 App Group 文件）。
    func recordRuleHit(_ id: UUID?, at date: Date) {
        guard let id else { return }
        ruleHitStats.recordHit(id, at: date)
        ruleHitStats.prune()
        ruleHitStatsDirty = true
        flushRuleHitStatsIfNeeded()
    }

    /// 有脏数据且距上次落盘 ≥ 节流间隔时写盘；轮询循环每轮兜底调用（同 domainHistory）。
    func flushRuleHitStatsIfNeeded() {
        guard ruleHitStatsDirty else { return }
        let now = Date()
        guard now.timeIntervalSince(ruleHitStatsSavedAt) >= ruleHitStatsSaveInterval else { return }
        ruleHitStatsSavedAt = now
        ruleHitStatsDirty = false
        persistence.saveAsync(ruleHitStats, name: Self.ruleHitStatsFile)
    }

    /// 记一条直连测量样本进节点历史（成功失败都记 —— 稳定性维度靠失败样本算丢包率；
    /// `lossFraction` 是本轮 burst 的失败占比）。节流落盘同 domainHistory 模式。
    func recordNodeDirectMeasurement(
        _ node: Node, latencyMs: Int?, lossFraction: Double? = nil, at date: Date
    ) {
        nodeMetricsHistory.recordDirect(
            fingerprint: node.identityFingerprint, latencyMs: latencyMs,
            lossFraction: lossFraction, at: date)
        nodeMetricsDirty = true
        flushNodeMetricsIfNeeded()
    }

    /// 记一次经代理实测（同轮窗口内并入直连样本，见 `NodeMetricsHistory.recordProxied`）。
    func recordNodeProxiedMeasurement(_ node: Node, proxiedMs: Int) {
        nodeMetricsHistory.recordProxied(fingerprint: node.identityFingerprint, proxiedMs: proxiedMs)
        nodeMetricsDirty = true
        flushNodeMetricsIfNeeded()
    }

    /// 有脏数据且距上次落盘 ≥ 节流间隔时写盘；轮询循环每轮兜底调用（同 domainHistory ——
    /// 测量轮之间隔着几十分钟，不兜底的话最后一批脏数据会一直悬着）。
    func flushNodeMetricsIfNeeded() {
        guard nodeMetricsDirty else { return }
        let now = Date()
        guard now.timeIntervalSince(nodeMetricsSavedAt) >= nodeMetricsSaveInterval else { return }
        nodeMetricsSavedAt = now
        nodeMetricsDirty = false
        persistence.saveAsync(nodeMetricsHistory, name: Self.nodeMetricsFile)
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

    /// 被动带宽观测的记录下限（byte/s）：低于此的下行速率不算「跑出了带宽」，不更新峰值——
    /// 否则挂着不用时的零星小流量会把峰值定得毫无意义。100 KB/s ≈ 有真实下载在进行。
    private static let bandwidthObserveFloorBps: Int64 = 100 * 1024

    /// Live Activity（灵动岛/锁屏）单一同步入口（E.19）。幂等：
    /// - 设置关 / VPN 没在跑 / 无当前节点 → 结束任何在显示的活动；
    /// - 否则按当前状态起或刷新（`LiveActivityController.start` 内部决定 request/update/换节点）。
    ///
    /// 由 startTunnel 起点、trafficPollingLoop 每秒、设置开关变更三处驱动。速率取波形窗口
    /// 最新样本（无样本按 0），phase 取系统真实 VPN 状态，计时起点复用 `connectedSince`
    /// （与首页倒计时同一口径，扩展写的会话标记）。macOS 上 controller 全 no-op。
    private func syncLiveActivity() {
        guard settings.showLiveActivity, isVPNRunning, let node = currentNode else {
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
        liveActivity.start(nodeName: node.name, protocolName: node.protocolType.rawValue, state: state)
    }

    /// appex 经 App Group 上报的真实 `TrafficStats` 喂进波形窗口。UI 观察 `trafficHistory` 自动重绘。
    /// 顺手做**被动带宽观测**：把当前节点跑出的下行速率峰值记到该节点上（零额外流量）。
    public func ingestTrafficStats(_ stats: TrafficStats) {
        trafficHistory.record(stats)
        recordObservedBandwidth(downBps: stats.downloadSpeedBps)
    }

    /// 把当前节点跑出的下行速率并入它的观测峰值。只在有明显下载（≥ floor）且刷新了峰值时
    /// 才落盘 —— 峰值只增不减、更新很稀疏，不会每秒刷盘。
    private func recordObservedBandwidth(downBps: Int64) {
        guard downBps >= Self.bandwidthObserveFloorBps,
              let id = currentNodeId,
              let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
        if downBps > (nodes[idx].observedPeakDownBps ?? 0) {
            nodes[idx].observedPeakDownBps = downBps
            nodes[idx].observedBandwidthAt = Date()
            persist()
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
            syncAutoStopState()   // 定时关闭：刷新倒计时 + 识别「扩展已按定时自停」
            syncTunnelMemory()    // 扩展内存观测：读快照 + 新增告警转写进主 App 日志
            syncLiveActivity()    // 灵动岛/锁屏实时活动：每秒推进速率 + phase（主 App 前台时）
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
            // xray per-outbound 拆分（代理/直连占比）。扩展每 2 秒写一次，5 秒新鲜窗口；
            // 过期（VPN 停了 / 本会话没开 metrics）就收起，不显示残留数据。
            // "xray-stats" 与 XrayCore.TunnelAppGroup.xrayStatsName 一致（两模块互不依赖）。
            if let xs = AppGroupStorage.read(XrayOutboundStats.self, from: "xray-stats"),
               abs(xs.sampledAt.timeIntervalSinceNow) <= 5 {
                outboundStats = xs
            } else if outboundStats != nil {
                outboundStats = nil
            }
        }
    }

    /// 「仅 IPv6」探测调度：交给 IPv6OnlyProber 后台经 DoH 查真实 A/AAAA，仅 IPv6 的
    /// 进 `ipv6OnlyHosts`（UI 提示 + 日志）。
    ///
    /// ⚠️ 数据源必须是 **fakedns-map**（浏览器解析过的所有域名），不能只用连接列表：
    /// 仅 IPv6 站点在全 IPv4 链路下**连不上、进不了连接列表**（access log 无它的连接），
    /// 但 fakedns 仍给它分过假 IP、落进 map —— 从连接列表取会永远漏掉最该标注的它们
    /// （真机 thiswebsiteisipv6only.com 案）。连接列表并进来只为兜底 map 尚未落盘的新域名。
    /// 每轮上限 8：新访问域名要够快被探到（access log 2 秒一轮），首次浏览的爆发量由
    /// `ipv6ProbeScheduled` 去重 + 会话上限跨轮摊平。
    private func probeIPv6OnlyCandidates() {
        let candidates = Set(fakeDNSMap.values).union(connectionTracker.connections.map(\.targetHost))
        var picked = 0
        for host in candidates {
            guard !HostClassifier.isBareIP(host),
                  ipv6ProbeScheduled.count < IPv6OnlyProber.sessionLimit,
                  !ipv6ProbeScheduled.contains(host) else { continue }
            ipv6ProbeScheduled.insert(host)
            picked += 1
            Task(priority: .utility) { [weak self] in
                guard let self, let verdict = await self.ipv6Prober.classifyIfNew(host: host) else { return }
                if verdict == .ipv6Only {
                    self.ipv6OnlyHosts.insert(host)
                    self.logger.warn(
                        "检测到仅 IPv6 站点 \(host)：该域名没有 IPv4 地址（只有 AAAA）。"
                        + "轻舟当前全 IPv4 链路（保护按域名分流）直连不可达；走代理时由节点解析、或可正常。"
                        + "设计取舍见 docs/IPV6.md",
                        category: "app")
                }
            }
            if picked >= 8 { break }
        }
    }

    /// 扩展内存观测的主 App 侧（每秒调，轻量：读一个小 JSON 文件）：
    /// 1. 刷新 `tunnelMemory` 给设置页「诊断」区显示（含 VPN 停后的历史峰值残留）；
    /// 2. 扩展侧新增的 40MB 越限告警转写进主 App 日志（LogsView 可见、可导出）——
    ///    扩展进程的 os_log 用户看不到，这里是它进 App 内日志页的通道。
    private func syncTunnelMemory() {
        // "memory-stats" 与 XrayCore.TunnelAppGroup.memoryStatsName 一致（两模块互不依赖）
        guard let stats = AppGroupStorage.read(TunnelMemoryStats.self, from: "memory-stats") else { return }
        tunnelMemory = stats
        if stats.warningCount > loggedMemoryWarningCount {
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

