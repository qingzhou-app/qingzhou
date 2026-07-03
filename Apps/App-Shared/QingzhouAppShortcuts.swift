// App Shortcuts：快捷指令 App 里「拿来即用」的预置动作 + Siri 短语。
//
// ⚠️ 必须放在 **app target**（本文件由 Qingzhou-iOS / Qingzhou-macOS 两个 target 共享）。
// 放 SPM 包（QingzhouApp）里时 appintentsmetadataprocessor 不抽取 AppShortcutsProvider ——
// 主 App Metadata.appintents 的 autoShortcuts 是空数组，快捷指令 App 搜不到「轻舟」、
// Siri 短语失效（真机踩过）。Intent 本身留在包里没问题（actions 抽取正常），
// 经 AppIntentsPackage 声明让 app target 的抽取器把包也纳入扫描范围。

import AppIntents
import QingzhouApp

/// 把 QingzhouApp 包纳入本 app 的 App Intents 元数据抽取范围。
@available(iOS 16.0, macOS 13.0, *)
struct QingzhouAppIntentsHost: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [QingzhouIntentsPackage.self]
    }
}

// `\(.applicationName)` 会被替换成 App 名（轻舟）。
@available(iOS 16.0, macOS 13.0, *)
struct QingzhouAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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
