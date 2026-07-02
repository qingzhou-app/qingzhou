import Foundation

/// 应用层连接类型（用于 UI 展示）。
public enum ConnectionType: String, Codable, Sendable, CaseIterable {
    case https
    case http
    case socks5
    case tcp
    case udp
}

/// 一次代理连接的快照。由 PacketTunnel 端定期上报到主 app。
public struct Connection: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var sourceApp: String?         // bundle id；iOS 上通常拿不到，会为 nil
    public var targetHost: String
    public var sourceAddress: String      // ip:port
    public var targetAddress: String      // ip:port
    public var type: ConnectionType
    public var route: String              // 走哪个节点；DIRECT/REJECT 表示直连/拒绝
    public var matchedRule: String        // 命中的规则源文本
    public var openedAt: Date
    public var closedAt: Date?
    public var uploadBytes: Int64
    public var downloadBytes: Int64
    public var uploadSpeedBps: Int64      // 当前上传速度 byte/s
    public var downloadSpeedBps: Int64

    public init(
        id: UUID = UUID(),
        sourceApp: String? = nil,
        targetHost: String,
        sourceAddress: String,
        targetAddress: String,
        type: ConnectionType,
        route: String,
        matchedRule: String,
        openedAt: Date = Date(),
        closedAt: Date? = nil,
        uploadBytes: Int64 = 0,
        downloadBytes: Int64 = 0,
        uploadSpeedBps: Int64 = 0,
        downloadSpeedBps: Int64 = 0
    ) {
        self.id = id
        self.sourceApp = sourceApp
        self.targetHost = targetHost
        self.sourceAddress = sourceAddress
        self.targetAddress = targetAddress
        self.type = type
        self.route = route
        self.matchedRule = matchedRule
        self.openedAt = openedAt
        self.closedAt = closedAt
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
        self.uploadSpeedBps = uploadSpeedBps
        self.downloadSpeedBps = downloadSpeedBps
    }

    public var isActive: Bool { closedAt == nil }
}

public extension Connection {
    /// `matchedRule` 的「没命中任何规则，走的是默认策略」语义值。
    ///
    /// 回填侧（AppState.ingestAccessLog → MatchedRuleResolver）判定不出具体规则时填它，
    /// **不要填空串** —— 空串保留给「未知/尚未回填」（如旧数据），语义上区分开。
    /// DomainAnalyzer 的建议逻辑把它和空串都当「未命中」处理。
    static let noMatchedRule = "未命中（默认策略）"
}
