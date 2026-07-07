import Foundation
import QingzhouCore
#if os(iOS)
import ActivityKit
#endif

/// Live Activity 生命周期管家（灵动岛 / 锁屏实时活动，iOS 16.1+）。
///
/// **跨平台门面**：macOS 无 Live Activity，所有方法在非 iOS 上是 no-op —— AppState 的调用点
/// 因此不必到处套 `#if os(iOS)`，隔离都收在本文件里。部署目标 iOS 17 ≥ 16.1，ActivityKit
/// 符号恒可用，无需运行期 `if #available` 判断。
///
/// **更新驱动**：由主 App 的 `trafficPollingLoop` 每秒调 `sync(...)` 推进 —— **不在 appex 里
/// 加负担**（iOS NE 50MB 硬上限，见 memory）。主 App 进后台被系统挂起时更新自然停止，锁屏/
/// 灵动岛的计时器仍靠 `Text(_:style:.timer)` 自走字，速率则冻结在最后一次值（MVP 取舍）。
///
/// **节点切换**：ActivityKit 的 attributes（节点名/协议）活动期内不可变，所以换节点必须结束
/// 旧活动再起新的 —— `start(...)` 内部检测 nodeName 变化自动处理。
///
/// **并发**：`Activity` 未被 Apple 标 `Sendable`，其 `update`/`end` 又是 nonisolated async ——
/// Swift 6 严格并发下不允许把 MainActor 隔离的 activity 直接送进这些方法。用 `ActivityBox`
/// (`@unchecked Sendable`) 把「起 / 更新 / 结束」整段搬进 nonisolated 的 fire-and-forget Task
/// 里执行（ActivityKit 内部自行串行化系统侧写入，这里的 @unchecked 只是补上缺失的标注）。
@MainActor
public final class LiveActivityController {
    public init() {}

    #if os(iOS)
    private var activity: Activity<QingzhouActivityAttributes>?

    /// 把非 Sendable 的 `Activity` 裹进 Sendable 盒子，供 fire-and-forget Task 捕获。
    private struct ActivityBox: @unchecked Sendable {
        let activity: Activity<QingzhouActivityAttributes>
    }
    #endif

    /// 系统是否允许起实时活动（用户可能在系统设置里全局关掉了「实时活动」）。
    public var systemEnabled: Bool {
        #if os(iOS)
        return ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        return false
        #endif
    }

    /// 起 / 刷新一个 Live Activity（幂等）：
    /// - 没有活动 → `Activity.request` 起一个；
    /// - 已有同节点活动 → 转 `update`；
    /// - 已有但节点名变了 → 结束旧的再起新的（attributes 不可变）。
    ///
    /// 系统未授权 / 起失败都静默降级（不影响 VPN 本体）。
    public func start(nodeName: String, protocolName: String, state: QingzhouActivityContentState) {
        #if os(iOS)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // 采认上次进程遗留的活动（主 App 被杀但 Live Activity 还在），避免起重复的。
        if activity == nil {
            activity = Activity<QingzhouActivityAttributes>.activities.first
        }
        if let current = activity {
            if current.attributes.nodeName == nodeName {
                fireUpdate(current, state)
                return
            }
            // 节点变了：结束旧活动，落到下面起新的。
            fireEnd(current)
            activity = nil
        }
        let attributes = QingzhouActivityAttributes(nodeName: nodeName, protocolName: protocolName)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            activity = nil
        }
        #endif
    }

    /// 更新当前活动的动态内容。没有活动时无操作。
    public func update(_ state: QingzhouActivityContentState) {
        #if os(iOS)
        guard let activity else { return }
        fireUpdate(activity, state)
        #endif
    }

    /// 结束当前活动（用户主动关 VPN / 会话结束）。顺带结束任何遗留活动，避免残留。
    public func endAll() {
        #if os(iOS)
        let tracked = activity
        activity = nil
        let all = Activity<QingzhouActivityAttributes>.activities
        guard tracked != nil || !all.isEmpty else { return }
        let boxes = all.map { ActivityBox(activity: $0) }
        Task {
            for box in boxes {
                await box.activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        #endif
    }

    #if os(iOS)
    private func fireUpdate(_ activity: Activity<QingzhouActivityAttributes>, _ state: QingzhouActivityContentState) {
        let box = ActivityBox(activity: activity)
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await box.activity.update(content) }
    }

    private func fireEnd(_ activity: Activity<QingzhouActivityAttributes>) {
        let box = ActivityBox(activity: activity)
        Task { await box.activity.end(nil, dismissalPolicy: .immediate) }
    }
    #endif
}
