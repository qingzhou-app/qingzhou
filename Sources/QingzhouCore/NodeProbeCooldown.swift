import Foundation

/// 仅本进程使用。完整连接身份为键，不改变用户排除配置；成功复测立即恢复。
public struct NodeProbeCooldown: Sendable {
    public static let duration: TimeInterval = 5 * 60
    private var deadlines: [String: Date] = [:]
    public init() {}
    public mutating func confirm(_ fingerprints: Set<String>, now: Date = Date()) {
        deadlines = deadlines.filter { $0.value > now }
        for fingerprint in fingerprints { deadlines[fingerprint] = now.addingTimeInterval(Self.duration) }
    }
    public mutating func recover(_ fingerprint: String) { deadlines[fingerprint] = nil }
    public mutating func reset() { deadlines = [:] }
    public func contains(_ fingerprint: String, now: Date = Date()) -> Bool {
        guard let end = deadlines[fingerprint] else { return false }
        // 时钟回拨不让短暂冷却变成长时间禁用。
        return end > now && end.timeIntervalSince(now) <= Self.duration
    }
}
