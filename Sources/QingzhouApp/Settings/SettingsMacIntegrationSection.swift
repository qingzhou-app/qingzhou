#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsMacIntegrationSection: View {
    @Bindable var state: AppState
    @State private var filterEnabled = false

    var body: some View {
        Section("macOS 集成") {
            Toggle("开机自启", isOn: state.setting(\.launchAtLogin))
            Button("立即应用") {
                state.applyMacSystemPreferences()
            }
            autoConnectRows
            // 「来源 App 标注」入口暂时隐藏（功能搁置，见 FeatureFlags.sourceAppLabeling）。
            if FeatureFlags.sourceAppLabeling {
                Button(filterEnabled ? LocalizedStringKey("关闭来源 App 标注") : LocalizedStringKey("启用来源 App 标注")) {
                    ContentFilterManager.shared.onNeedsApproval = {
                        state.showToast(L("请到「系统设置 → 通用 → 登录项与扩展 → 网络扩展」批准轻舟"))
                    }
                    Task {
                        do {
                            if filterEnabled {
                                try await ContentFilterManager.shared.disable()
                            } else {
                                try await ContentFilterManager.shared.activateAndEnable()
                            }
                            filterEnabled = ContentFilterManager.isEnabled
                            state.showToast(filterEnabled ? L("已启用来源 App 标注") : L("已关闭来源 App 标注"))
                        } catch {
                            let ns = error as NSError
                            state.showToast(L("失败 [\(ns.domain) #\(ns.code)] \(ns.localizedDescription)"))
                            state.logger.error("Content filter toggle failed: domain=\(ns.domain) code=\(ns.code) info=\(ns.userInfo)", category: "filter")
                        }
                    }
                }
                .task { filterEnabled = ContentFilterManager.isEnabled }
                Text("开启后「连接」页会标注每条流量是哪个 App 发起的。首次要在系统设置批准扩展 + 授权过滤。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// 「打开指定 App 自动连」：开关 + 触发 App 列表 + 添加按钮。
    /// iOS 没有对应系统能力（Shortcuts 自动化可实现同样效果），故仅 macOS。
    @ViewBuilder
    private var autoConnectRows: some View {
        Toggle("打开指定 App 时自动连接", isOn: state.setting(\.autoConnectOnAppLaunch))
        if state.settings.autoConnectOnAppLaunch {
            ForEach(state.settings.autoConnectApps.sorted(), id: \.self) { bundleID in
                HStack {
                    let info = Self.appDisplayInfo(for: bundleID)
                    if let icon = info.icon {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    }
                    Text(info.name)
                    Spacer()
                    Button {
                        var apps = state.settings.autoConnectApps
                        apps.remove(bundleID)
                        state.setting(\.autoConnectApps).wrappedValue = apps
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("移除")
                }
            }
            Button {
                addAutoConnectApps()
            } label: {
                Label("添加 App…", systemImage: "plus")
            }
            Text("任一所选 App 启动 → 自动连接；全部退出 → 自动断开（只断开由自动连接拉起的会话，手动开启的 VPN 不受影响）。iPhone/iPad 上可用「快捷指令 → 自动化 → App」实现同样效果。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// NSOpenPanel 选 .app → 读 bundle id 存入设置。选不出 bundle id 的（损坏包）静默跳过。
    private func addAutoConnectApps() {
        let panel = NSOpenPanel()
        panel.title = L("选择触发自动连接的 App")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        var apps = state.settings.autoConnectApps
        for url in panel.urls {
            if let bid = Bundle(url: url)?.bundleIdentifier { apps.insert(bid) }
        }
        state.setting(\.autoConnectApps).wrappedValue = apps
    }

    /// bundle id → 展示名 + 图标（App 已卸载时退化显示 bundle id）。
    private static func appDisplayInfo(for bundleID: String) -> (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return (bundleID, nil)
        }
        let name = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? FileManager.default.displayName(atPath: url.path)
        return (name, NSWorkspace.shared.icon(forFile: url.path))
    }
}
#endif
