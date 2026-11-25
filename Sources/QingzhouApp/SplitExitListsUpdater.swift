import Foundation
import QingzhouCore
import QingzhouSubscription
import QingzhouLogging

/// 名单的落盘位置。抽成协议是为了能在单测里换成内存实现 ——
/// 测试环境没有 App Group entitlement，用真实现只会得到"写不进去"。
public protocol SplitExitListsStore: Sendable {
    func load() -> SplitExitLists?
    func save(_ lists: SplitExitLists) throws
}

/// 生产实现：写到 App Group 的 xray-data 目录，隧道扩展按同一路径读。
public struct AppGroupSplitExitListsStore: SplitExitListsStore {
    public init() {}

    static var storeURL: URL? {
        guard let dir = AppGroupStorage.xrayDataDirectoryURL else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(SplitExitListsFile.fileName)
    }

    public func load() -> SplitExitLists? {
        guard let url = Self.storeURL, let data = try? Data(contentsOf: url) else { return nil }
        return SplitExitListsFile.decode(data)
    }

    public func save(_ lists: SplitExitLists) throws {
        guard let url = Self.storeURL, let data = SplitExitListsFile.encode(lists) else {
            throw NSError(domain: "qingzhou.split-exit", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("无法写入 App Group 共享目录")])
        }
        try data.write(to: url, options: .atomic)
    }
}

