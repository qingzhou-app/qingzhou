import AppIntents
import Foundation
import NetworkExtension
import os

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
    /// Intent 在独立进程（主 App 后台拉起 / widget 扩展 / 控制中心）里跑，我们的
    /// QingzhouLogging.Logger 落在各自进程内存里根本看不见 —— 全链路走 os_log，
    /// Console.app 过滤 subsystem `com.sbraveyoung.qingzhou.intents` 即可诊断。
    static let log = os.Logger(subsystem: "com.sbraveyoung.qingzhou.intents", category: "runner")

    @MainActor static func start() async throws {
        log.info("start: loading VPN preferences")
        let mgr = VPNTunnelManager()
        do {
            try await mgr.load()
            // 重开 On-Demand（用户上次可能主动关过、把它落盘成 false），让隧道在 App 被杀后仍保持。
            try? await mgr.setOnDemandEnabled(true)
            try await mgr.start()
        } catch {
            log.error("start failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        // ⚠️ 等状态尘埃落定再返回：widget 按钮 / 控制中心的 intent 一返回，WidgetKit 就
        // 重载时间线 —— 提交即返回会让重载落在 connecting 窗口，widget 长时间停在「切换中」
        // （真机上 .after(15s) 的补刷并不可靠，实测会卡住）。
        await waitUntilSettled(mgr)
        log.info("start: settled at \(mgr.status.rawValue)")
    }
    @MainActor static func stop() async throws {
        log.info("stop: loading VPN preferences")
        let mgr = VPNTunnelManager()
        do {
            try await mgr.load()
        } catch {
            log.error("stop failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        // 用户主动关：先关 On-Demand 并落盘，否则规则会立刻把隧道重连回来。
        try? await mgr.setOnDemandEnabled(false)
        mgr.stop()
        await waitUntilSettled(mgr)
        log.info("stop: settled at \(mgr.status.rawValue)")
    }
    /// 当前隧道是否在跑（含建立中 / 重连中）。给状态查询 Intent 用。
    @MainActor static func isActive() async throws -> Bool {
        let mgr = VPNTunnelManager()
        try await mgr.load()
        let active = AppState.isTunnelActive(mgr.status)
        log.info("isActive → \(active) (status \(mgr.status.rawValue))")
        return active
    }
    /// 在跑就关、没跑就开。
    @MainActor static func toggle() async throws {
        let mgr = VPNTunnelManager()
        try await mgr.load()
        log.info("toggle: current status \(mgr.status.rawValue)")
        switch mgr.status {
        case .connected, .connecting, .reasserting:
            try? await mgr.setOnDemandEnabled(false)
            mgr.stop()
        default:
            try? await mgr.setOnDemandEnabled(true)
            do {
                try await mgr.start()
            } catch {
                log.error("toggle start failed: \(String(describing: error), privacy: .public)")
                throw error
            }
        }
        await waitUntilSettled(mgr)
        log.info("toggle: settled at \(mgr.status.rawValue)")
    }

    /// 轮询到 NEVPNStatus 离开过渡态（connecting / disconnecting / reasserting）为止，
    /// 超时兜底（规则模式加载 geo 可达数秒；12 秒覆盖绝大多数情况，超时也不算失败）。
    @MainActor static func waitUntilSettled(_ mgr: VPNTunnelManager, timeout: TimeInterval = 12) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch mgr.status {
            case .connected, .disconnected, .invalid:
                return
            default:
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        log.warning("waitUntilSettled: timed out at status \(mgr.status.rawValue)")
    }
}

/// SPM 包里的 App Intents 要被 app target 的元数据抽取器看到，规范做法是包声明
/// AppIntentsPackage、app target 侧再 includedPackages 引用（见 Apps/App-Shared/）。
@available(iOS 16.0, macOS 13.0, *)
public struct QingzhouIntentsPackage: AppIntentsPackage {
    public init() {}
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

// ⚠️ AppShortcutsProvider（Siri 短语 + 快捷指令预置动作）**不在这里** ——
// 放 SPM 包里 appintentsmetadataprocessor 不抽取（主 App Metadata.appintents 的
// autoShortcuts 是空数组，快捷指令 App 里搜不到、Siri 短语失效，真机踩过）。
// 它必须定义在 app target：见 Apps/App-Shared/QingzhouAppShortcuts.swift。
