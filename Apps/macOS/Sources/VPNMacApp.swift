// 示例：macOS App 入口。
//
// 包含两个 Scene：
// - Window 提供唯一主窗口
// - MenuBarExtra 提供状态栏菜单（macOS 13+）
//
// 同样，真要让代理工作需要 Network Extension Target 和 entitlements，详见 docs/BUILD.md。

import os
import SwiftUI
import QingzhouApp
import QingzhouLogging
import QingzhouCore

#if os(macOS)
import AppKit

/// 单实例守卫：全机只允许一个轻舟 macOS 实例运行。
///
/// 历史坑：曾同时从 /Applications、DerivedData、/tmp 启动多份实例，
/// 造成 VPN 状态互抢、App Group 文件互相覆盖等真实问题。
/// 这里在展示 UI 之前（applicationWillFinishLaunching）就检测同 bundle id
/// 的其它进程，若存在则激活既有实例并退出自己。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sbraveyoung.qingzhou.mac"
        let myPID = ProcessInfo.processInfo.processIdentifier
        let currentApp = NSRunningApplication.current

        // 找出所有同 bundle id 且不是自己的运行进程。
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID && $0 != currentApp }

        guard let existing = others.first else { return }

        // 已有实例在跑：把它拉到前台，然后退出自己。
        existing.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
    }
}
#endif

@main
struct VPNMacApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @State private var state: AppState = AppState(
        logger: Logger(capacity: 10000, minimumLevel: .debug)
    )

    @State private var didStart = false

    var body: some Scene {
        Window("轻舟", id: MainWindowButton.sceneID) {
            RootView(state: state)
                .frame(minWidth: 880, minHeight: 560)
                .preferredColorScheme(colorScheme(for: state.settings.theme))
                .environment(\.locale, LocaleResolver.locale(for: state.settings.language))
                .task {
                    guard !didStart else { return }
                    didStart = true
                    state.startSchedulers()
                    state.applyMacSystemPreferences()
                    #if DEBUG
                    // 远程验收钩子（仅 DEBUG，同 iOS 壳）：`open Qingzhou.app --args --qz-lang-en`
                    // 切语言；l10n 自检日志用 `log show --predicate 'subsystem == "com.sbraveyoung.qingzhou.diag"'` 读
                    if CommandLine.arguments.contains("--qz-lang-en") {
                        state.setting(\.language).wrappedValue = .en
                    } else if CommandLine.arguments.contains("--qz-lang-zh") {
                        state.setting(\.language).wrappedValue = .zhHans
                    }
                    let diag = os.Logger(subsystem: "com.sbraveyoung.qingzhou.diag", category: "l10n")
                    diag.info("lang=\(state.settings.language.rawValue, privacy: .public) bundle=\(L10n.bundle.bundlePath, privacy: .public) 关闭→\(L("关闭"), privacy: .public) 定时=\(AutoStopPresets.label(for: 0), privacy: .public)")
                    #endif
                    if state.remoteRules.isEmpty {
                        await state.refreshRemoteRules()
                    }
                    await state.refreshPublicIPInfo()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                MainWindowButton().keyboardShortcut("1", modifiers: .command)
            }
        }

        // 标准设置场景：让 ⌘, 和菜单栏「设置…」能打开设置窗口（macOS 用户的肌肉记忆）。
        // 复用主窗口同一个 AppState 实例，改动即时双向同步；SettingsView 本身不感知宿主差异。
        Settings {
            SettingsView(state: state)
                .frame(minWidth: 560, minHeight: 520)
                .preferredColorScheme(colorScheme(for: state.settings.theme))
                .environment(\.locale, LocaleResolver.locale(for: state.settings.language))
        }

        MenuBarExtra {
            StatusBarMenu(state: state)
                .environment(\.locale, LocaleResolver.locale(for: state.settings.language))
        } label: {
            // 独立 View 才能建立 @Observable 观察 —— 在这个 Scene 闭包里直接读 state
            // 不会触发重绘（状态变了图标不更新的历史 bug）。见 StatusBarIcon 注释。
            StatusBarIcon(state: state)
        }
        .menuBarExtraStyle(.menu)
    }

    private func colorScheme(for theme: AppearanceTheme) -> ColorScheme? {
        switch theme {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
