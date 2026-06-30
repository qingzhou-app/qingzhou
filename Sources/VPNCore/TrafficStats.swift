import Foundation

/// 隧道实时流量快照。由 PacketTunnel appex 在 TUN 桥接层按秒采样，
/// 通过 App Group 共享文件上报给主 app —— 替换早期的 sample 假数据。
///
/// appex 只能在 IP 层数字节（上/下行总量 + 瞬时速率 + 活跃连接数）；
/// 细到「哪个域名走了代理」要解析 xray access log（见 ConnectionDigest），那是另一条管道。
public struct TrafficStats: Codable, Sendable, Equatable {
    public var uploadBytes: Int64        // 本次会话累计上行字节
    public var downloadBytes: Int64      // 本次会话累计下行字节
    public var uploadSpeedBps: Int64     // 瞬时上行速率 byte/s
    public var downloadSpeedBps: Int64   // 瞬时下行速率 byte/s
    public var activeConnections: Int
    public var sampledAt: Date

    public init(
        uploadBytes: Int64 = 0,
        downloadBytes: Int64 = 0,
        uploadSpeedBps: Int64 = 0,
        downloadSpeedBps: Int64 = 0,
        activeConnections: Int = 0,
        sampledAt: Date = Date()
    ) {
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
        self.uploadSpeedBps = uploadSpeedBps
        self.downloadSpeedBps = downloadSpeedBps
        self.activeConnections = activeConnections
        self.sampledAt = sampledAt
    }
}

/// 波形图用的滑动窗口：保留最近 `capacity` 个速率样本，满了丢最老的。
/// 纯值类型、无副作用，方便单测；UI 拿 `samples` 画曲线、拿 `peakSpeed` 做纵轴归一化。
public struct TrafficHistory: Sendable, Equatable {
    public private(set) var samples: [TrafficStats]
    public let capacity: Int

    public init(capacity: Int = 60) {
        self.capacity = max(1, capacity)
        self.samples = []
    }

    /// 追加一个样本；超出容量时从头部丢弃最老的。
    public mutating func record(_ sample: TrafficStats) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    public mutating func clear() {
        samples.removeAll(keepingCapacity: true)
    }

    /// 窗口内的最大瞬时速率（上下行取大者），用于波形纵轴归一化。无样本时为 0。
    public var peakSpeed: Int64 {
        samples.reduce(0) { Swift.max($0, Swift.max($1.uploadSpeedBps, $1.downloadSpeedBps)) }
    }

    public var latest: TrafficStats? { samples.last }
}
