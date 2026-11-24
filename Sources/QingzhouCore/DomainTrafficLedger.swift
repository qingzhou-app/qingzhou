import Foundation

/// 内核提供的进程累计载荷字节。仅用于本地扩展采集，不进入云配置。
public struct DomainTrafficSnapshot: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var domain: String
        public var route: String
        public var upload: Int64
        public var download: Int64
        public init(domain: String, route: String, upload: Int64, download: Int64) {
            self.domain = domain; self.route = route; self.upload = upload; self.download = download
        }
    }
    public var session: String
    public var entries: [Entry]
    public init(session: String, entries: [Entry]) { self.session = session; self.entries = entries }
    public static func parseMetrics(_ data: Data) -> Self? {
        struct Metrics: Decodable { var qingzhouDomainTraffic: DomainTrafficSnapshot }
        return try? JSONDecoder().decode(Metrics.self, from: data).qingzhouDomainTraffic
    }
}

public struct DomainTrafficBytes: Codable, Sendable, Equatable {
    public var upload: Int64 = 0
    public var download: Int64 = 0
    public var total: Int64 { Self.sum(upload, download) }
    public init(upload: Int64 = 0, download: Int64 = 0) { self.upload = upload; self.download = download }
    public mutating func add(_ value: Self) {
        upload = Self.sum(upload, value.upload); download = Self.sum(download, value.download)
    }
    private static func sum(_ a: Int64, _ b: Int64) -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : value
    }
}

public struct DomainTrafficRow: Codable, Sendable, Equatable, Identifiable {
    public let domain: String
    public var proxy = DomainTrafficBytes()
    public var direct = DomainTrafficBytes()
    public var id: String { domain }
    public var all: DomainTrafficBytes { var value = proxy; value.add(direct); return value }
    public init(domain: String) { self.domain = domain }
}

public struct DomainTrafficMonth: Codable, Sendable, Equatable {
    public var firstObservedAt: Date
    public var lastObservedAt: Date
    public var timeZoneIdentifier: String
    fileprivate var domains: [String: DomainTrafficRow] = [:]
    public var rows: [DomainTrafficRow] { domains.values.sorted { $0.domain < $1.domain } }
    fileprivate mutating func add(_ delta: DomainTrafficBytes, domain: String, route: String) {
        var domain = domain
        if domains[domain] == nil && domain != DomainTrafficLedger.unknownDomain && domain != DomainTrafficLedger.otherDomain {
            let named = domains.keys.filter { $0 != DomainTrafficLedger.unknownDomain && $0 != DomainTrafficLedger.otherDomain }.count
            if named >= 512 { domain = DomainTrafficLedger.otherDomain }
        }
        var row = domains[domain] ?? .init(domain: domain)
        if route == "proxy" { row.proxy.add(delta) } else { row.direct.add(delta) }
        domains[domain] = row
    }
}

/// 单写者（隧道扩展）账本。按采样时刻归档本地自然月，最多6个月/每月512主域名。
/// 基线和月账同一次原子持久化；重复快照不重复累计，进程重启从新累计值接续。
public struct DomainTrafficLedger: Codable, Sendable, Equatable {
    public static let storageName = "domain-traffic-history"
    public static let unknownDomain = "__unknown__"
    public static let otherDomain = "__other__"
    public private(set) var months: [String: DomainTrafficMonth] = [:]
    // Optional storage preserves decoding of older monthly-only ledgers.
    private var daysStorage: [String: DomainTrafficMonth]?
    public var days: [String: DomainTrafficMonth] { daysStorage ?? [:] }
    public private(set) var currentSession: DomainTrafficMonth?
    public private(set) var vpnSessionID: String?
    public private(set) var lastObservedAt: Date?
    private var session: String?
    private var baseline: [String: DomainTrafficBytes] = [:]
    public init() {}

    public static func monthKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private static func domain(_ raw: String) -> String {
        if raw == unknownDomain || raw == otherDomain { return raw }
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !HostClassifier.isBareIP(host),
              host.allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) }) else { return unknownDomain }
        return DomainAnalyzer.registrableDomain(host)
    }

    @discardableResult
    public mutating func ingest(_ snapshot: DomainTrafficSnapshot, at date: Date, calendar: Calendar = .current, vpnSessionID: String? = nil) -> Bool {
        guard !snapshot.session.isEmpty, snapshot.session.count < 128, snapshot.entries.count <= 1024,
              lastObservedAt.map({ date > $0 }) ?? true,
              snapshot.entries.allSatisfy({ $0.upload >= 0 && $0.download >= 0 && $0.domain.count <= 253
                  && ($0.route == "proxy" || $0.route == "direct") }) else { return false }
        var normalized: [String: DomainTrafficBytes] = [:]
        for entry in snapshot.entries {
            let key = Self.domain(entry.domain) + "\u{1f}" + entry.route
            normalized[key, default: .init()].add(.init(upload: entry.upload, download: entry.download))
        }
        let sameSession = session == snapshot.session
        if !sameSession { baseline = [:] }
        let monthKey = Self.monthKey(date, calendar: calendar)
        var month = months[monthKey] ?? .init(firstObservedAt: date, lastObservedAt: date,
                                             timeZoneIdentifier: calendar.timeZone.identifier)
        let dayKey = Self.dayKey(date, calendar: calendar)
        var day = days[dayKey] ?? .init(firstObservedAt: date, lastObservedAt: date,
                                       timeZoneIdentifier: calendar.timeZone.identifier)
        let vpnID = vpnSessionID ?? snapshot.session
        if self.vpnSessionID != vpnID || currentSession == nil {
            currentSession = .init(firstObservedAt: date, lastObservedAt: date,
                                   timeZoneIdentifier: calendar.timeZone.identifier)
            self.vpnSessionID = vpnID
        }
        // 排序固定容量边界；达到上限后归其他，保留代理/直连总数。
        for key in normalized.keys.sorted() {
            guard let current = normalized[key] else { continue }
            let old = baseline[key] ?? .init()
            let delta = DomainTrafficBytes(upload: max(0, current.upload - old.upload),
                                           download: max(0, current.download - old.download))
            // 同进程异常回退不下调基线，否则下一次恢复会重复计数。
            baseline[key] = .init(upload: max(old.upload, current.upload), download: max(old.download, current.download))
            guard delta.total > 0 else { continue }
            let pieces = key.split(separator: "\u{1f}")
            let domain = String(pieces[0]); let route = String(pieces[1])
            month.add(delta, domain: domain, route: route)
            day.add(delta, domain: domain, route: route)
            currentSession?.add(delta, domain: domain, route: route)
        }
        month.lastObservedAt = date
        months[monthKey] = month
        day.lastObservedAt = date
        if daysStorage == nil { daysStorage = [:] }
        daysStorage?[dayKey] = day
        currentSession?.lastObservedAt = date
        if let cutoffDate = calendar.date(byAdding: .day, value: -30, to: date) {
            let cutoff = Self.dayKey(cutoffDate, calendar: calendar)
            daysStorage = days.filter { $0.key >= cutoff && $0.key <= dayKey }
        }
        session = snapshot.session
        lastObservedAt = date
        if let cutoffDate = calendar.date(byAdding: .month, value: -5, to: date) {
            let cutoff = Self.monthKey(cutoffDate, calendar: calendar)
            months = months.filter { $0.key >= cutoff && $0.key <= monthKey }
        }
        return true
    }
}
