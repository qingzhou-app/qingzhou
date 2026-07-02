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

/// 全局设置 —— 持久化到 UserDefaults / 文件。
public struct Settings: Codable, Sendable {
    public var proxyMode: ProxyMode
    public var autoSelectTrigger: AutoSelectTrigger
    public var autoSelectIntervalSeconds: TimeInterval   // 仅在 .interval / 组合时有效
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

    public init(
        proxyMode: ProxyMode = .rule,
        autoSelectTrigger: AutoSelectTrigger = .onAppLaunch,
        autoSelectIntervalSeconds: TimeInterval = 30 * 60,
        autoMeasureIntervalSeconds: TimeInterval = 30 * 60,
        subscriptionRefreshIntervalSeconds: TimeInterval = 3600,
        nodeSortOrder: NodeSortOrder = .latency,
        excludedRegions: Set<String> = [],
        preferredRegion: String? = nil,
        ruleSourceURL: URL? = URL(string: "https://raw.githubusercontent.com/pexcn/daily/gh-pages/shadowrocket/whitelist.conf"),
        launchAtLogin: Bool = false,
        logLevel: String = "INFO",
        theme: AppearanceTheme = .system,
        language: AppLanguage = .system,
        autoConnectOnAppLaunch: Bool = false,
        autoConnectApps: Set<String> = [],
        iCloudSyncEnabled: Bool = true
    ) {
        self.proxyMode = proxyMode
        self.autoSelectTrigger = autoSelectTrigger
        self.autoSelectIntervalSeconds = autoSelectIntervalSeconds
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
    }

    /// 旧版没有这些 interval 字段；解码时给个默认值。
    enum CodingKeys: String, CodingKey {
        case proxyMode, autoSelectTrigger, autoSelectIntervalSeconds
        case autoMeasureIntervalSeconds
        case subscriptionRefreshIntervalSeconds
        case nodeSortOrder, excludedRegions, preferredRegion
        case ruleSourceURL, launchAtLogin
        case logLevel, theme, language
        case autoConnectOnAppLaunch, autoConnectApps
        case iCloudSyncEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.proxyMode = try c.decodeIfPresent(ProxyMode.self, forKey: .proxyMode) ?? .rule
        self.autoSelectTrigger = try c.decodeIfPresent(AutoSelectTrigger.self, forKey: .autoSelectTrigger) ?? .onAppLaunch
        self.autoSelectIntervalSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .autoSelectIntervalSeconds) ?? 30 * 60
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
        self.language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        self.autoConnectOnAppLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoConnectOnAppLaunch) ?? false
        self.autoConnectApps = try c.decodeIfPresent(Set<String>.self, forKey: .autoConnectApps) ?? []
        self.iCloudSyncEnabled = try c.decodeIfPresent(Bool.self, forKey: .iCloudSyncEnabled) ?? true
    }
}
