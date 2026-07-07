import Foundation

/// 一条测量样本（一轮自动择优 / 手动测速产生一条）。
///
/// `latencyMs == nil` 表示**该轮直连测速失败** —— 失败必须留痕：稳定性维度的成功率
/// 就靠失败样本算，只记成功会把「时好时坏」的烂节点洗白成满分。
/// `proxiedMs` 是同轮经代理精选实测的全链路延迟（没轮到 / 失败为 nil）。
public struct NodeMetricSample: Codable, Sendable, Equatable {
    public var at: Date
    public var latencyMs: Int?
    public var proxiedMs: Int?

    public init(at: Date, latencyMs: Int? = nil, proxiedMs: Int? = nil) {
        self.at = at
        self.latencyMs = latencyMs
        self.proxiedMs = proxiedMs
    }
}

/// 每节点环形测量历史 —— 打分引擎（`NodeScorer`）稳定性维度的数据源。
///
/// 为什么需要它：`Node` 上只存**最近一次**测量（lastLatencyMs），没有序列就没法算
/// 成功率 / 延迟抖动，纯延迟择优最常见的翻车点（延迟低但抖动大）就避不开。
///
/// 设计取舍：
/// - key 用 `Node.identityFingerprint` 而不是 UUID —— 订阅刷新后 UUID 可能变，指纹稳定，
///   历史才能跨刷新延续；
/// - 环形上限 `capacity` 条：足够算成功率/变异系数，体量可控
///   （500 节点 × 20 条 × ~40B ≈ 400KB，全在主 App，不碰扩展 50MB 红线）；
/// - 落盘为单个 JSON（`node-metrics.json`），本地瞬态：**不进 Persistence.Snapshot、
///   不上 iCloud** —— 测量结果跨设备/网络没有可比性，待遇同 domain-history。
public struct NodeMetricsHistory: Codable, Sendable, Equatable {

    /// 每节点最多保留的样本数。
    public static let capacity = 20

    /// 「同轮回填」窗口：经代理精选紧跟在全量直连测速之后（同一轮内串行实测，最多几分钟），
    /// 距最近直连样本 ≤ 该窗口的经代理结果并入**同一条**样本；更久远的（用户在详情页
    /// 手动测的）另起独立样本 —— 直接改老样本等于篡改历史轮次的记录。
    public static let sameRoundWindow: TimeInterval = 10 * 60

    /// identityFingerprint → 时间正序的样本环。
    public private(set) var samples: [String: [NodeMetricSample]] = [:]

    public init() {}

    public var isEmpty: Bool { samples.isEmpty }

    /// 某节点的样本（时间正序）；没有历史返回空数组。
    public func samples(for fingerprint: String) -> [NodeMetricSample] {
        samples[fingerprint] ?? []
    }

    /// 记一条直连测量（成功失败都记，见 `NodeMetricSample.latencyMs` 注释）。
    public mutating func recordDirect(fingerprint: String, latencyMs: Int?, at: Date = Date()) {
        append(NodeMetricSample(at: at, latencyMs: latencyMs), for: fingerprint)
    }

    /// 记一次经代理实测：同轮窗口内并入最近一条样本，否则作为独立样本追加。
    public mutating func recordProxied(fingerprint: String, proxiedMs: Int, at: Date = Date()) {
        if var ring = samples[fingerprint], let last = ring.last,
           at.timeIntervalSince(last.at) <= Self.sameRoundWindow {
            ring[ring.count - 1].proxiedMs = proxiedMs
            samples[fingerprint] = ring
        } else {
            append(NodeMetricSample(at: at, proxiedMs: proxiedMs), for: fingerprint)
        }
    }

    /// 只保留给定指纹的历史 —— 节点被订阅刷新删掉后，历史别永远躺在文件里。
    public mutating func prune(keeping fingerprints: Set<String>) {
        samples = samples.filter { fingerprints.contains($0.key) }
    }

    private mutating func append(_ sample: NodeMetricSample, for fingerprint: String) {
        var ring = samples[fingerprint] ?? []
        ring.append(sample)
        if ring.count > Self.capacity {
            ring.removeFirst(ring.count - Self.capacity)
        }
        samples[fingerprint] = ring
    }
}
