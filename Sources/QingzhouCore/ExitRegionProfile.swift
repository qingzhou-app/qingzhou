import Foundation

/// 出口地区画像 —— 从「节点出口 IP 的地理信息」推导出的、可以拿来对齐本地环境的几项。
///
/// 为什么要这个：分流方案把流量送到海外出口之后，显式 IP 变了，但**时区、语言**这些
/// 还是本机的。对风控来说，"IP 在伦敦、浏览器时区是 Asia/Shanghai" 是一眼可见的矛盾。
///
/// 边界要说清楚 —— 应用层能改的和不能改的完全不同：
/// - **能改**：本 App 自己的界面语言、日期/时间的显示时区（SwiftUI 环境值）。
/// - **改不了**：系统时区、系统语言（需要 root，见 `systemTimeZoneCommand`）；
///   浏览器语言/时区（各浏览器自己的设置）；GPS 定位（系统级，且多数站点按 IP 判定）。
public struct ExitRegionProfile: Sendable, Equatable {
    public var countryCode: String?
    public var country: String?
    public var city: String?
    /// IANA 时区标识，如 `Asia/Singapore`。
    public var timezoneID: String?
    public var latitude: Double?
    public var longitude: Double?

    public init(countryCode: String? = nil, country: String? = nil, city: String? = nil,
                timezoneID: String? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.countryCode = countryCode
        self.country = country
        self.city = city
        self.timezoneID = timezoneID
        self.latitude = latitude
        self.longitude = longitude
    }

    public var timeZone: TimeZone? {
        timezoneID.flatMap(TimeZone.init(identifier:))
    }

    /// 「新加坡 · Asia/Singapore」这种一行摘要。
    public var summary: String {
        let place = [country, city].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let tz = timezoneID ?? "未知时区"
        return place.isEmpty ? tz : "\(place) · \(tz)"
    }

    /// 建议的 App 界面语言。
    ///
    /// 只映射**有把握**的国家/地区，其余返回 nil（保持用户当前选择）——
    /// 拿不准就不动，比猜错强：把日语切成一堆英文更让人困惑。
    public var suggestedLanguage: AppLanguage? {
        switch countryCode?.uppercased() {
        case "CN":                       return .zhHans
        case "TW", "HK", "MO":           return .zhHant
        case "JP":                       return .ja
        case "US", "GB", "AU", "CA", "NZ", "IE", "SG", "PH", "IN":
            return .en
        default:                         return nil
        }
    }

    /// 系统时区的修改命令（需要 root，本 App 不代劳）。
    /// 给用户一条能直接粘贴的命令，比"请自行在系统设置里改"更可执行。
    public func systemTimeZoneCommand() -> String? {
        guard let tz = timezoneID, TimeZone(identifier: tz) != nil else { return nil }
        return "sudo systemsetup -settimezone \(tz)"
    }
}