/// 拉取并缓存「国内域名 / 国内 IP」名单（Loyalsoldier/clash-rules 的 direct.txt / cncidr.txt）。
///
/// 三条纪律，都是为了「更新失败不能把分流搞坏」：
/// 1. 两份名单**都**解析出条目才算成功；任何一份为空 / 拉不到 → 整体失败；
/// 2. 失败时保留上一份文件，绝不写空文件覆盖（否则下一次连接就只剩 geosite:cn 兜底）；
/// 3. 写完立刻回读校验，能读回同样条目数才算落地。
public actor SplitExitListsUpdater {
    public struct Outcome: Sendable, Equatable {
        /// 成功时是刚写入的名单；失败时是当前仍在用的旧名单（可能为 nil）。
        public var lists: SplitExitLists?
        public var error: String?
        public var usedCache: Bool
        public var metrics: SplitExitListMetrics?

        public init(lists: SplitExitLists?, error: String?, usedCache: Bool, metrics: SplitExitListMetrics? = nil) {
            self.lists = lists
            self.error = error
            self.usedCache = usedCache
            self.metrics = metrics
        }
    }

    /// Loyalsoldier 的 `release` 分支是构建产物分支，直接给可用的 txt；
    /// `master` 分支是源数据（需要构建），拉 master 会拿到另一种格式。
    public static let defaultSources: [URL] = [
        URL(string: "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/direct.txt")!,
        URL(string: "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/cncidr.txt")!
    ]

    private let client: HTTPClient
    private let logger: Logger?
    private let sources: [URL]
    private let store: SplitExitListsStore
    private let geoSiteCNMatcher: GeoSiteCNMatcher

    public init(client: HTTPClient = URLSessionHTTPClient(),
                logger: Logger? = nil,
                sources: [URL] = SplitExitListsUpdater.defaultSources,
                store: SplitExitListsStore = AppGroupSplitExitListsStore(),
                geoSiteCNMatcher: GeoSiteCNMatcher = .bundled) {
        self.client = client
        self.logger = logger
        self.sources = sources
        self.store = store
        self.geoSiteCNMatcher = geoSiteCNMatcher
    }

    /// 默认位置上的缓存（给 UI 在没触发刷新时先显示）。
    public static func loadCached() -> SplitExitLists? {
        AppGroupSplitExitListsStore().load()
    }

    /// 名单是否过期（默认 24 小时）。从未成功过也算过期，让启动后尽快拉一次。
    public static func isStale(_ lists: SplitExitLists?, maxAge: TimeInterval = 24 * 3600) -> Bool {
        guard let lists, let at = lists.fetchedAt else { return true }
        return Date().timeIntervalSince(at) >= maxAge
    }

    /// 拉一次。`force == false` 且缓存新鲜时直接返回缓存，不打网络。
    public func refresh(force: Bool = true) async -> Outcome {
        let cached = store.load()
        if !force, !Self.isStale(cached) {
            return Outcome(lists: cached, error: nil, usedCache: true)
        }
        guard sources.count == 2 else {
            return Outcome(lists: cached, error: L("名单源配置错误（需要域名与 IP 两份）"), usedCache: cached != nil)
        }

        var domains: [String] = []
        var keywords: [String] = []
        var cidrs: [String] = []
        var failures: [String] = []
        for (index, url) in sources.enumerated() {
            do {
                let (data, _) = try await client.get(url)
                guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                    failures.append(L("\(url.lastPathComponent)：响应为空或非 UTF-8"))
                    continue
                }
                if index == 0 {
                    let parsed = SplitExitListParser.parseDomains(text)
                    domains = parsed.domains
                    keywords = parsed.keywords
                } else {
                    cidrs = SplitExitListParser.parseCIDRs(text)
                }
                logger?.info("Split-exit list \(url.lastPathComponent): \(index == 0 ? domains.count : cidrs.count) 条", category: "rules")
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // 任何一份为空都算失败：只有域名没有 IP 名单（或反之）会让国内直连明显缺口，
        // 而且这种"半份"很难被用户察觉。宁可整份不更新。
        guard failures.isEmpty else {
            let message = failures.joined(separator: L("；"))
            logger?.error("Split-exit lists refresh failed: \(message)", category: "rules")
            return Outcome(lists: cached, error: message, usedCache: cached != nil)
        }
        guard !domains.isEmpty, !cidrs.isEmpty else {
            let message = L("解析结果为空（域名 \(domains.count) 条 / IP \(cidrs.count) 条），已保留上一份")
            logger?.error("Split-exit lists empty: \(message)", category: "rules")
            return Outcome(lists: cached, error: message, usedCache: cached != nil)
        }

        // 先剔除已被内置 `geosite:cn` 覆盖的域名，再对剩余条目按内存预算抽样。
        let rawDomainCount = domains.count + keywords.count
        let rawCIDRCount = cidrs.count
        let preDedupCount = domains.count
        domains = domains.filter { !geoSiteCNMatcher.isCovered($0) }
        let dedupRemovedCount = preDedupCount - domains.count
        let postDedupDomainCount = domains.count + keywords.count

        domains = SplitExitListSampler.sample(domains, limit: SplitExitListsLimits.domains)
        keywords = SplitExitListSampler.sample(keywords, limit: SplitExitListsLimits.keywords)
        cidrs = SplitExitListSampler.sample(cidrs, limit: SplitExitListsLimits.cidrs)
        let finalDomainCount = domains.count + keywords.count

        let metrics = SplitExitListMetrics(
            rawDomainCount: rawDomainCount,
            deduplicatedByGeoSiteCNCount: dedupRemovedCount,
            postDeduplicationDomainCount: postDedupDomainCount,
            finalDomainCount: finalDomainCount,
            rawCIDRCount: rawCIDRCount,
            finalCIDRCount: cidrs.count
        )

        let fresh = SplitExitLists(domains: domains, domainKeywords: keywords, cidrs: cidrs,
                                   sourceDomainCount: rawDomainCount,
                                   sourceCIDRCount: rawCIDRCount,
                                   deduplicatedDomainCount: dedupRemovedCount,
                                   fetchedAt: Date(), sources: sources.map(\.absoluteString))
        do {
            try store.save(fresh)
        } catch {
            return Outcome(lists: cached, error: L("写入失败：\(error.localizedDescription)"), usedCache: cached != nil)
        }
        // 回读校验：写出去了但读不回来（权限 / 磁盘）和没写是一回事，别告诉用户成功了。
        guard let readBack = store.load(),
              readBack.domains.count == domains.count,
              readBack.cidrs.count == cidrs.count else {
            return Outcome(lists: cached, error: L("写入后回读校验失败，已保留上一份"), usedCache: cached != nil)
        }
        logger?.info(
            "Split-exit lists updated: raw=\(rawDomainCount) dedupedGeoSiteCN=\(dedupRemovedCount) postDedup=\(postDedupDomainCount) final=\(finalDomainCount) domains / \(cidrs.count) cidrs (rawCIDRs=\(rawCIDRCount))",
            category: "rules"
        )
        return Outcome(lists: readBack, error: nil, usedCache: false, metrics: metrics)
    }
}

extension AppState {
    /// 启动/进设置页时把缓存状态读出来显示，不打网络。
    public func loadSplitExitListsStatus() {
        guard let lists = SplitExitListsUpdater.loadCached() else { return }
        splitExitListsStatus.domainCount = lists.domains.count + lists.domainKeywords.count
        splitExitListsStatus.cidrCount = lists.cidrs.count
        splitExitListsStatus.sourceDomainCount = lists.sourceDomainCount
        splitExitListsStatus.sourceCIDRCount = lists.sourceCIDRCount
        splitExitListsStatus.deduplicatedDomainCount = lists.deduplicatedDomainCount
        splitExitListsStatus.updatedAt = lists.fetchedAt
    }

    /// 刷新国内名单。`force == false` 时仅在缓存过期（>24h）才真正发请求。
    ///
    /// 名单变化后只在**分流正在跑**时才重连：普通模式下这份名单根本不参与分流，
    /// 为此断一次网没有道理。
    public func refreshSplitExitLists(force: Bool = true) async {
        #if os(macOS)
        guard !splitExitListsStatus.isLoading else { return }
        splitExitListsStatus.isLoading = true
        lastSplitExitListsAttempt = Date()
        let outcome = await SplitExitListsUpdater(logger: logger).refresh(force: force)
        splitExitListsStatus.isLoading = false
        splitExitListsStatus.error = outcome.error

        if let lists = outcome.lists {
            let changed = (lists.domains.count + lists.domainKeywords.count) != splitExitListsStatus.domainCount
                || lists.cidrs.count != splitExitListsStatus.cidrCount
            splitExitListsStatus.domainCount = lists.domains.count + lists.domainKeywords.count
            splitExitListsStatus.cidrCount = lists.cidrs.count
            splitExitListsStatus.sourceDomainCount = lists.sourceDomainCount
            splitExitListsStatus.sourceCIDRCount = lists.sourceCIDRCount
            splitExitListsStatus.deduplicatedDomainCount = lists.deduplicatedDomainCount
            splitExitListsStatus.updatedAt = lists.fetchedAt
            // 分流运行中且名单变了 → 重连才会带上新名单（配置在扩展启动时构建一次）。
            if changed, outcome.error == nil, isVPNRunning, settings.splitExitEnabled {
                await reapplyRunningTunnel()
            }
        } else if outcome.error != nil {
            logger.warn("Split-exit lists unavailable: \(outcome.error ?? "")", category: "rules")
        }
        #endif
    }

    /// 调度器每拍调用：24 小时一次，失败不重试到爆（失败也记 lastAttempt）。
    func refreshSplitExitListsIfDue() async {
        #if os(macOS)
        let last = lastSplitExitListsAttempt ?? .distantPast
        guard Date().timeIntervalSince(last) >= 24 * 3600 else { return }
        await refreshSplitExitLists(force: false)
        #endif
    }
}
