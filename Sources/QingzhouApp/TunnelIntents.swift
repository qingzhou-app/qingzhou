import AppIntents
import Foundation
import NetworkExtension

// 轻舟的 App Intents —— 暴露给「快捷指令」/ Siri / 桌面小组件按钮 / iOS 自动化。
//
// 设计：Intent 在独立轻量进程里跑（不是主 App UI 进程），所以不能依赖 AppState。
// 它直接 new 一个 VPNTunnelManager、load 出主 App 之前保存好的隧道配置（含当前节点），
// 再 start / stop。用户只要在主 App 里配过一次节点，这些 Intent 就能用「上次的节点」启停。
//
// 「打开某 App 自动开 VPN」：
//   - iOS：用户在「快捷指令 → 自动化 → App → 已打开/已关闭」里挂 StartVPNIntent/StopVPNIntent，
//     勾「立即运行」即静默生效（我们只需提供 Intent，自动化由用户配）。
//   - macOS：Shortcuts 没有 App 打开/关闭触发器，改用主 App 内的 AppLaunchWatcher（见 AppLaunchWatcher.swift）。

@available(iOS 16.0, macOS 13.0, *)
enum TunnelIntentRunner {
    @MainActor static func start() async throws {
        let mgr = VPNTunnelManager()
        try await mgr.load()
        // 重开 On-Demand（用户上次可能主动关过、把它落盘成 false），让隧道在 App 被杀后仍保持。
        try? await mgr.setOnDemandEnabled(true)
        try await mgr.start()
    }
    @MainActor static func stop() async throws {
        let mgr = VPNTunnelManager()
        try await mgr.load()
        // 用户主动关：先关 On-Demand 并落盘，否则规则会立刻把隧道重连回来。
        try? await mgr.setOnDemandEnabled(false)
        mgr.stop()
    }
    /// 当前隧道是否在跑（含建立中 / 重连中）。给状态查询 Intent 用。
    @MainActor static func isActive() async throws -> Bool {
        let mgr = VPNTunnelManager()
        try await mgr.load()
        return AppState.isTunnelActive(mgr.status)
    }
    /// 在跑就关、没跑就开。
    @MainActor static func toggle() async throws {
        let mgr = VPNTunnelManager()
        try await mgr.load()
        switch mgr.status {
        case .connected, .connecting, .reasserting:
            try? await mgr.setOnDemandEnabled(false)
            mgr.stop()
        default:
            try? await mgr.setOnDemandEnabled(true)
            try await mgr.start()
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct StartVPNIntent: AppIntent {
    public static let title: LocalizedStringResource = "开启轻舟"
    public static let description = IntentDescription("连接到上次使用的节点。")
    public static let openAppWhenRun = false
    public init() {}
    public func perform() async throws -> some IntentResult {
        try await TunnelIntentRunner.start()
        return .result()
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct StopVPNIntent: AppIntent {
    public static let title: LocalizedStringResource = "关闭轻舟"
    public static let description = IntentDescription("断开当前 VPN 连接。")
    public static let openAppWhenRun = false
    public init() {}
    public func perform() async throws -> some IntentResult {
        try await TunnelIntentRunner.stop()
        return .result()
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct ToggleVPNIntent: AppIntent {
    public static let title: LocalizedStringResource = "切换轻舟"
    public static let description = IntentDescription("VPN 在跑就关、没跑就开。")
    public static let openAppWhenRun = false
    public init() {}
    public func perform() async throws -> some IntentResult {
        try await TunnelIntentRunner.toggle()
        return .result()
    }
}

/// 查询 VPN 当前是否已连接 —— 返回布尔值，供「快捷指令」自动化做条件分支
/// （例：打开某 App 时「如果 轻舟已连接 = 否 → 开启轻舟」，避免重复启动弹提示）。
@available(iOS 16.0, macOS 13.0, *)
public struct GetVPNStatusIntent: AppIntent {
    public static let title: LocalizedStringResource = "轻舟是否已连接"
    public static let description = IntentDescription("返回 VPN 当前是否已连接（布尔值），可在自动化里做条件判断。")
    public static let openAppWhenRun = false
    public init() {}
    public func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let connected = try await TunnelIntentRunner.isActive()
        return .result(value: connected, dialog: IntentDialog(stringLiteral: connected ? "轻舟已连接" : "轻舟未连接"))
    }
}

// Siri 短语 + 快捷指令库里的预置动作。`\(.applicationName)` 会被替换成 App 名。
// 注：AppShortcutsProvider 需要被 App 主 bundle 扫描到；app target 引用 QingzhouApp 即可。
@available(iOS 16.0, macOS 13.0, *)
public struct QingzhouAppShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleVPNIntent(),
            phrases: ["切换\(.applicationName)", "Toggle \(.applicationName)"],
            shortTitle: "切换 VPN",
            systemImageName: "power"
        )
        AppShortcut(
            intent: StartVPNIntent(),
            phrases: ["开启\(.applicationName)", "用\(.applicationName)连接"],
            shortTitle: "开启 VPN",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: StopVPNIntent(),
            phrases: ["关闭\(.applicationName)", "断开\(.applicationName)"],
            shortTitle: "关闭 VPN",
            systemImageName: "stop.fill"
        )
    }
}
