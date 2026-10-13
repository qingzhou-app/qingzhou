import Foundation
import QingzhouCore
import QingzhouRules
import QingzhouSubscription
import QingzhouLogging

/// 拉取远程规则文本 → 解析成 `[Rule]`。复用 QingzhouSubscription 的 HTTPClient 抽象。
public actor RemoteRulesFetcher {
    private let client: HTTPClient
    private let logger: Logger?

    public init(client: HTTPClient = URLSessionHTTPClient(), logger: Logger? = nil) {
        self.client = client
        self.logger = logger
    }

    public func fetch(_ url: URL) async throws -> [Rule] {
        logger?.info("Fetching remote rules from \(url)", category: "rules")
        let (data, _) = try await client.get(url)
        let text = String(data: data, encoding: .utf8) ?? ""
        let (rules, errors) = RuleParser.parseAll(text)
        if !errors.isEmpty {
            logger?.warn("Remote rules had \(errors.count) parse errors (kept first 3): \(errors.prefix(3).map(\.line).joined(separator: " | "))", category: "rules")
        }
        logger?.info("Loaded \(rules.count) remote rules", category: "rules")
        return rules
    }
}

extension AppState {
    /// 把 `settings.ruleSourceURL` 拉一遍，写入 `remoteRules`。
    public func refreshRemoteRules() async {
        guard let url = settings.ruleSourceURL else {
            logger.warn("ruleSourceURL is nil, skipping remote rules refresh", category: "rules")
            return
        }
        remoteRulesStatus = .loading
        let fetcher = RemoteRulesFetcher(logger: logger)
        do {
            let rules = try await fetcher.fetch(url)
            if applyFetchedRemoteRules(rules) { reapplyForRulesChange() }
        } catch {
            remoteRulesStatus = .failure(message: "\(error)")
            logger.error("Refresh remote rules failed: \(error)", category: "rules")
        }
    }

    /// 本进程刚启动时remoteRules为空，不能据此认定扩展中的规则也为空。
    /// 先提交读取结果，再按实际配置摘要决定是否重配；旧扩展仍走内容变化的安全回退。
    @discardableResult
    func applyFetchedRemoteRules(_ rules: [Rule]) -> Bool {
        let changed = rules.map(\.lineForm) != remoteRules.map(\.lineForm)
        remoteRules = rules
        remoteRulesStatus = .success(at: Date(), count: rules.count)
        #if DEBUG
        if changed { AcceptanceTrace.record(.remoteRulesChanged) }
        #endif
        guard isVPNRunning, settings.proxyMode == .rule else { return false }
        // 在途请求可能已捕获本进程的旧规则；旧实例摘要不能证明它将应用的新配置。
        // 保守排队full，当前轮完成后用新规则再收敛一次。
        if isSwitchingTunnel, changed { return true }
        if let applied = appliedTunnelConfiguration, applied.mode == .rule,
           let digest = applied.rulesDigest {
            return digest != AppliedTunnelConfiguration.digestRules(effectiveUserRules)
        }
        return changed
    }
}
