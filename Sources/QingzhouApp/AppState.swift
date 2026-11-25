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
    public var currentNodeId: UUID? {
        didSet { selectionIntentGeneration &+= 1 }
    }
    var selectionIntentGeneration: UInt64 = 0
    /// 扩展确认的实际配置；当前选择只是用户请求，不能用于推断数据面的节点。
    public var appliedTunnelConfiguration: AppliedTunnelConfiguration? { tunnelSession.appliedConfiguration }
    var tunnelSession = TunnelSessionCoordinator()
    public var runningNode: Node? {
        guard let appliedTunnelConfiguration else { return nil }
        return nodes.first { appliedTunnelConfiguration.matches($0) }
    }
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
    public internal(set) var domainHistory = DomainDailyHistory()
    /// 扩展拥有的本地月度账本；主App只读，不写配置快照/云备份。
    public internal(set) var activeTrafficSessionID: String?
    public internal(set) var domainTrafficHistory: DomainTrafficLedger?
    public internal(set) var domainTrafficReadFailed = false
    var domainTrafficReadAt = Date.distantPast
    var domainTrafficReadGeneration = 0

    /// 自定义规则的命中计数（近 30 天，规则页「命中 N 次 / 可考虑删除」数据源）。
    /// ⚠️ 同 domainHistory：独立文件落本地，**不进 Snapshot**、不上 iCloud。
    public internal(set) var ruleHitStats = RuleHitStats()
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
    var loggedMemoryWarningCount = 0
    /// 「隧道计划外断开」日志的去重闸：断一次只记一条，重新连上后复位。
    var loggedUnexpectedTunnelDeath = false

    /// 已判定为「仅 IPv6」的域名（只有 AAAA、没有 A）。连接页据此打「仅 IPv6」徽标 ——
    /// 这类站点直连需要物理网络提供 IPv6（见 docs/IPV6.md），
    /// 标注出来让用户遇到时不迷惑。
    public internal(set) var ipv6OnlyHosts: Set<String> = []
    let ipv6Prober = IPv6OnlyProber()
    /// 已排队探测过的域名（成败都算），防重复调度；上限同 prober 的会话上限。
    var ipv6ProbeScheduled: Set<String> = []
    public var settings: Settings = Settings() {
        didSet {
            if oldValue.autoSelectUsesProxiedLatency != settings.autoSelectUsesProxiedLatency
                || oldValue.proxiedTestTarget != settings.proxiedTestTarget
                || oldValue.preferredRegion != settings.preferredRegion
                || oldValue.excludedRegions != settings.excludedRegions {
                proxyProbeContext &+= 1
                nodeProbeCooldown.reset()
            }
        }
    }
    /// App 内「发现新版本」提示的数据源（非 nil 时 RootView 弹更新 alert）。
    /// App Store 版启动时静默查一次 iTunes Lookup API；未上架 / 失败 → 保持 nil，不打扰。
    public internal(set) var availableUpdate: AvailableUpdate?
    public var lastSpeedTestReport: SpeedTestReport?
    public internal(set) var lastSelectionReport: NodeSelectionReport?
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
        didSet {
            if !isVPNRunning {
                tunnelSession.clearAppliedState()
            }
            if oldValue != isVPNRunning {
                invalidatePublicIPInfo()
                proxyProbeContext &+= 1
                nodeProbeCooldown.reset()
                WidgetRefresher.reload()
            }
        }
    }
    /// 热切换窗口标志：VPN 运行中切节点/模式触发全量重启（stop→start）期间为 true。
    /// UI 用它把开关滑到"关"、显示"切换中…"——跟真实断流窗口一致，不做假动画。
    /// 不翻转 isVPNRunning：那个承载"用户意图上 VPN 是开的"，被 reapply 入口 guard
    /// 和 NetworkInfoService（公网 IP 写哪栏）依赖。internal(set) 供 @testable 测试写入。
    public internal(set) var isSwitchingTunnel: Bool = false {
        didSet {
            if oldValue != isSwitchingTunnel {
                proxyProbeContext &+= 1
            }
        }
    }
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
    var lastTunnelStartAt: Date? { tunnelSession.startedAtFloor }
    /// 灵动岛 / 锁屏实时活动管家（E.19）。跨平台门面，macOS 上所有方法 no-op。
    /// 由 startTunnel 起、trafficPollingLoop 每秒推进、stopTunnel 结束。
    let liveActivity = LiveActivityController()
    #if os(macOS)
    /// 「打开指定 App 自动连」的监听器（见 AppLaunchWatcher.swift）。settings 驱动启停。
    var appLaunchWatcher: AppLaunchWatcher?
    /// 当前隧道是否由自动连拉起 —— 只有自动拉起的会话才在触发 App 全退出时自动断开，
    /// 用户手动开的 VPN 不能因为关掉某个 App 被误断。任何 stop 都会清掉。
    var tunnelStartedByAutoConnect = false
    #endif
    /// 当前 xray-core 版本。由 app 入口注入（QingzhouApp 库本身不依赖 XrayCore，避免拖进 380MB xcframework）。
    public var coreVersion: String?

    /// 公网 IP / 地理信息，由 NetworkInfoService 异步填充。
    public var publicIPInfo: PublicIPInfo?
    /// 绑定物理接口查询的出口 IP；VPN 开启时仍独立查询。
    public var directIPInfo: PublicIPInfo?
    /// 经运行中隧道的专用入口查询的节点出口。
    public var proxyIPInfo: PublicIPInfo?
    public var directIPFailed = false
    public var proxyIPFailed = false
    var ipRefreshGeneration = UUID()
    /// 远程规则源最近一次拉取时间 / 错误。
    public var remoteRulesStatus: RemoteFetchStatus = .idle
    /// 分流方案用的国内名单（direct.txt / cncidr.txt）最近一次状态。
    public var splitExitListsStatus = SplitExitListsStatus()
    /// 上次尝试刷新名单的时刻（只在内存）：用来做 24 小时节流，不用每 15 秒读一次文件。
    var lastSplitExitListsAttempt: Date?
    /// 订阅最近一次刷新错误（按 id 索引），仅保留最近一条错误信息。
    public var subscriptionErrors: [UUID: String] = [:]
    /// 轻量 toast 文案（自动择优、订阅添加等非阻塞反馈）。UI 浮层显示，几秒自动消失。
    public var toast: String?
    /// 「浏览器可能在用 DoH」提示被用户点掉（连接页/域名分析共用）。
    /// 只在内存 —— 本会话不再弹，下次启动条件仍满足会再提示。
    public var dohNoticeDismissed = false
    /// 当前「节点疑似故障」信号（扩展经 App Group 写、主 App 每秒读，见 syncNodeHealth）。
    /// 非 nil 且特性开时，首页显示红色横幅 + 一键切。仅在特性开 + opt-in + 信号新鲜时置位。
    public internal(set) var nodeHealthSuspect: NodeHealthSignal?
    /// 通知权限只申请一次的进程内去重标记（用户开「节点故障提醒」时触发）。
    var didRequestFailoverAuth = false
    /// UNUserNotificationCenter delegate 只挂一次。
    var didWireNotificationDelegate = false
    /// 故障提醒通知的点击回调 delegate（NSObject，须由 AppState 强持有 —— center.delegate 是 weak）。
    var failoverNotificationDelegate: AnyObject?
    /// iCloud vault 同步状态（设置页展示）。
    public internal(set) var cloudSyncStatus: CloudSyncStatus {
        get { cloudSyncCoordinator.status }
        set { cloudSyncCoordinator.status = newValue }
    }
    @ObservationIgnored lazy var cloudSyncCoordinator = CloudSyncCoordinator(state: self)
    /// 待确认的恢复候选（启动检查发现云端更新 / 用户从版本列表选了一份）。非 nil 时 UI 弹
    /// 确认 alert，alert 里会展示来源设备 / 时间 / 内容计数 —— 「0 订阅」一眼可见，防误恢复。
    public internal(set) var cloudRestoreOffer: VaultRestoreCandidate? {
        get { cloudRestoreCoordinator.offer }
        set { cloudRestoreCoordinator.offer = newValue }
    }
    let cloudRestoreCoordinator = CloudRestoreCoordinator()
    /// 版本选择 sheet 是否在屏。⚠️ 专用稳定 Bool，与加载态解耦 —— sheet 的 isPresented
    /// binding **只依赖它**。之前 binding 读 `cloudVersionLoad != nil`，而 .loading →
    /// .loaded/.failed 的写入恰落在 sheet 呈现动画进行中（iCloud 元数据有缓存时 fetch
    /// 很快返回）→ mid-transition 重渲染打断呈现簿记，sheet 弹出后立即自己沉下去
    /// （真机复验 #18 二次打回）。加载完成 / 失败**绝不能**碰这个开关。
    public var isCloudVersionSheetPresented: Bool { cloudRestoreCoordinator.isVersionSheetPresented }
    /// 「立即恢复」的版本选择 sheet 内容态：点击瞬间置 .loading（sheet 同时呈现，iCloud
    /// 读取要 coordinated read / 可能触发下载，秒级 —— 不能让用户对着按钮干等），读取
    /// 完成再变 .loaded / .failed（失败在 sheet 内展示 + 可重试）。只驱动内容，不驱动呈现。
    public var cloudVersionLoad: CloudVersionLoadState? { cloudRestoreCoordinator.versionLoad }
    /// 已加载出的版本列表（.loaded 时非 nil）。选择 / 关闭逻辑与测试读这个，别自己解包枚举。
    public var cloudVersionOptions: [VaultRestoreCandidate]? {
        cloudRestoreCoordinator.versionOptions
    }
    /// 版本选择 sheet 里刚点选、等 sheet 完全收起后再进确认弹窗的候选。
    /// ⚠️ 不能在点选的同一刻直接置 `cloudRestoreOffer`：iOS 上 alert 会在 sheet 收起动画
    /// 进行中呈现 → 呈现层冲突，alert 被系统吞掉（真机现象：确认弹窗第一次自动消失、
    /// 第二次才正常）。sheet 的 onDismiss 回调 `presentPendingCloudRestoreOffer()` 接棒。
    public var pendingCloudRestoreCandidate: VaultRestoreCandidate? { cloudRestoreCoordinator.pendingCandidate }

    public let logger: Logger
    public let subscriptionFetcher: SubscriptionFetcher
    public let nodeSelector: NodeSelector
    public let speedTestRunner: SpeedTestRunner
    public let persistence: Persistence
    public let tunnelManager: VPNTunnelManager
    let proxiedProber: any ProxiedLatencyProbing
    let measurementNow: @MainActor () -> Date
    var nodeProbeCooldown = NodeProbeCooldown()
    var proxyMeasurementGeneration: [UUID: UUID] = [:]
    /// 会话/设置变化和手动重测使自动轮次及旧回执失效。
    var proxyProbeContext: UInt64 = 0
    public internal(set) var measurementNetworkID = UUID()
    var measurementNetworkStartedAt = Date()
    let measurementNetworkObserver = MeasurementNetworkObserver()
    var proxyBandwidthBaseline: XrayOutboundStats?
    var nodeProbePlanner = NodeProbePlanner()
    var bandwidthWindows: [String: RecentBandwidth] = [:]
    /// 经代理精选轮次计数（进程内，不持久化）—— 域名画像探测目标的 round-robin 推进用：
    /// 每次启用 Top-3 域名轮换的精选轮 +1，跨 3 轮覆盖 Top-3。重启归零无妨（只需推进）。
    var proxiedProbeRound = 0
    /// 完整版 geo 数据的下载/版本管理（主备源 + sha256 校验）。测试可注入假下载器。
    public let geoData: GeoDataManager
    /// App Store 版本查询器（App 内更新提醒用）。测试可注入假实现跳过真实出网。
    let updateFetcher: any AppStoreVersionLookup
    /// iCloud Drive vault 的读写层。测试可注入指向临时目录的假容器。
    let cloudVault: any CloudVaultAccess
    /// 镜像到 iCloud 的防抖任务（连续 persist 只留最后一次）。internal 供测试 await。
    var cloudMirrorTask: Task<Void, Never>? { cloudSyncCoordinator.mirrorTask }

    var schedulerTask: Task<Void, Never>?
    /// 主actor可在await处重入：一次只允许一个直连测量轮，结果按节点身份合并。
    var directMeasurementID: UUID?
    var subscriptionRefreshIDs: [UUID: UUID] = [:]
    var updateCheckTask: Task<Void, Never>?
    var trafficPollingTask: Task<Void, Never>?
    var accessLogPollingTask: Task<Void, Never>?
    var toastTask: Task<Void, Never>?
    var ipRefreshTask: Task<Void, Never>?
    var diagnosticGeneration = UUID()
    /// 系统 VPN 状态变化的实时监听 token（NEVPNStatusDidChange）。
    var vpnStatusObserver: NSObjectProtocol?
    /// 热切换进行中又来了新的切换请求（快速连点节点）：记 pending，当前轮收尾后再跑一轮。
    /// 不并发跑两个 reapply —— stop/start 交错会打架。
    /// 热切换的范围：nodeOnly = 只换节点（mode / 规则没变，可走扩展内原地换出口，
    /// 零断流）；full = 模式 / 规则 / 恢复等也变了，必须全量重启隧道。
    public enum ReapplyScope { case nodeOnly, full }
    /// 热切换进行中又来一次请求时的合并暂存：nil = 无 pending；full 吞并 nodeOnly。
    var pendingReapplyScope: ReapplyScope?
    /// QUIC 策略 auto 下，被 HTTP/3 实测判定「QUIC 走不通」的节点指纹集合。**本会话内存缓存**：
    /// 不落盘、不上云（换会话重探一次可接受，避免把一次网络抖动永久钉死）。key 用 identityFingerprint
    /// （订阅刷新后 UUID 可能变、指纹稳定）。命中 → auto 下该 hysteria2 节点也挡 QUIC。见 docs/QUIC.md。
    /// internal 供单测注入（quicRuntimeStatus 用例）。
    var quicKnownBrokenNodes: Set<String> = []
    /// auto 下 HTTP/3 实测**通过**的节点指纹集合。**纯观测态**：只喂设置页的「当前 QUIC 运行态」
    /// 状态行显示「实测通过」，不参与任何阻断决策（决策只认 quicKnownBrokenNodes / resolver）。
    /// 生命周期与 broken 集一致（本会话内存缓存）；每轮实测开始时移除该节点，回到「实测中」。
    /// internal 供单测注入。
    var quicProbePassedNodes: Set<String> = []
    /// access log 文件已读到的字节位置（增量读，不重复解析）。
    var accessLogOffset: UInt64 = 0
    /// matchedRule 回填器（内含 host→规则 缓存）。规则集 / proxyMode 变化时按 key 重建。
    var matchedRuleResolver: MatchedRuleResolver?
    var matchedRuleResolverKey: Int = 0
    /// domainHistory 的独立持久化文件名（不进 Snapshot —— 见 domainHistory 注释）。
    static let domainHistoryFile = "domain-history"
    /// domainHistory 上次落盘时间：浏览时每 2 秒都有新批次，逐批全量编码落盘太浪费，
    /// 节流到 ≥saveInterval 一次；停止浏览后由轮询循环把最后的脏数据补写掉
    /// （进程被杀最多丢 saveInterval 秒的聚合，可接受）。
    var domainHistorySavedAt = Date.distantPast
    var domainHistoryDirty = false
    /// internal 供测试注入 0 关掉节流做确定性断言。
    var domainHistorySaveInterval: TimeInterval = 10
    /// ruleHitStats 的独立持久化（节流模式与 domainHistory 完全一致）。
    static let ruleHitStatsFile = "rule-hit-stats"
    var ruleHitStatsSavedAt = Date.distantPast
    var ruleHitStatsDirty = false
    /// internal 供测试注入 0 关掉节流做确定性断言。
    var ruleHitStatsSaveInterval: TimeInterval = 10
    /// nodeMetricsHistory 的独立持久化（节流模式与 domainHistory 完全一致）。
    static let nodeMetricsFile = "node-metrics"
    var nodeMetricsSavedAt = Date.distantPast
    var nodeMetricsDirty = false
    /// internal 供测试注入 0 关掉节流做确定性断言。
    var nodeMetricsSaveInterval: TimeInterval = 10
    /// 分数黏性（自动择优）的连续轮次状态：挑战者要对**同一在位者**连续
    /// `autoSwitchScoreStreakRounds` 轮总分领先 ≥ `autoSwitchScoreMargin` 才放行切换。
    /// 内存态，重启清零（可接受：顶多多等一轮）。记录在位者指纹 —— 手动切换 / 恢复等
    /// 改变当前节点后，配对对不上号自动作废，无需在各切换入口埋钩子。
    var selectionHysteresis = NodeSelectionHysteresis()
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
    let filterControl = FilterControlClient()
    /// 测试注入点：默认从 App Group 读 root 中继凭据；单测可替换，避免触碰真实 App Group 文件。
    var loadGuardRelayCredentials: @MainActor () -> GuardRelayCredentials? = { GuardRelayCredentials.load() }
    #endif

    public init(
        logger: Logger = Logger(),
        persistence: Persistence = Persistence(directory: Persistence.defaultDirectory()),
        subscriptionFetcher: SubscriptionFetcher? = nil,
        nodeSelector: NodeSelector? = nil,
        speedTestRunner: SpeedTestRunner? = nil,
        tunnelManager: VPNTunnelManager? = nil,
        proxiedProber: (any ProxiedLatencyProbing)? = nil,
        cloudVault: (any CloudVaultAccess)? = nil,
        geoDataManager: GeoDataManager? = nil,
        updateFetcher: (any AppStoreVersionLookup)? = nil,
        measurementNow: @escaping @MainActor () -> Date = Date.init
    ) {
        self.measurementNow = measurementNow
        self.logger = logger
        self.persistence = persistence
        self.subscriptionFetcher = subscriptionFetcher ?? SubscriptionFetcher(logger: logger)
        self.nodeSelector = nodeSelector ?? NodeSelector(logger: logger)
        self.speedTestRunner = speedTestRunner ?? SpeedTestRunner(logger: logger)
        self.tunnelManager = tunnelManager ?? VPNTunnelManager(logger: logger)
        self.proxiedProber = proxiedProber ?? self.tunnelManager
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
        metrics.migrateLegacyIdentities(for: snapshot.nodes)
        metrics.prune(keeping: Set(snapshot.nodes.map(\.identityFingerprint)))
        self.nodeMetricsHistory = metrics
        measurementNetworkDidChange()
        logger.info(
            "AppState restored: \(subscriptions.count) subs, \(nodes.count) nodes, \(customRules.count) custom rules",
            category: "app"
        )
        logger.setMinimumLevel(LogLevel(rawValue: settings.logLevel) ?? .info)
        // 语言选项放出 zhHans / zhHant / en / ja 四种固定语言；存量老值（.system）
        // 一次性迁移到简中，否则 Picker 无匹配 tag、显示为空（旧值来自下架前的版本或手改 JSON）
        if ![AppLanguage.zhHans, .zhHant, .en, .ja].contains(settings.language) {
            settings.language = .zhHans
        }
        // 动态字符串（toast / 错误文案）的语言跟随 App 语言设置（静态 UI 靠 \.locale 环境值）
        L10n.setLanguage(settings.language)
    }

    // MARK: - 持久化

    /// 把当前状态序列化落盘。异步执行 —— 主线程立即返回，编码 + 写盘在后台 utility 队列。
    /// 本地落盘后再（防抖地）镜像到 iCloud vault —— 本地是权威源，云端只是镜像。
    func persist() {
        let snapshot = currentSnapshot()
        cloudSyncCoordinator.scheduleMirror(after: saveCurrentSnapshot(snapshot), snapshot: snapshot)
    }

    /// 立即排入本地串行保存队列，完成后告知云同步是否可镜像。
    @discardableResult
    func saveCurrentSnapshot(_ savedSnapshot: Persistence.Snapshot? = nil) -> Task<Bool, Never> {
        let snapshot = savedSnapshot ?? currentSnapshot()
        let (results, completion) = AsyncStream<Result<Void, Error>>.makeStream()
        // 立即入串行保存队列；不能等MainActor上的Task启动才入队，测试flush/应用退出会漏掉写入。
        persistence.saveSnapshotAsync(snapshot) { result in
            completion.yield(result)
            completion.finish()
        }
        let saved = Task { @MainActor [weak self] in
            var iterator = results.makeAsyncIterator()
            guard let result = await iterator.next() else { return false }
            if case .failure(let error) = result {
                self?.logger.error("Configuration save failed: \(error)", category: "persistence")
                self?.showToast(L("配置保存失败，请检查设备剩余空间"))
                return false
            }
            return true
        }
        return saved
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
}

