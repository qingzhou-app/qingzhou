import Foundation

/// 按天 × 主域名聚合的一条记录。**只有聚合结果，没有原始连接** ——
/// 访问历史属敏感数据，原始 Connection（含源地址、精确时刻）不落盘。
public struct DomainDayRecord: Codable, Sendable, Equatable {
    public var domain: String            // registrable domain（DomainAnalyzer.registrableDomain）
    public var connectionCount: Int
    public var proxyCount: Int           // 三个计数按连接的路由归类累加，和为 connectionCount
    public var directCount: Int
    public var rejectCount: Int
    public var lastMatchedRule: String   // 真实规则优先于「未命中」哨兵（同 DomainAnalyzer 聚合口径）
    public var firstSeen: Date
    public var lastSeen: Date

    public init(domain: String, connectionCount: Int, proxyCount: Int, directCount: Int,
                rejectCount: Int, lastMatchedRule: String, firstSeen: Date, lastSeen: Date) {
        self.domain = domain
        self.connectionCount = connectionCount
        self.proxyCount = proxyCount
        self.directCount = directCount
        self.rejectCount = rejectCount
        self.lastMatchedRule = lastMatchedRule
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// 域名分析「每日」视图的持久化数据源：按天滚动的域名聚合历史。
///
/// 为什么需要它：`AppState.connections` 只在内存保留最近 200 条，重启清零 ——
/// 在它上面做「每日」汇总是假历史。本结构在 access log 摄入时**增量更新**，
/// 由 AppState 落到本地 JSON（Persistence 目录），保留最近 `defaultKeepDays` 天。
///
/// ⚠️ 隐私：这是用户的访问历史。只存本地（Persistence 目录 / App 容器），
/// **不进 Persistence.Snapshot**，因此绝不会被 iCloud vault（只镜像 Snapshot）带上云。
public struct DomainDailyHistory: Codable, Sendable, Equatable {

    public static let defaultKeepDays = 30

    /// 天键（"2026-07-02"，本地历法/时区） → 主域名 → 聚合记录。
    /// 天键用字符串而不是 Date：Date 作字典键经 JSON 编码会退化成时间戳字面量，
    /// 且跨时区解释含糊；"yyyy-MM-dd" 直读直查。
    public var days: [String: [String: DomainDayRecord]] = [:]

    public init() {}

    public var isEmpty: Bool { days.isEmpty }

    // MARK: - 增量摄入

    /// 把一批新连接（每 2 秒的 access log 增量）并进当天聚合。
    public mutating func record(_ connections: [Connection], calendar: Calendar = .current) {
        for c in connections {
            let key = Self.dayKey(c.openedAt, calendar: calendar)
            let domain = DomainAnalyzer.registrableDomain(c.targetHost)
            let route = DomainAnalyzer.routeCategory(c.route)
            var rec = days[key]?[domain] ?? DomainDayRecord(
                domain: domain, connectionCount: 0, proxyCount: 0, directCount: 0,
                rejectCount: 0, lastMatchedRule: "", firstSeen: c.openedAt, lastSeen: c.openedAt
            )
            rec.connectionCount += 1
            switch route {
            case .proxy, .mixed: rec.proxyCount += 1   // 单连接不会是 mixed，防御性归代理
            case .direct:        rec.directCount += 1
            case .reject:        rec.rejectCount += 1
            }
            rec.lastMatchedRule = DomainAnalyzer.mergedRule(existing: rec.lastMatchedRule,
                                                            new: c.matchedRule)
            rec.firstSeen = min(rec.firstSeen, c.openedAt)
            rec.lastSeen = max(rec.lastSeen, c.openedAt)
            days[key, default: [:]][domain] = rec
        }
    }

    // MARK: - 滚动清理

    /// 只保留最近 `keepDays` 天（含今天）；解析不了的天键一并清掉。
    public mutating func prune(keepDays: Int = defaultKeepDays, now: Date = Date(),
                               calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -(keepDays - 1),
                                         to: calendar.startOfDay(for: now)) else { return }
        days = days.filter { key, _ in
            guard let day = Self.parseDayKey(key, calendar: calendar) else { return false }
            return day >= cutoff
        }
    }

    // MARK: - 每日视图

    /// 转成 UI 用的每日摘要，最近的在前；每天内按连接次数降序（字节没有真实来源，恒 0）。
    public func digests(calendar: Calendar = .current) -> [DailyDigest] {
        days.compactMap { key, records -> DailyDigest? in
            guard let day = Self.parseDayKey(key, calendar: calendar) else { return nil }
            let stats = records.values.map { r in
                DomainStat(
                    domain: r.domain, connectionCount: r.connectionCount,
                    uploadBytes: 0, downloadBytes: 0,   // 接上 QueryStats 前没有真实字节，不编造
                    route: Self.dominantRoute(r), lastMatchedRule: r.lastMatchedRule,
                    firstSeen: r.firstSeen, lastSeen: r.lastSeen
                )
            }
            .sorted {
                $0.connectionCount != $1.connectionCount
                    ? $0.connectionCount > $1.connectionCount : $0.domain < $1.domain
            }
            // digest 级计数与 DomainAnalyzer.daily 同口径：mixed 计入代理
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

    // MARK: - 天键

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func parseDayKey(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        return calendar.date(from: c)
    }

    private static func dominantRoute(_ r: DomainDayRecord) -> DomainRoute {
        let kinds = [(r.proxyCount, DomainRoute.proxy),
                     (r.directCount, .direct),
                     (r.rejectCount, .reject)].filter { $0.0 > 0 }
        return kinds.count == 1 ? kinds[0].1 : .mixed
    }
}
