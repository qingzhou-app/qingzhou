// Widget 进程内读 VPN 状态的快照。
//
// 为什么 widget 是「App 被杀后」唯一能一眼看到真相的自有 UI：它是独立进程、由系统按
// 时间线刷新，读的是系统状态 + App Group 文件，全程不依赖主 App 活着（设置页 / Live
// Activity 都做不到——前者 App 死就没 UI，后者更新靠 App 驱动、App 死就冻结）。
//
// 数据来源（三条路，都不依赖主 App 进程活着）：
// 1. **会话状态 / 节点名**：直接读系统 VPN preferences（NETunnelProviderManager）。
//    widget 扩展带了和主 App 相同的 NE entitlement，可以 loadAllFromPreferences 拿到
//    connection.status（权威）和 providerConfiguration["nodeName"]（主 App configure 时写入）。
//    不用 App Group 的 tunnel-session.json 判断连接状态 —— 用户手动断开时扩展不回填
//    stoppedAt，那个文件单独看会误判成"还连着"。
// 2. **转发层真相（是不是 zombie）**：App Group 的 traffic-stats.json 心跳（扩展每秒
//    无条件写）。会话显示连着、但心跳过期 → 扩展死/卡，显示「无响应」而非假装正常。
//    判活阈值/语义收敛在 QingzhouCore.TunnelLiveness（可单测）。
// 3. **已连接时长**：App Group 的 tunnel-session.json（隧道扩展在 xray 起来那刻写入
//    startedAt）。只在 status == .connected 时采纳，避开上面说的残留问题。

import Foundation
import NetworkExtension
import QingzhouApp
import QingzhouCore

struct VPNWidgetSnapshot: Sendable, Equatable {
    enum Phase: Sendable {
        case connected
        /// connecting / reasserting / disconnecting —— 马上会尘埃落定的过渡态
        case transitioning
        case disconnected
    }

    var phase: Phase
    var nodeName: String?
    /// 本次会话计时起点（仅 connected 且会话标记有效时非 nil），给 Text(style: .timer) 用
    var connectedSince: Date?
    /// 转发层真相（仅 connected 时有意义）：forwarding=真在转发 / stalled=会话在但扩展无响应 /
    /// unknown=刚起还没心跳。非 connected 恒为 unknown。
    var forwarding: TunnelForwarding

    /// 会话显示连着、但扩展心跳过期 —— zombie 隧道，UI 该给醒目警告而非假装正常。
    var isStalled: Bool { phase == .connected && forwarding == .stalled }

    /// 小组件库预览 / placeholder 用的静态快照
    static let placeholder = VPNWidgetSnapshot(
        phase: .disconnected, nodeName: nil, connectedSince: nil, forwarding: .unknown)

    /// 读一次当前状态。任何一步失败都降级成 disconnected/nil —— widget 绝不能因读状态崩溃。
    @MainActor
    static func read() async -> VPNWidgetSnapshot {
        let mgr = VPNTunnelManager()
        try? await mgr.load()

        let phase: Phase
        switch mgr.status {
        case .connected:
            phase = .connected
        case .connecting, .reasserting, .disconnecting:
            phase = .transitioning
        default:
            phase = .disconnected
        }

        let nodeName = (mgr.manager?.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?["nodeName"] as? String

        var connectedSince: Date?
        var forwarding: TunnelForwarding = .unknown
        if phase == .connected {
            if let session = AppGroupStorage.read(TunnelSessionInfo.self, from: "tunnel-session"),
               session.stoppedAt == nil,
               session.startedAt <= Date() {
                connectedSince = session.startedAt
            }
            // 转发层真相：读扩展每秒写的流量心跳，据其新鲜度判活（zombie 检测）。
            let lastHeartbeat = AppGroupStorage.read(TrafficStats.self, from: "traffic-stats")?.sampledAt
            forwarding = TunnelLiveness.forwarding(lastHeartbeat: lastHeartbeat)
        }

        return VPNWidgetSnapshot(
            phase: phase, nodeName: nodeName, connectedSince: connectedSince, forwarding: forwarding)
    }
}