/// 远程拉取的轻量状态。
public enum RemoteFetchStatus: Sendable, Equatable {
    case idle
    case loading
    case success(at: Date, count: Int)
    case failure(message: String)
}

/// 分流方案国内名单的运行状态（设置页展示用）。
public struct SplitExitListsStatus: Sendable, Equatable {
    public var domainCount = 0
    public var cidrCount = 0
    /// 源文件总条数（去重与截断前），用于显示「30000/110251」
    public var sourceDomainCount = 0
    public var sourceCIDRCount = 0
    /// 采样前被内置 `geosite:cn` 去重移除的域名条数
    public var deduplicatedDomainCount = 0
    public var updatedAt: Date?
    public var error: String?
    public var isLoading = false

    public init() {}

    public var isLoaded: Bool { (domainCount > 0 || deduplicatedDomainCount > 0) && cidrCount > 0 }
}

/// 公网 IP / 地理信息。
public struct PublicIPInfo: Codable, Sendable, Equatable {
    public var ip: String
    public var country: String?
    public var region: String?
    public var city: String?
    public var isp: String?
    public var fetchedAt: Date
    /// 以下三项来自同一次查询（ipwho.is 一并返回），不额外发请求。
    /// 用途：对齐界面语言与时间显示时区（见 ExitRegionProfile）。
    public var countryCode: String?
    public var timezoneID: String?
    public var latitude: Double?
    public var longitude: Double?

    public init(ip: String, country: String? = nil, region: String? = nil, city: String? = nil,
                isp: String? = nil, fetchedAt: Date = Date(),
                countryCode: String? = nil, timezoneID: String? = nil,
                latitude: Double? = nil, longitude: Double? = nil) {
        self.ip = ip
        self.country = country
        self.region = region
        self.city = city
        self.isp = isp
        self.fetchedAt = fetchedAt
        self.countryCode = countryCode
        self.timezoneID = timezoneID
        self.latitude = latitude
        self.longitude = longitude
    }

    /// 出口地区画像（给「跟随出口地区」用）。
    public var exitRegion: ExitRegionProfile {
        ExitRegionProfile(countryCode: countryCode, country: country, city: city,
                          timezoneID: timezoneID, latitude: latitude, longitude: longitude)
    }
}
