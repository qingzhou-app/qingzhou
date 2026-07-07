import Foundation

/// 经代理测速的探测目标规划：把固定的 Cloudflare 探测点换成「用户真实走代理、连接数
/// 最高的 Top-N registrable domain」，让经代理延迟反映「你常用的东西快不快」而非
/// generate_204。数据来源是 30 天 `DomainDailyHistory`（按主域名聚合，有 proxyCount）。
///
/// **内存 / 成本取舍（关键，见 docs/NODE-SCORING.md）**：经代理测速在扩展进程串行跑、
/// 受 38MB 内存护栏约束，每轮对每个节点只发**一次** HTTP。所以这里不是「每节点测 3 个
/// 域名」（那会 3× 成本 + 3× 时长，逼近内存/时间预算），而是**每轮从 Top-3 里轮流取一个**
/// （round-robin）作为该轮全体节点的统一探测目标 —— 单轮成本与今天完全一致
/// （1 目标 / 节点 / 轮），跨 3 轮覆盖 Top-3，稳定性历史（100 条环形）自然吸收不同真实
/// 域名间的差异。同轮所有节点打同一域名，延迟仍可横向比较。
///
/// 数据不足（走代理的域名 < `minProxiedDomains`）→ 返回 nil，调用方回退现有固定目标
/// （样本太少时 Top-N 不具代表性，不如稳定的 Cloudflare）。
public enum ProxiedProbePlanner {

    /// 参与轮换的 Top 域名数上限。
    public static let topN = 3
    /// 启用「域名画像探测」的最小走代理域名数：不足则回退固定目标。
    public static let minProxiedDomains = 3

    /// 30 天历史里「走代理、连接数最高」的 Top registrable domain，降序（proxyCount 高者在前，
    /// 同分按域名字典序升序保证确定性）。剔除裸 IP（无聚合价值）与 proxyCount==0 的域名
    /// （只走直连的不该拿来测代理）。
    public static func topProxiedDomains(
        from history: DomainDailyHistory, limit: Int = topN
    ) -> [String] {
        var totals: [String: Int] = [:]
        for (_, records) in history.days {
            for (domain, rec) in records where rec.proxyCount > 0 {
                if HostClassifier.isBareIP(domain) { continue }
                totals[domain, default: 0] += rec.proxyCount
            }
        }
        return totals
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map(\.key)
    }

    /// 某域名的探测 URL —— 直接打域名根，量「通过该节点访问你常用站点」的全链路延迟。
    public static func probeURL(for domain: String) -> String {
        "https://\(domain)/"
    }

    /// 本轮该用的经代理探测目标：走代理域名 ≥ `minProxiedDomains` 时，从 Top-N 里按
    /// `roundIndex` 轮换取一个；否则 nil（调用方回退固定目标）。`roundIndex` 由调用方
    /// 每轮自增（进程内计数即可，重启归零无妨 —— 轮换只需推进，不需持久化）。
    public static func probeTarget(
        from history: DomainDailyHistory, roundIndex: Int
    ) -> String? {
        let domains = topProxiedDomains(from: history)
        guard domains.count >= minProxiedDomains else { return nil }
        // 负数防御（不该发生）：先取模再补正，保证下标非负、不越界。
        let idx = ((roundIndex % domains.count) + domains.count) % domains.count
        return probeURL(for: domains[idx])
    }
}
