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
    ///
    /// - Parameter excludingBareIPs: true 时剔除裸 IP 条目 —— 和域名 tab 的「忽略 IP」
    ///   过滤同一口径，否则开关一开两个 tab 数字必然对不上。判定在读取时现场做
    ///   （`HostClassifier.isBareIP`），已落盘的旧历史数据无需迁移。
    /// - Note: digest 的 proxy/direct/reject 是**连接次数**（Σ 各域名的分路计数，
    ///   三者之和 = 当天总连接次数），与行内「N 次」同单位，可直接对账；
    ///   不是「域名个数」—— 那个口径下 mixed 域名没法归类，数字也没法验证。
    public func digests(calendar: Calendar = .current, excludingBareIPs: Bool = false) -> [DailyDigest] {
        days.compactMap { key, allRecords -> DailyDigest? in
            guard let day = Self.parseDayKey(key, calendar: calendar) else { return nil }
            let records = excludingBareIPs
                ? allRecords.values.filter { !HostClassifier.isBareIP($0.domain) }
                : Array(allRecords.values)
            guard !records.isEmpty else { return nil }
            let stats = records.map { r in
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
            return DailyDigest(
                day: day,
                domains: stats,
                proxyCount: records.reduce(0) { $0 + $1.proxyCount },
                directCount: records.reduce(0) { $0 + $1.directCount },
                rejectCount: records.reduce(0) { $0 + $1.rejectCount }
            )
        }
        .sorted { $0.day > $1.day }
    }

    // MARK: - 单域名趋势（详情页柱状图）

    /// 一天的连接次数（`dailyCounts` 的元素）。
    public struct DayCount: Sendable, Equatable, Identifiable {
        public var day: Date     // 当天 0 点
        public var count: Int
        public var id: Date { day }

        public init(day: Date, count: Int) {
            self.day = day
            self.count = count
        }
    }

    /// 某主域名最近 `days` 天（含今天）的每日连接次数，时间正序、无记录的天补 0 ——
    /// 柱状图要等宽的 7 根柱，缺天不补会错位。`domain` 传聚合行的主域名（存储键同口径）。
    public func dailyCounts(domain: String, days count: Int = 7, now: Date = Date(),
                            calendar: Calendar = .current) -> [DayCount] {
        let todayStart = calendar.startOfDay(for: now)
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: todayStart) else {
                return nil
            }
            let key = Self.dayKey(day, calendar: calendar)
            return DayCount(day: day, count: days[key]?[domain]?.connectionCount ?? 0)
        }
    }

    // MARK: - 今日新增（新面孔）

    /// 「今日新增」的主域名统计：今天出现、且窗口内**更早的天**从未见过的主域名。
    /// 判定完全基于本结构的 30 天历史 —— 30 天前见过但已被滚动清理的域名会再次算新，
    /// 这是「新面孔」语义的自然边界（和 UI 文案「30 天内首次出现」一致）。
    ///
    /// - Parameter excludingBareIPs: 与 digests 的「忽略 IP」同口径。
    /// - Returns: 今天的聚合统计（DomainStat，字节恒 0 同 digests），按连接次数降序。
    public func newTodayStats(now: Date = Date(), calendar: Calendar = .current,
                              excludingBareIPs: Bool = false) -> [DomainStat] {
        let todayKey = Self.dayKey(now, calendar: calendar)
        guard let today = days[todayKey], !today.isEmpty else { return [] }
        guard let todayStart = Self.parseDayKey(todayKey, calendar: calendar) else { return [] }
        // 更早的天里见过的主域名全集（未来天键防御性忽略：时钟回拨产生的脏键别误伤）
        var seenBefore: Set<String> = []
        for (key, records) in days where key != todayKey {
            guard let day = Self.parseDayKey(key, calendar: calendar), day < todayStart else { continue }
            seenBefore.formUnion(records.keys)
        }
        return today.values
            .filter { !seenBefore.contains($0.domain) }
            .filter { !excludingBareIPs || !HostClassifier.isBareIP($0.domain) }
            .map { r in
                DomainStat(
                    domain: r.domain, connectionCount: r.connectionCount,
                    uploadBytes: 0, downloadBytes: 0,
                    route: Self.dominantRoute(r), lastMatchedRule: r.lastMatchedRule,
                    firstSeen: r.firstSeen, lastSeen: r.lastSeen
                )
            }
            .sorted {
                $0.connectionCount != $1.connectionCount
                    ? $0.connectionCount > $1.connectionCount : $0.domain < $1.domain
            }
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
