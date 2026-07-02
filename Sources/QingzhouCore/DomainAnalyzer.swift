import Foundation

/// 域名维度的连接分析：把一批 `Connection` 按主域名聚合，做每日汇总，并给规则优化建议。
///
/// 数据来源是隧道上报的真实连接（access log 解析，见 AccessLogParser）。它回答：
/// 哪些域名走了代理 / 直连 / 被拒、命中了哪条规则、占了多少流量；进而提示"这个境外域名
/// 走了直连是不是该补条代理规则""这个国内域名走代理是不是该直连省流量"。
public enum DomainRoute: String, Sendable, Equatable {
    case proxy, direct, reject, mixed
}

public struct DomainStat: Sendable, Equatable, Identifiable {
    public var domain: String           // 归并后的主域名（registrable domain）
    public var connectionCount: Int
    public var uploadBytes: Int64
    public var downloadBytes: Int64
    public var route: DomainRoute        // 同域名多连接 route 不一致 → mixed
    public var lastMatchedRule: String   // 命中的规则源文本；空表示走了默认出站
    public var firstSeen: Date
    public var lastSeen: Date

    public var id: String { domain }
    public var totalBytes: Int64 { uploadBytes + downloadBytes }

    public init(domain: String, connectionCount: Int, uploadBytes: Int64, downloadBytes: Int64,
                route: DomainRoute, lastMatchedRule: String, firstSeen: Date, lastSeen: Date) {
        self.domain = domain
        self.connectionCount = connectionCount
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
        self.route = route
        self.lastMatchedRule = lastMatchedRule
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

public struct DailyDigest: Sendable, Equatable, Identifiable {
    public var day: Date                 // 当天 0 点
    public var domains: [DomainStat]
    public var proxyCount: Int
    public var directCount: Int
    public var rejectCount: Int

    public var id: Date { day }
    public var totalBytes: Int64 { domains.reduce(0) { $0 + $1.totalBytes } }

    public init(day: Date, domains: [DomainStat], proxyCount: Int, directCount: Int, rejectCount: Int) {
        self.day = day
        self.domains = domains
        self.proxyCount = proxyCount
        self.directCount = directCount
        self.rejectCount = rejectCount
    }
}

public struct RuleSuggestion: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case shouldProxy   // 境外域名走了直连，建议补代理规则
        case shouldDirect  // 国内域名走了代理，建议直连省流量
        case unmatched     // 未命中任何规则，走的默认出站
    }
    public var domain: String
    public var kind: Kind
    public var reason: String

    public var id: String { "\(domain)#\(kind.rawValue)" }

    public init(domain: String, kind: Kind, reason: String) {
        self.domain = domain
        self.kind = kind
        self.reason = reason
    }
}

public enum DomainAnalyzer {

    // MARK: - 聚合

    /// 聚合结果的排序维度。
    ///
    /// `.traffic` 是设计上的最终形态，但在接上 xray QueryStats 之前 per-连接字节恒 0
    /// （access log 不含字节数），按流量排序等于按域名字母排序还谎称「按流量」。
    /// UI 当前用 `.connections`（诚实展示），字节有真实来源后切回 `.traffic`。
    public enum SortDimension: Sendable {
        case traffic       // 总字节降序（需要真实流量数据）
        case connections   // 连接次数降序
    }

    /// 把连接按主域名聚合成统计，按 `sortBy` 维度降序（同值按域名字典序）。
    public static func aggregate(_ connections: [Connection],
                                 sortBy: SortDimension = .traffic) -> [DomainStat] {
        var map: [String: DomainStat] = [:]
        for c in connections {
            let domain = registrableDomain(c.targetHost)
            let r = routeCategory(c.route)
            if var s = map[domain] {
                s.connectionCount += 1
                s.uploadBytes += c.uploadBytes
                s.downloadBytes += c.downloadBytes
                if s.route != r { s.route = .mixed }
                s.lastMatchedRule = mergedRule(existing: s.lastMatchedRule, new: c.matchedRule)
                s.firstSeen = min(s.firstSeen, c.openedAt)
                s.lastSeen = max(s.lastSeen, c.openedAt)
                map[domain] = s
            } else {
                map[domain] = DomainStat(
                    domain: domain, connectionCount: 1,
                    uploadBytes: c.uploadBytes, downloadBytes: c.downloadBytes,
                    route: r, lastMatchedRule: c.matchedRule,
                    firstSeen: c.openedAt, lastSeen: c.openedAt
                )
            }
        }
        switch sortBy {
        case .traffic:
            return map.values.sorted {
                $0.totalBytes != $1.totalBytes ? $0.totalBytes > $1.totalBytes : $0.domain < $1.domain
            }
        case .connections:
            return map.values.sorted {
                $0.connectionCount != $1.connectionCount
                    ? $0.connectionCount > $1.connectionCount : $0.domain < $1.domain
            }
        }
    }

