import Foundation

/// 「可合并规则」建议：同一主域名下的多条 DOMAIN / DOMAIN-SUFFIX 同目标自定义规则，
/// 可替换为一条 `DOMAIN-SUFFIX,主域名,目标`。
public struct RuleMergeSuggestion: Sendable, Equatable, Identifiable {
    public var domain: String        // registrable domain（合并后规则的 value）
    public var target: RuleTarget
    /// 将被替换的规则，保持在 customRules 里的原有顺序（应用时用第一条的位置放合并规则）。
    public var rules: [Rule]

    public var id: String { "\(domain)#\(target.rawValue)" }
    /// 合并后规则的源文本形式（UI 预览用）。
    public var mergedLineForm: String {
        "\(RuleType.domainSuffix.rawValue),\(domain),\(target.rawValue)"
    }

    public init(domain: String, target: RuleTarget, rules: [Rule]) {
        self.domain = domain
        self.target = target
        self.rules = rules
    }
}

/// 自定义规则的收敛建议检测（域名分析「建议」tab 的「可合并」类建议）。
///
/// 只看 DOMAIN / DOMAIN-SUFFIX 且 value 是真域名的规则，按主域名分组：
/// - 同组 ≥ 2 条且**目标全部一致** → 建议合并为一条 DOMAIN-SUFFIX；
/// - 同组存在不同目标 → 恒不建议 —— 规则按序 first-match，合并成 SUFFIX 会吞掉
///   后面不同目标的精确规则（如 `DOMAIN,ads.example.com,REJECT`），改变分流行为。
///
/// 注意合并本身是**放宽**匹配（DOMAIN 精确 → SUFFIX 覆盖全部子域名），这是建议的
/// 本意（收敛规则表），UI 文案要把这点说出来，由用户决定。
public enum RuleConsolidator {

    public static func mergeSuggestions(customRules: [Rule]) -> [RuleMergeSuggestion] {
        var byDomain: [String: [Rule]] = [:]
        for rule in customRules where rule.type == .domain || rule.type == .domainSuffix {
            let value = rule.value.trimmingCharacters(in: .whitespaces).lowercased()
            // 裸 IP / 无点主机名不参与：DOMAIN-SUFFIX 对它们没有意义（同一键规则的判定）
            guard value.contains("."), !HostClassifier.isBareIP(value) else { continue }
            byDomain[DomainAnalyzer.registrableDomain(value), default: []].append(rule)
        }
        return byDomain.compactMap { domain, rules -> RuleMergeSuggestion? in
            guard rules.count >= 2 else { return nil }
            let target = rules[0].target
            guard rules.allSatisfy({ $0.target == target }) else { return nil }
            return RuleMergeSuggestion(domain: domain, target: target, rules: rules)
        }
        .sorted { $0.domain < $1.domain }
    }
}
