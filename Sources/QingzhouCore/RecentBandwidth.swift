import Foundation

/// 近 30 分钟活跃下载的分钟峰值分布，至少 3 个活跃分钟才有观测。
/// 取下侧 75% 分位，过滤孤立尖峰；闲置不记零，不把业务需求误认为线路容量。
/// 进程内、按节点及网络上下文使用；重启 / 路径变化由调用方丢弃。
public struct RecentBandwidth: Sendable {
    public static let window: TimeInterval = 30 * 60
    public static let activeFloorBps: Int64 = 100 * 1024
    private struct Bucket: Sendable { var at: Date; var peak: Int64 }
    private var buckets: [Int: Bucket] = [:]
    public init() {}

    public mutating func record(bytesPerSecond: Int64, at: Date) {
        buckets = buckets.filter { at.timeIntervalSince($0.value.at) >= 0 && at.timeIntervalSince($0.value.at) < Self.window }
        guard bytesPerSecond >= Self.activeFloorBps else { return }
        let key = Int(floor(at.timeIntervalSince1970 / 60))
        buckets[key] = Bucket(at: at, peak: max(buckets[key]?.peak ?? 0, bytesPerSecond))
    }

    public func estimate(at now: Date = Date()) -> Int64? {
        let active = buckets.values.filter { now.timeIntervalSince($0.at) >= 0 && now.timeIntervalSince($0.at) < Self.window }
            .map(\.peak).sorted()
        guard active.count >= 3 else { return nil }
        return active[Int(floor(Double(active.count - 1) * 0.75))]
    }
}
