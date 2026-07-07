import Foundation

// Live Activity（灵动岛 / 锁屏实时活动）的数据契约（E.19）。
//
// 主 App（QingzhouApp）负责起 / 更新 / 结束 Live Activity，widget 扩展负责渲染它 ——
// 两个 target 都 link QingzhouCore，所以共享类型住在这里（对齐 TunnelSessionInfo 这类
// 跨 target / 跨进程数据契约的既有摆放）。
//
// `ActivityAttributes` 协议本身依赖 ActivityKit（仅 iOS，macOS 无 Live Activity），用
// `#if canImport(ActivityKit)` 隔离；纯数据的 ContentState 不依赖 ActivityKit，可在
// macOS 上跑 `swift test` 覆盖编解码 —— TDD 的可测面就在这层。

/// Live Activity 的动态内容（每秒更新）：连接状态 + 计时起点 + 实时速率 + 累计字节。
/// 必须 `Codable & Hashable`（ActivityKit 对 ContentState 的硬性要求）。
public struct QingzhouActivityContentState: Codable, Hashable, Sendable {
    /// 连接阶段。灵动岛/锁屏据此切图标与文案（连接中 / 已连接 / 断开中）。
    public enum Phase: String, Codable, Sendable {
        case connecting
        case connected
        case disconnecting
    }

    public var phase: Phase
    /// 计时起点（`connected` 且会话标记有效时非 nil）。锁屏/灵动岛用 `Text(_:style:.timer)`
    /// 自走字，主 App 进后台被挂起也不影响计时显示。
    public var connectedSince: Date?
    /// 瞬时上行速率 byte/s。
    public var uploadSpeedBps: Int64
    /// 瞬时下行速率 byte/s。
    public var downloadSpeedBps: Int64
    /// 本次会话累计上行字节。
    public var uploadBytes: Int64
    /// 本次会话累计下行字节。
    public var downloadBytes: Int64

    public init(
        phase: Phase = .connecting,
        connectedSince: Date? = nil,
        uploadSpeedBps: Int64 = 0,
        downloadSpeedBps: Int64 = 0,
        uploadBytes: Int64 = 0,
        downloadBytes: Int64 = 0
    ) {
        self.phase = phase
        self.connectedSince = connectedSince
        self.uploadSpeedBps = uploadSpeedBps
        self.downloadSpeedBps = downloadSpeedBps
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
    }
}

extension QingzhouActivityContentState {
    /// 从 TUN 层流量快照构造动态内容（速率/字节直接取，phase / 计时起点由调用方给）。
    public init(phase: Phase, connectedSince: Date?, traffic: TrafficStats) {
        self.init(
            phase: phase,
            connectedSince: connectedSince,
            uploadSpeedBps: traffic.uploadSpeedBps,
            downloadSpeedBps: traffic.downloadSpeedBps,
            uploadBytes: traffic.uploadBytes,
            downloadBytes: traffic.downloadBytes
        )
    }
}

// ActivityKit 在原生 macOS 上「能 import 但协议标了 unavailable」，所以用 `#if os(iOS)`
// 而非 `canImport(ActivityKit)` —— Live Activity 只在 iOS / iPadOS 存在。
#if os(iOS)
import ActivityKit

/// Live Activity 的静态属性（活动生命周期内不变）：节点名 + 协议名。
/// 节点变了要换 attributes → ActivityKit 语义上必须结束旧活动再起新的（见 LiveActivityController）。
@available(iOS 16.1, *)
public struct QingzhouActivityAttributes: ActivityAttributes, Sendable {
    public typealias ContentState = QingzhouActivityContentState

    public var nodeName: String
    public var protocolName: String

    public init(nodeName: String, protocolName: String) {
        self.nodeName = nodeName
        self.protocolName = protocolName
    }
}
#endif
