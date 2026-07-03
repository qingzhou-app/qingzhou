// iOS App 入口。
//
// **注意**：主 App 不要 `import XrayCore`。XrayCore 拖入 LibXray.xcframework（85 MB
// Go runtime），dyld 在进程启动时把它整个加载完才进 main()，会让 app 黑屏 1–3 秒。
// share link → xray 配置的转换都在 Extension（Apps/Tunnel-Shared/PacketTunnelProvider.swift）
// 里跑 —— Extension 进程独立加载 LibXray，跟主 App 启动无关。

import SwiftUI
import QingzhouApp
import QingzhouLogging
import QingzhouCore

@main
struct VPNiOSApp: App {
    @State private var state: AppState = AppState(
        logger: Logger(capacity: 5000, minimumLevel: .debug)
    )

    var body: some Scene {
        WindowGroup {
            RootView(state: state)
                .preferredColorScheme(colorScheme(for: state.settings.theme))
                .environment(\.locale, LocaleResolver.locale(for: state.settings.language))
                .task {
                    state.startSchedulers()
                    #if DEBUG
                    // 远程验收钩子（仅 DEBUG）：让开发机能用
                    // `devicectl device process launch ... --qz-start-vpn` 驱动真机启停，
                    // 配合截图 / syslog 实现无人值守的真机回归。Release 构建不编译进来。
                    if CommandLine.arguments.contains("--qz-start-vpn") {
                        await state.startTunnel()
                    } else if CommandLine.arguments.contains("--qz-stop-vpn") {
                        await state.stopTunnel()
                    }
                    #endif
                    // 网络初始化延后到首屏稳定之后再跑：首次启动（尤其墙内/无网）这些请求会挂起，
                    // 别让它们和冷启动争抢。延迟 + 失败都不影响 UI。
                    try? await Task.sleep(for: .seconds(2))
                    if state.remoteRules.isEmpty {
                        await state.refreshRemoteRules()
                    }
                    await state.refreshPublicIPInfo()
                }
        }
    }

    private func colorScheme(for theme: AppearanceTheme) -> ColorScheme? {
        switch theme {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
