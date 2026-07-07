import Foundation

public enum AppearanceTheme: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case dark
}

public enum AppLanguage: String, Codable, Sendable, CaseIterable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case ja
}

/// 自动择优触发时机。
public enum AutoSelectTrigger: String, Codable, Sendable, CaseIterable {
    case onAppLaunch         // 每次 app 启动
    case interval            // 定时
    case onAppLaunchAndInterval
    case off
}

/// 打分预设档位 —— 三组权重的用户可见抽象（不暴露裸权重滑杆）。
/// 具体权重映射见 `NodeScorer.weights(for:)`；改选即生效下一轮自动择优。
/// - speed（速度优先）：延迟权重升、成本压低，只要快
/// - balanced（均衡，默认）：= P1 现状权重 0.45/0.30/0.15/0.10
/// - saver（省流量）：成本权重提到 0.30，优先低倍率
public enum ScoringProfile: String, Codable, Sendable, CaseIterable {
    case speed
    case balanced
    case saver
}

/// 全局设置 —— 持久化到 UserDefaults / 文件。
public struct Settings: Codable, Sendable {
    public var proxyMode: ProxyMode
    public var autoSelectTrigger: AutoSelectTrigger
    public var autoSelectIntervalSeconds: TimeInterval   // 仅在 .interval / 组合时有效
    /// 自动择优时用「经代理延迟」精选（VPN 运行中才生效）：直连延迟先排序取前几名，
    /// 再逐个真实走节点测全链路延迟选最优 —— 避开「直连快但出口绕路 / 已失效」的假好节点。
    public var autoSelectUsesProxiedLatency: Bool
    /// 经代理测速 + 连通性哨兵的探测目标 URL。空 = 用内置默认（Cloudflare，见 ConnectivityProbe）。
    /// 有些节点出口对 Google 会 reset，可在此改成其他站点或自己的可靠域名。
    public var proxiedTestTarget: String
    /// 自动择优时「延迟接近就优先低倍率节点」（省流量）。倍率见 NodeRateParser。
    public var preferLowerRate: Bool
    /// 打分预设档位（速度优先 / 均衡 / 省流量），映射三组打分权重（见 NodeScorer.weights(for:)）。
    /// 默认 .balanced（= P1 现状权重）。改选即生效下一轮自动择优。
    public var scoringProfile: ScoringProfile
    /// 后台周期性"只测速、不换节点"间隔，秒。0 = 关闭。
    /// 这跟 autoSelect 是两回事：autoSelect 会偷偷把 currentNodeId 改成最快的那个；
    /// 这个只刷新延迟列，currentNodeId 不动，让 UI 的延迟数据保持新鲜。
    public var autoMeasureIntervalSeconds: TimeInterval
    public var subscriptionRefreshIntervalSeconds: TimeInterval  // 订阅自动刷新间隔；0 表示关闭
    public var nodeSortOrder: NodeSortOrder
    /// 被排除的地区（如 ["香港"]）。这些地区的所有节点不参与自动择优、不会被自动选中。
    /// 解决 Anthropic / OpenAI 等对某些地区 IP 不开放的问题。
    public var excludedRegions: Set<String>
    /// 优先地区（如 "日本"）。自动择优时若该地区有可用节点，优先从中选最快的；
    /// 没有则回退到全局最快。nil = 无偏好。
    public var preferredRegion: String?
    public var ruleSourceURL: URL?                       // 远程规则集，可被覆盖
    public var launchAtLogin: Bool                       // macOS：开机自启
    public var logLevel: String                          // 用字符串以解耦 QingzhouLogging
    public var theme: AppearanceTheme
    public var language: AppLanguage
    /// macOS：开启「打开指定 App 自动连 VPN」。配合 autoConnectApps 用（见 AppLaunchWatcher）。
    public var autoConnectOnAppLaunch: Bool
    /// 触发自动连的 App bundle id 集合（如 ["com.tinyspeck.slackmacgap"]）。
    public var autoConnectApps: Set<String>
    /// 把配置镜像到 iCloud Drive 文档容器（vault）—— 卸载不丢数据、换设备可恢复。
    /// 默认开：数据只进用户自己的 iCloud，重装即有「自动恢复」的体验。
    public var iCloudSyncEnabled: Bool
    /// VPN 定时自动关闭（防忘关），秒。0 = 关闭（默认）。
    /// 语义是「本次连接」的定时：到点断开后不自动重开，手动重开重新计时。
    /// 倒计时在隧道扩展进程里生效 —— 主 App 被系统回收也照样到点关。
    public var autoStopSeconds: TimeInterval
    /// 用户「忽略此版本」选中的 App Store 版本号（App 内更新提醒用）。
    /// 同一版本不再提示；出了更新的版本（语义化比较更大）才会再提示。"" = 没忽略过任何版本。
    public var ignoredUpdateVersion: String

