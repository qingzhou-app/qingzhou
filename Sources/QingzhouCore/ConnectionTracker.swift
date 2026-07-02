import Foundation

/// 连接列表的「最后活跃时间 + 超时老化」管理器。
///
/// 背景：xray access log **只记录连接建立**（`from ... accepted ...`），没有关闭事件，
/// 所以 `Connection.closedAt` 没有任何直接来源 —— 不老化的话「已关闭」分组永远为空。
/// per-连接的 upload/downloadSpeedBps 也没有真实更新来源（appex 只上报全局 TrafficStats），
/// 无法用「速率归零」辅助判定，只能按 access log 里身份重现来刷新活跃时间。
///
/// 规则：
/// - 身份 = 源地址(ip:port) + 目标地址(host:port) + 网络类型。同一身份在 access log
///   中重复出现（典型如 UDP/QUIC 同一 socket 的多次会话）→ 刷新活跃时间，不重复插入；
/// - 超过 `idleTimeout` 无活动 → 置 `closedAt` = 最后活跃时刻（真实关闭大概率发生在
///   最后活跃后不久，比「老化判定那一刻」更接近真相）；
/// - 隧道停止 → `closeAll`，所有仍活跃的连接立即关闭（closedAt = 停止时刻）；
/// - 已关闭的身份再次出现 → 视为一条全新连接。
///
/// 纯逻辑、时间全部由参数注入，swift test 可完整覆盖。
public struct ConnectionTracker: Sendable {

    /// 空闲多久判定为已关闭。access log 每 2s 增量摄入，取 90–120s 区间的中间值。
    public static let idleTimeout: TimeInterval = 100

    /// 连接列表（新的在前）。元素字段可原地改（如回填 sourceApp），
    /// 但**增删必须走 ingest / ageOut / closeAll**，否则内部索引会失配。
    public var connections: [Connection] = []

    private var lastSeenByID: [UUID: Date] = [:]
    /// 身份 → 仍活跃的那条连接 id。关闭/挤出后移除，同身份重现即成为新连接。
    private var activeIDByKey: [String: UUID] = [:]
    private let maxCount: Int

    public init(maxCount: Int = 200) {
        self.maxCount = maxCount
    }

    /// 摄入一条 access log 解析出的连接。同身份且仍活跃 → 只刷新活跃时间。
    public mutating func ingest(_ connection: Connection, at now: Date = Date()) {
        let key = Self.identity(of: connection)
        if let existingID = activeIDByKey[key] {
            lastSeenByID[existingID] = now
            return
        }
        activeIDByKey[key] = connection.id
        lastSeenByID[connection.id] = now
        connections.insert(connection, at: 0)
        trim()
    }

    /// 老化：把超过 `idleTimeout` 无活动的活跃连接置为已关闭。
    public mutating func ageOut(at now: Date = Date(), idleTimeout: TimeInterval = ConnectionTracker.idleTimeout) {
        for i in connections.indices where connections[i].isActive {
            let lastSeen = lastSeenByID[connections[i].id] ?? connections[i].openedAt
            if now.timeIntervalSince(lastSeen) >= idleTimeout {
                connections[i].closedAt = lastSeen
                forget(connections[i])
            }
        }
    }

    /// 隧道停止：所有仍活跃的连接立即关闭。
    public mutating func closeAll(at now: Date = Date()) {
        for i in connections.indices where connections[i].isActive {
            connections[i].closedAt = now
            forget(connections[i])
        }
    }

    // MARK: - 私有

    private static func identity(of c: Connection) -> String {
        "\(c.sourceAddress)|\(c.targetAddress)|\(c.type.rawValue)"
    }

    /// 连接不再活跃（已关闭或被挤出）后清掉它的索引，防止字典无界增长。
    private mutating func forget(_ c: Connection) {
        lastSeenByID.removeValue(forKey: c.id)
        let key = Self.identity(of: c)
        if activeIDByKey[key] == c.id {
            activeIDByKey.removeValue(forKey: key)
        }
    }

    private mutating func trim() {
        while connections.count > maxCount {
            forget(connections.removeLast())
        }
    }
}
