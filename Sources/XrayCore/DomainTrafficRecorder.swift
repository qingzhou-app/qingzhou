import Foundation
import QingzhouCore

/// 只由扩展 statsQueue 调用。账本与去重基线原子提交，写失败不推进内存基线。
public final class DomainTrafficRecorder {
    private var ledger: DomainTrafficLedger
    private var url: URL
    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            ledger = try decoder.decode(DomainTrafficLedger.self, from: Data(contentsOf: url))
        } else { ledger = .init() }
    }
    public func record(_ snapshot: DomainTrafficSnapshot, at date: Date, calendar: Calendar = .current, vpnSessionID: String? = nil) throws {
        var candidate = ledger
        guard candidate.ingest(snapshot, at: date, calendar: calendar, vpnSessionID: vpnSessionID) else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(candidate)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        ledger = candidate
        var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try? url.setResourceValues(attributes)
    }
}
