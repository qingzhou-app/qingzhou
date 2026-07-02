import Foundation

/// 隧道扩展进程的内存快照。由 PacketTunnel appex 随流量统计每秒采样一次，
/// 经 App Group（memory-stats.json）上报给主 App。
///
/// 背景：iOS 对 packet tunnel 扩展有 **50 MiB phys_footprint 硬上限**，超限被 jetsam
/// 直接杀（表现为「断流」）。扩展里跑着 Go runtime（xray-core），内存是"不断流"
/// 卖点成立与否的生死线 —— 所以先量化（本类型），再优化。
///
/// - `footprintBytes` 用的是 task_vm_info 的 phys_footprint —— **jetsam 判死刑看的就是它**，
///   不是 resident size。
/// - `allTimePeakBytes` 跨会话持久（扩展启动时从上次的 memory-stats.json 读回来接着比），
///   诊断"用户报断流"时有据可查。
public struct TunnelMemoryStats: Codable, Sendable, Equatable {
    /// 当前 phys_footprint（字节）。jetsam 的判定依据。
    public var footprintBytes: Int64
    /// os_proc_available_memory() 的返回（字节）—— 距离被杀还剩多少。仅 iOS 有效，macOS 为 nil。
    public var availableBytes: Int64?
    /// 本次隧道会话内的 footprint 峰值。
    public var sessionPeakBytes: Int64
    /// 跨会话的历史最高峰值（扩展每次启动时从上次落盘值接着累计）。
    public var allTimePeakBytes: Int64
    /// 平台内存上限（字节）。iOS = 50 MiB（NE 扩展 jetsam 线）；macOS 无硬上限，为 0。
    public var limitBytes: Int64
    /// 本次会话 footprint 越过告警阈值的次数（进入告警状态才 +1，持续超限不重复计）。
    public var warningCount: Int
    /// 采样诊断：采样失败/降级时的原因（task_info 的 kern_return 码、反推标记等），
    /// 正常时为 nil。**采样失败也要每秒写记录** —— 原因必须能到达诊断 UI：
    /// 验收 #17-iOS 的教训是扩展静默跳过写入后，Mac 上读不到 iPhone 容器，只能靠猜。
    public var error: String?
    public var sampledAt: Date

    public init(
        footprintBytes: Int64,
        availableBytes: Int64? = nil,
        sessionPeakBytes: Int64 = 0,
        allTimePeakBytes: Int64 = 0,
        limitBytes: Int64 = 0,
        warningCount: Int = 0,
        error: String? = nil,
        sampledAt: Date = Date()
    ) {
        self.footprintBytes = footprintBytes
        self.availableBytes = availableBytes
        self.sessionPeakBytes = sessionPeakBytes
        self.allTimePeakBytes = allTimePeakBytes
        self.limitBytes = limitBytes
        self.warningCount = warningCount
        self.error = error
        self.sampledAt = sampledAt
    }
}

/// 内置 geo 数据的能力声明 —— UI 校验和规则转换共用，避免两处硬编码漂移。
///
/// geoip.dat 用的是 v2fly 的 `geoip-only-cn-private.dat`（约 1.5 MB，替代 22 MB 全量版，
/// 给 NE 扩展 50 MiB 内存预算省地）。内置规则只用 geoip:cn / geoip:private，行为不变；
/// 用户自定义其他国家码的 GEOIP 规则会**不生效**（转换层跳过 —— xray 对缺失的
/// geoip 分类会直接启动失败，绝不能透传）。完整版 geo 数据下载是后续任务。
public enum GeoDataBundle {
    /// 内置 geoip.dat 实际包含的分类码（小写）。
    public static let bundledGeoIPCategories: Set<String> = ["cn", "private"]

    /// 该 GEOIP 规则值是否被内置 geo 数据支持（大小写不敏感，容忍 `!` 反转前缀）。
    public static func supportsGeoIP(_ value: String) -> Bool {
        var v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.hasPrefix("!") { v.removeFirst() }
        return bundledGeoIPCategories.contains(v)
    }
}
