import AppIntents
import Foundation

// 专注模式（Focus）联动（E.19 任务 2，iOS 16+/macOS 13+）。
//
// 让用户在系统「设置 → 专注模式 → [某专注] → 添加过滤器 → 轻舟」里，给这个专注配一条
// 规则：专注开启时自动「连接 / 断开 / 不改变」VPN。系统在专注切换时**在后台**调用本
// intent 的 perform() —— 走和快捷指令 / 控制中心完全相同的 TunnelIntentRunner 启停路径
// （独立轻量进程、不依赖 AppState、用上次落盘的节点配置）。
//
// 最小可用：只做「开 / 关 / 不动」。切代理模式 / 指定节点等更细的联动留待后续（决策逻辑
// 已抽成纯枚举 FocusVPNAction.tunnelCommand，扩展时只加 case + 映射即可，可单测）。

/// 专注模式激活时对 VPN 采取的动作。作为 SetFocusFilterIntent 的可配置参数（AppEnum →
/// 系统专注设置里渲染成下拉选择）。
@available(iOS 16.0, macOS 13.0, *)
public enum FocusVPNAction: String, AppEnum, Sendable {
    case connect
    case disconnect
    case noChange

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "专注开启时" }

    public static var caseDisplayRepresentations: [FocusVPNAction: DisplayRepresentation] {
        [
            .connect: DisplayRepresentation(title: "连接 VPN"),
            .disconnect: DisplayRepresentation(title: "断开 VPN"),
            .noChange: DisplayRepresentation(title: "不改变"),
        ]
    }
}

/// 隧道指令（纯决策的产物）：起 / 停。nil 表示不动。
public enum FocusTunnelCommand: Sendable, Equatable {
    case start
    case stop
}

@available(iOS 16.0, macOS 13.0, *)
extension FocusVPNAction {
    /// 纯决策：这个动作对应要不要启停隧道。抽出来便于单测（perform 只是把它接到
    /// TunnelIntentRunner）。
    public var tunnelCommand: FocusTunnelCommand? {
        switch self {
        case .connect:    return .start
        case .disconnect: return .stop
        case .noChange:   return nil
        }
    }
}

/// 轻舟的专注模式过滤器。系统在专注开启时后台调用 perform()。
@available(iOS 16.0, macOS 13.0, *)
public struct QingzhouFocusFilterIntent: SetFocusFilterIntent {
    public static let title: LocalizedStringResource = "轻舟 VPN"
    public static let description = IntentDescription("专注模式开启时自动连接或断开 VPN。")
    // 后台静默执行，别把主 App 拉到前台。
    public static let openAppWhenRun = false

    @Parameter(title: "专注开启时", default: .noChange)
    public var action: FocusVPNAction

    public init() {}

    public init(action: FocusVPNAction) {
        self.action = action
    }

    /// 在系统专注设置里显示的当前配置摘要（一行说明这条过滤器会做什么）。
    public var displayRepresentation: DisplayRepresentation {
        switch action {
        case .connect:    return DisplayRepresentation(title: "连接 VPN")
        case .disconnect: return DisplayRepresentation(title: "断开 VPN")
        case .noChange:   return DisplayRepresentation(title: "不改变 VPN")
        }
    }

    public func perform() async throws -> some IntentResult {
        switch action.tunnelCommand {
        case .start: try await TunnelIntentRunner.start()
        case .stop:  try await TunnelIntentRunner.stop()
        case .none:  break
        }
        return .result()
    }
}
