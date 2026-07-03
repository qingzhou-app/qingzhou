// Widget 进程内读 VPN 状态的快照。
//
// 数据来源（两条路，都不依赖主 App 进程活着）：
// 1. **连接状态 / 节点名**：直接读系统 VPN preferences（NETunnelProviderManager）。
//    widget 扩展带了和主 App 相同的 NE entitlement，可以 loadAllFromPreferences 拿到
//    connection.status（权威）和 providerConfiguration["nodeName"]（主 App configure 时写入）。
//    不用 App Group 的 tunnel-session.json 判断连接状态 —— 用户手动断开时扩展不回填
//    stoppedAt，那个文件单独看会误判成"还连着"。
// 2. **已连接时长**：App Group 的 tunnel-session.json（隧道扩展在 xray 起来那刻写入
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

    /// 小组件库预览 / placeholder 用的静态快照
    static let placeholder = VPNWidgetSnapshot(phase: .disconnected, nodeName: nil, connectedSince: nil)

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
        if phase == .connected,
           let session = AppGroupStorage.read(TunnelSessionInfo.self, from: "tunnel-session"),
           session.stoppedAt == nil,
           session.startedAt <= Date() {
            connectedSince = session.startedAt
        }

        return VPNWidgetSnapshot(phase: phase, nodeName: nodeName, connectedSince: connectedSince)
    }
}