    /// 按天分组的每日汇总，最近的在前。
    public static func daily(_ connections: [Connection], calendar: Calendar = .current,
                             sortBy: SortDimension = .traffic) -> [DailyDigest] {
        let groups = Dictionary(grouping: connections) { calendar.startOfDay(for: $0.openedAt) }
        return groups.map { day, conns in
            let stats = aggregate(conns, sortBy: sortBy)
            return DailyDigest(
                day: day,
                domains: stats,
                proxyCount: stats.filter { $0.route == .proxy || $0.route == .mixed }.count,
                directCount: stats.filter { $0.route == .direct }.count,
                rejectCount: stats.filter { $0.route == .reject }.count
            )
        }
        .sorted { $0.day > $1.day }
    }

    // MARK: - 规则优化建议

    public static func suggestions(_ stats: [DomainStat]) -> [RuleSuggestion] {
        var out: [RuleSuggestion] = []
        for s in stats {
            let cn = isLikelyCN(s.domain)
            let unmatched = isUnmatchedRule(s.lastMatchedRule)
            if s.route == .direct && !cn && unmatched {
                out.append(.init(domain: s.domain, kind: .shouldProxy,
                                 reason: "境外域名走了直连且未命中规则，可能需要补一条代理规则"))
            } else if (s.route == .proxy || s.route == .mixed) && cn {
                out.append(.init(domain: s.domain, kind: .shouldDirect,
                                 reason: "国内域名走了代理，直连更快也省代理流量"))
            } else if unmatched && s.route != .reject && s.route != .proxy {
                // 只提示「直连/混合 却没命中规则」的情况。rule 模式下境外域名按默认策略
                // 走代理是预期行为，逐个刷「未命中」只会淹没真正有用的建议（历史误报源头）。
                out.append(.init(domain: s.domain, kind: .unmatched,
                                 reason: "未命中任何规则，走的是默认出站"))
            }
        }
        return out
    }

    /// matchedRule 是否为「未命中」语义：空串（未知/未回填）或明确的默认策略哨兵值。
    public static func isUnmatchedRule(_ rule: String) -> Bool {
        rule.isEmpty || rule == Connection.noMatchedRule
    }

    // MARK: - 辅助

    /// 取可注册主域名（registrable domain）。IP 原样返回；
    /// 普通域名取末两段；常见二级公共后缀（com.cn / co.uk 等）取末三段。
    /// 不引入完整 Public Suffix List —— 那是几千行的表，对统计聚合而言这套启发式够用。
    public static func registrableDomain(_ host: String) -> String {
        let h = host.lowercased()
        if h.isEmpty || h.contains(":") { return h }            // IPv6 等原样
        if h.allSatisfy({ $0.isNumber || $0 == "." }) { return h } // IPv4 原样
        let parts = h.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return h }
        let twoLevel: Set<String> = [
            "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
            "co.uk", "org.uk", "co.jp", "com.hk", "com.tw", "com.sg"
        ]
        let lastTwo = parts.suffix(2).joined(separator: ".")
        return twoLevel.contains(lastTwo) ? parts.suffix(3).joined(separator: ".") : lastTwo
    }

    /// `Connection.route` 字符串 → 路由类别。route 存的是「DIRECT / REJECT / 节点名」，
    /// 节点名一律视为代理。公开给摄入侧（matchedRule 回填、每日聚合）复用同一套归类。
    public static func routeCategory(_ r: String) -> DomainRoute {
        switch r.uppercased() {
        case "DIRECT": return .direct
        case "REJECT": return .reject
        default:       return .proxy
        }
    }

    /// 聚合时合并 matchedRule：真实规则文本优先于「未命中」哨兵/空串；
    /// 两个都是真实规则时保留后到的（"last" 语义）。internal 供 DomainDailyHistory 复用同一口径。
    static func mergedRule(existing: String, new: String) -> String {
        if !isUnmatchedRule(new) { return new }
        return isUnmatchedRule(existing) && !new.isEmpty ? new : existing
    }

    private static let cnKnownDomains: Set<String> = [
        "baidu.com", "qq.com", "taobao.com", "tmall.com", "jd.com", "weibo.com",
        "bilibili.com", "163.com", "alipay.com", "douyin.com", "alicdn.com", "qpic.cn"
    ]

    private static func isLikelyCN(_ domain: String) -> Bool {
        domain.hasSuffix(".cn") || cnKnownDomains.contains(domain)
    }
}
