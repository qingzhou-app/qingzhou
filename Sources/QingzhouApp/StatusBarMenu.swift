#if os(macOS)
import SwiftUI
import QingzhouCore

/// macOS 状态栏菜单内容。在 app 入口里通过 `MenuBarExtra { StatusBarMenu(...) }` 使用。
public struct StatusBarMenu: View {
    @Bindable var state: AppState

    public init(state: AppState) { self.state = state }

    public var body: some View {
        Toggle(
            state.isSwitchingTunnel ? "切换中…" : (state.isVPNRunning ? "VPN 已连接" : "VPN 未连接"),
            isOn: state.vpnRunningBinding
        )
        .disabled(state.isSwitchingTunnel)

        if let node = state.currentNode {
            Text("→ \(node.name)\(node.lastLatencyMs.map { " · \($0)ms" } ?? "")")
                .font(.caption)
        }

        Divider()

        Picker("模式", selection: state.proxyModeBinding) {
            Text("全局").tag(ProxyMode.global)
            Text("规则").tag(ProxyMode.rule)
            Text("直连").tag(ProxyMode.direct)
        }
        .pickerStyle(.inline)

        Divider()

        Menu("选择节点") {
            if state.nodes.isEmpty {
                Text("无可用节点").disabled(true)
            } else {
                ForEach(state.sortedNodes.prefix(20)) { node in
                    Button {
                        state.select(node)
                    } label: {
                        let mark = state.currentNodeId == node.id ? "✓ " : "  "
                        let lat = node.lastLatencyMs.map { " (\($0)ms)" } ?? ""
                        let excl = node.isExcluded ? " 🚫" : ""
                        Text("\(mark)\(node.name)\(lat)\(excl)")
                    }
                }
                if state.sortedNodes.count > 20 {
                    Text("还有 \(state.sortedNodes.count - 20) 个，去 app 内查看")
                        .disabled(true)
                }
            }
        }

        if !state.subscriptions.isEmpty {
            Menu("订阅 (\(state.subscriptions.count))") {
                ForEach(state.subscriptions) { sub in
                    Button {
                        Task { await state.refreshSubscription(sub) }
                    } label: {
                        Text("刷新：\(sub.name)")
                    }
                }
            }
        }

        Divider()

        Button("一键测速并择优") {
            Task { await state.autoSelectBestNode() }
        }

        Button("刷新远程规则") {
            Task { await state.refreshRemoteRules() }
        }

        Divider()

        Button("打开主窗口") {
            // 主窗口 SwiftUI 场景：唤起首个 WindowGroup
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }

        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

/// 状态栏图标。必须是独立 View 而不是在 MenuBarExtra 的 label 闭包里直接读 state ——
/// @Observable 的依赖追踪只在 View.body 求值时登记，Scene 层闭包里读状态不建立观察，
/// 状态变了图标不重绘（实测：VPN 开关/热切换后菜单栏图标不更新）。
public struct StatusBarIcon: View {
    @Bindable var state: AppState

    public init(state: AppState) { self.state = state }

    public var body: some View {
        // 已连接=满格三角；切换中=半格；断开=空心
        if state.isSwitchingTunnel {
            Image(systemName: "triangle.lefthalf.filled")
        } else {
            Image(systemName: state.isVPNRunning ? "triangle.fill" : "triangle")
        }
    }
}
#endif
