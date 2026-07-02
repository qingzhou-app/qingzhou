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
            // 内容级比较（lineForm）：每次 fetch 都会生成新 UUID，直接比 [Rule] 永远"变了"，
            // 会让每次定时刷新都重启隧道。只有规则内容真变了才热切换。
            let changed = rules.map(\.lineForm) != remoteRules.map(\.lineForm)
            remoteRules = rules
            remoteRulesStatus = .success(at: Date(), count: rules.count)
            if changed { reapplyForRulesChange() }
        } catch {
            remoteRulesStatus = .failure(message: "\(error)")
            logger.error("Refresh remote rules failed: \(error)", category: "rules")
        }
    }
}