    public init(
        proxyMode: ProxyMode = .rule,
        autoSelectTrigger: AutoSelectTrigger = .onAppLaunch,
        autoSelectIntervalSeconds: TimeInterval = 30 * 60,
        autoSelectUsesProxiedLatency: Bool = true,
        proxiedTestTarget: String = "",
        preferLowerRate: Bool = true,
        scoringProfile: ScoringProfile = .balanced,
        autoMeasureIntervalSeconds: TimeInterval = 30 * 60,
        subscriptionRefreshIntervalSeconds: TimeInterval = 3600,
        nodeSortOrder: NodeSortOrder = .latency,
        excludedRegions: Set<String> = [],
        preferredRegion: String? = nil,
        ruleSourceURL: URL? = URL(string: "https://raw.githubusercontent.com/pexcn/daily/gh-pages/shadowrocket/whitelist.conf"),
        launchAtLogin: Bool = false,
        logLevel: String = "INFO",
        theme: AppearanceTheme = .system,
        language: AppLanguage = .zhHans,
        autoConnectOnAppLaunch: Bool = false,
        autoConnectApps: Set<String> = [],
        iCloudSyncEnabled: Bool = true,
        autoStopSeconds: TimeInterval = 0,
        ignoredUpdateVersion: String = ""
    ) {
        self.proxyMode = proxyMode
        self.autoSelectTrigger = autoSelectTrigger
        self.autoSelectIntervalSeconds = autoSelectIntervalSeconds
        self.autoSelectUsesProxiedLatency = autoSelectUsesProxiedLatency
        self.proxiedTestTarget = proxiedTestTarget
        self.preferLowerRate = preferLowerRate
        self.scoringProfile = scoringProfile
        self.autoMeasureIntervalSeconds = autoMeasureIntervalSeconds
        self.subscriptionRefreshIntervalSeconds = subscriptionRefreshIntervalSeconds
        self.nodeSortOrder = nodeSortOrder
        self.excludedRegions = excludedRegions
        self.preferredRegion = preferredRegion
        self.ruleSourceURL = ruleSourceURL
        self.launchAtLogin = launchAtLogin
        self.logLevel = logLevel
        self.theme = theme
        self.language = language
        self.autoConnectOnAppLaunch = autoConnectOnAppLaunch
        self.autoConnectApps = autoConnectApps
        self.iCloudSyncEnabled = iCloudSyncEnabled
        self.autoStopSeconds = autoStopSeconds
        self.ignoredUpdateVersion = ignoredUpdateVersion
    }

    /// 旧版没有这些 interval 字段；解码时给个默认值。
    enum CodingKeys: String, CodingKey {
        case proxyMode, autoSelectTrigger, autoSelectIntervalSeconds
        case autoSelectUsesProxiedLatency
        case proxiedTestTarget
        case preferLowerRate
        case scoringProfile
        case autoMeasureIntervalSeconds
        case subscriptionRefreshIntervalSeconds
        case nodeSortOrder, excludedRegions, preferredRegion
        case ruleSourceURL, launchAtLogin
        case logLevel, theme, language
        case autoConnectOnAppLaunch, autoConnectApps
        case iCloudSyncEnabled
        case autoStopSeconds
        case ignoredUpdateVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.proxyMode = try c.decodeIfPresent(ProxyMode.self, forKey: .proxyMode) ?? .rule
        self.autoSelectTrigger = try c.decodeIfPresent(AutoSelectTrigger.self, forKey: .autoSelectTrigger) ?? .onAppLaunch
        self.autoSelectIntervalSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .autoSelectIntervalSeconds) ?? 30 * 60
        self.autoSelectUsesProxiedLatency = try c.decodeIfPresent(Bool.self, forKey: .autoSelectUsesProxiedLatency) ?? true
        self.proxiedTestTarget = try c.decodeIfPresent(String.self, forKey: .proxiedTestTarget) ?? ""
        self.preferLowerRate = try c.decodeIfPresent(Bool.self, forKey: .preferLowerRate) ?? true
        // 缺失 or 未知档位值（未来新增档 / 手改文件）统一回落 .balanced：
        // c.decode 缺 key 或值无法解码都抛错，try? 一并吞掉。
        self.scoringProfile = (try? c.decode(ScoringProfile.self, forKey: .scoringProfile)) ?? .balanced
        self.autoMeasureIntervalSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .autoMeasureIntervalSeconds) ?? 30 * 60
        self.subscriptionRefreshIntervalSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .subscriptionRefreshIntervalSeconds) ?? 3600
        self.nodeSortOrder = try c.decodeIfPresent(NodeSortOrder.self, forKey: .nodeSortOrder) ?? .latency
        self.excludedRegions = try c.decodeIfPresent(Set<String>.self, forKey: .excludedRegions) ?? []
        self.preferredRegion = try c.decodeIfPresent(String.self, forKey: .preferredRegion)
        self.ruleSourceURL = try c.decodeIfPresent(URL.self, forKey: .ruleSourceURL)
            ?? URL(string: "https://raw.githubusercontent.com/pexcn/daily/gh-pages/shadowrocket/whitelist.conf")
        self.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        self.logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? "INFO"
        self.theme = try c.decodeIfPresent(AppearanceTheme.self, forKey: .theme) ?? .system
        // 语言选项：zhHans / zhHant / en / ja 均已放出（E.18 补齐繁中 + 日语翻译）。
        // 缺 key（旧持久化数据）或未知值统一回落 zhHans；enum case 全保留，向后兼容。
        self.language = (try? c.decode(AppLanguage.self, forKey: .language)) ?? .zhHans
        self.autoConnectOnAppLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoConnectOnAppLaunch) ?? false
        self.autoConnectApps = try c.decodeIfPresent(Set<String>.self, forKey: .autoConnectApps) ?? []
        self.iCloudSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .iCloudSyncEnabled) ?? true
        self.autoStopSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .autoStopSeconds) ?? 0
        self.ignoredUpdateVersion = try c.decodeIfPresent(String.self, forKey: .ignoredUpdateVersion) ?? ""
    }
}
