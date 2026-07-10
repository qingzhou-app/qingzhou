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

/// 历史峰值的可信性护栏 —— 读侧钳制 + 写侧防护（纯逻辑，可测）。
///
/// 背景（2026-07 真实事故）：用户 Mac 的 memory-stats.json 里 allTimePeakBytes=8427511368
/// （≈7.85 GiB），而扩展真实 footprint 只有 ~54 MB。那不是采样 API 出错 —— 是 build 8 之前
/// Xray→Apple 写包循环缺 autoreleasepool 的滞留泄漏（footprint 堆到 ≈ 会话总流量，见
/// PacketTunnelProvider.runFdToWritePacketsLoop 的注释）在崩溃循环时代留下的**真实读数**。
/// 泄漏已修（7e64e44），但 allTimePeak 跨会话只增不减（max + 落盘接续），坏样本一旦写入
/// 就永久粘住，「历史最高」从此失去诊断价值。两道防线：
/// - **读侧**（sanitizedPersistedPeak）：启动接续上次落盘值之前钳制，超界视为损坏 → 丢弃重建；
/// - **写侧**（mergingPeak）：单次采样超界不并入峰值 —— 再出病理读数也污染不了历史。
public enum TunnelMemoryPeakGuard {
    /// 「NE 隧道扩展物理上可能」的 footprint 峰值上限：2 GiB。
    /// 取值理由：iOS NE 扩展 jetsam 硬上限 50 MiB（超限即被杀），2 GiB 已是 40 倍；
    /// macOS 无硬上限、本扩展常态 ~60 MB，footprint 到 GiB 级只可能是灾难性泄漏 ——
    /// 峰值饱和在 2 GiB 已足够说明「出过大事」，更大的数字没有额外诊断信息量，
    /// 只会像 8.4 GB 事故那样把指标永久打坏。
    public static let maxPlausiblePeakBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// 读侧钳制：扩展启动时从上次落盘 JSON 接续历史峰值前过一遍。
    /// 非正数或超上限 = 损坏 → 返回 0（丢弃，用本会话数据重建）。
    public static func sanitizedPersistedPeak(_ persistedBytes: Int64) -> Int64 {
        guard persistedBytes > 0, persistedBytes <= maxPlausiblePeakBytes else { return 0 }
        return persistedBytes
    }

    /// 写侧防护：把单次 footprint 采样并入峰值。样本非正（采样失败占位）或超上限
    /// （病理读数）→ 不并入，峰值保持原值。
    public static func mergingPeak(_ currentPeak: Int64, sample: Int64) -> Int64 {
        guard sample > 0, sample <= maxPlausiblePeakBytes else { return currentPeak }
        return max(currentPeak, sample)
    }
}

/// 内置 geo 数据的能力声明 —— UI 校验和规则转换共用，避免两处硬编码漂移。
///
/// geoip.dat 用的是 v2fly 的 `geoip-only-cn-private.dat`（约 1.5 MB，替代 22 MB 全量版，
/// 给 NE 扩展 50 MiB 内存预算省地）。内置规则只用 geoip:cn / geoip:private，行为不变；
/// 用户自定义其他国家码的 GEOIP 规则默认**不生效**（转换层跳过 —— xray 对缺失的
/// geoip 分类会直接启动失败，绝不能透传）。下载完整版 geoip.dat（GeoDataManager，
/// 经 App Group 交给扩展）后转换层传 hasFullGeoIP=true，全部国家码解锁。
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

/// 已下载的完整版 geo 数据的元信息。主 App（GeoDataManager）下载校验通过后写进
/// App Group `xray-data/geo-data-info.json`，隧道扩展启动时读它来决定用哪份 geoip.dat：
/// info 存在且 `sizeBytes` 与磁盘文件吻合 → 用 App Group 完整版；否则回退内置精简版。
/// 编解码统一 ISO8601 日期（与 AppGroupStorage 的读写策略一致）。
public struct GeoDataInfo: Codable, Sendable, Equatable {
    /// geoip.dat 内容的 SHA-256（hex 小写）。下载校验记录 + "检查更新"的比较基准。
    public var sha256: String
    /// 文件字节数 —— 扩展侧用它做廉价的一致性检查（不用再算一遍 20 多 MB 的 sha）。
    public var sizeBytes: Int64
    /// 来源 id（"qingzhou" = 自建源 / "v2fly" = 官方源）。
    public var sourceID: String
    /// 来源展示名（"轻舟源" / "v2fly 官方"），UI 直接显示。
    public var sourceName: String
    public var downloadedAt: Date

    public init(sha256: String, sizeBytes: Int64, sourceID: String, sourceName: String, downloadedAt: Date = Date()) {
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.downloadedAt = downloadedAt
    }
}
