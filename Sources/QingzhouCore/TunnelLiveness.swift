import Foundation

/// 隧道「转发层」真相 —— 区别于「会话层」真相（NEVPNStatus）。
///
/// 为什么需要两层：`NEVPNStatus == .connected` 只说明系统里有一个 VPN 会话，**不保证
/// 隧道扩展进程还活着、xray 还在转发流量**。崩溃循环就是反例——扩展崩了、On-Demand
/// 秒拉起，会话状态只闪一下，而那几秒流量是断的。
///
/// 判活信号 = App Group 的流量心跳（`traffic-stats.json` 的 `sampledAt`）。扩展用每秒
/// 无条件触发的 DispatchSource 定时器写它（即使空闲无流量也写，只是速率为 0），所以
/// **心跳新鲜 = 扩展进程活着且统计循环在跑；心跳过期 = 扩展死了 / 卡住**（不会把「你只是
/// 没上网」误判成死亡）。任何进程（widget / 主 App）读到心跳文件都能据此判活。
public enum TunnelForwarding: Sendable, Equatable {
    /// 会话在 + 心跳新鲜 → 真的在转发。
    case forwarding
    /// 会话在 + 心跳过期 → 扩展疑似死亡 / 卡住（zombie 隧道）。
    case stalled
    /// 没有心跳数据（刚起、从未写过、或非连接态）→ 不下判断。
    case unknown
}

public enum TunnelLiveness {
    /// 心跳新鲜窗口（秒）。扩展每秒写一次，正常情况下读到的心跳 ≤1~2 秒新。留 10 秒
    /// 余量吸收：读取本身的时序、文件写入延迟、widget 刷新时机——只有**真正**死掉 /
    /// 卡死的扩展才会超过它。比主 App 波形判活的 5 秒宽，因为 widget 读取时机不受控。
    public static let heartbeatFreshWindow: TimeInterval = 10

    /// 由「最近一次心跳时刻」判定转发层真相。lastHeartbeat 为 nil（无数据）→ unknown。
    public static func forwarding(lastHeartbeat: Date?, now: Date = Date()) -> TunnelForwarding {
        guard let lastHeartbeat else { return .unknown }
        return abs(now.timeIntervalSince(lastHeartbeat)) <= heartbeatFreshWindow
            ? .forwarding
            : .stalled
    }
}
