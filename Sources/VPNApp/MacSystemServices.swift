#if os(macOS)
import Foundation
import ServiceManagement
import VPNLogging

/// 包装 macOS 系统级集成。`MacSystemServices` 是 namespace，里面的 API 都是静态的。
///
/// 注：系统代理（networksetup）已彻底移除 —— TUN 模式已接管整机流量，系统代理纯属冗余，
/// 且在 App Sandbox 下无法调用 networksetup。只保留「开机自启」。
public enum MacSystemServices {

    // MARK: - 开机自启

    /// 返回当前主 app 是否注册为登录项。
    public static func isLoginItemEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 注册 / 注销主 app 的开机自启。
    /// - Returns: 操作后的最终状态（true 表示已启用）。
    @discardableResult
    public static func setLoginItem(_ enabled: Bool, logger: Logger? = nil) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            logger?.error("Toggle login item failed: \(error)", category: "system")
        }
        return service.status == .enabled
    }
}

extension AppState {
    /// 应用 macOS 系统设置：目前只有开机自启。
    @MainActor
    public func applyMacSystemPreferences() {
        let loginActual = MacSystemServices.setLoginItem(settings.launchAtLogin, logger: logger)
        if loginActual != settings.launchAtLogin {
            settings.launchAtLogin = loginActual
        }
    }
}
#endif
