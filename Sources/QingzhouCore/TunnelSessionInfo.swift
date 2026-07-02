import Foundation

/// 隧道会话标记 —— 扩展写 App Group（`tunnel-session.json`）、主 App 轮询读。
///
/// 用途（VPN 定时自动关闭）：
/// - 主 App 用「启动时刻 + 时长」推算剩余时间画倒计时，**不依赖**和扩展的实时通信
///   （providerMessage / XPC），主 App 被杀重启后也能恢复显示；
/// - 扩展到点自停时回填 `stoppedAt`，主 App 看到它 + 隧道确实断了，就把开关归位并提示
///   「已按定时断开」—— 区别于用户手动关和异常断开。
///
/// 编解码统一 ISO8601 日期策略（与 AppGroupStorage 一致），两个进程才能互读。
public struct TunnelSessionInfo: Codable, Sendable, Equatable {
    /// 本次会话（xray 成功起来那刻 / 运行中重设定时那刻）的计时起点。
    public var startedAt: Date
    /// 本次会话的定时时长，秒。0 = 未启用定时。
    public var autoStopSeconds: TimeInterval
    /// 扩展按定时自停的时刻。nil = 还没到点（或没启用定时）。
    public var stoppedAt: Date?

    public init(startedAt: Date, autoStopSeconds: TimeInterval, stoppedAt: Date? = nil) {
        self.startedAt = startedAt
        self.autoStopSeconds = autoStopSeconds
        self.stoppedAt = stoppedAt
    }

    /// 到点时刻。未启用定时（<= 0）时为 nil。
    public var deadline: Date? {
        autoStopSeconds > 0 ? startedAt.addingTimeInterval(autoStopSeconds) : nil
    }
}
