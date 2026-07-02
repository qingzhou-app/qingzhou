import SwiftUI
import QingzhouCore

/// 跨平台根视图。iOS 用 TabView，macOS 用 NavigationSplitView。
public struct RootView: View {
    @Bindable public var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        rootContent
            .overlay(alignment: .top) { toastOverlay }
            .animation(.spring(duration: 0.3), value: state.toast)
            // iCloud vault：云端备份更新（或新装机）时的恢复确认。挂在根上 —— 启动检查
            // 在任何页面都能弹；设置页的「立即恢复」也复用这里。
            .alert(
                "发现 iCloud 备份",
                isPresented: cloudRestoreAlertBinding,
                presenting: state.cloudRestoreOffer
            ) { offer in
                // ⚠️ 必须用 presenting 闭包参数 offer（呈现 alert 那一刻捕获的值）传给恢复：
                // 按钮 action 的 Task 执行前，dismiss 会先经 isPresented binding 调
                // declineCloudRestore() 把 state.cloudRestoreOffer 清成 nil —— Task 里
                // 再读它恒为 nil，用户选的历史版本会被忽略、错恢复成云端主文档（真机踩过）。
                Button("恢复") { Task { await state.restoreFromCloud(candidate: offer) } }
                Button("暂不恢复", role: .cancel) { state.declineCloudRestore() }
            } message: { offer in
                // 内容计数放最前 —— 「0 个订阅 · 0 个节点」一眼可见，防止误恢复空数据
                Text("内容：\(offer.header.contentSummary)\n"
                     + "来自 \(offer.header.deviceName)，"
                     + "\(offer.header.modifiedAt.formatted(date: .abbreviated, time: .shortened))。\n"
                     + "恢复会用它覆盖本机配置；本机当前配置会先自动备份。")
            }
    }

    /// alert 的显隐 Binding：关掉（点按钮 / 系统 dismiss）等价于「暂不恢复」。
    private var cloudRestoreAlertBinding: Binding<Bool> {
        Binding(
            get: { state.cloudRestoreOffer != nil },
            set: { if !$0 { state.declineCloudRestore() } }
        )
    }

    @ViewBuilder private var rootContent: some View {
        #if os(iOS)
        iOSRoot
        #else
        macOSRoot
        #endif
    }

    @ViewBuilder private var toastOverlay: some View {
        if let toast = state.toast {
            Text(toast)
                .font(.subheadline)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.secondary.opacity(0.2)))
                .shadow(radius: 8, y: 2)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    #if os(iOS)
    private var iOSRoot: some View {
        // 超过 5 个 tab 时 iPhone 会自动把多出来的塞进 "More" tab。
        // selection 绑定 state.activeSection —— 首页空态按钮等可编程式切 tab。
        TabView(selection: $state.activeSection) {
            NavigationStack { HomeView(state: state) }
                .tabItem { Label("首页", systemImage: "house") }
                .tag(AppSection.home)
            NavigationStack { NodesView(state: state) }
                .tabItem { Label("节点", systemImage: "server.rack") }
                .tag(AppSection.nodes)
            NavigationStack { SubscriptionsView(state: state) }
                .tabItem { Label("订阅", systemImage: "tray.full") }
                .tag(AppSection.subscriptions)
            NavigationStack { RulesView(state: state) }
                .tabItem { Label("规则", systemImage: "list.bullet.rectangle") }
                .tag(AppSection.rules)
            NavigationStack { ConnectionsView(state: state) }
                .tabItem { Label("连接", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(AppSection.connections)
            NavigationStack { LogsView(state: state) }
                .tabItem { Label("日志", systemImage: "doc.text.magnifyingglass") }
                .tag(AppSection.logs)
            NavigationStack { SettingsView(state: state) }
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(AppSection.settings)
        }
    }
    #else
    private var macOSRoot: some View {
        // 侧栏由 push 式 NavigationLink 改为 selection 驱动：detail 跟随
        // state.activeSection 切换，任意视图（首页空态按钮 / 菜单栏等）都能编程式换页。
        NavigationSplitView {
            List(selection: sidebarSelectionBinding) {
                ForEach(AppSection.allCases, id: \.self) { section in
                    Text(section.sidebarTitle).tag(section)
                }
            }
            .navigationTitle("VPN")
            .frame(minWidth: 180)
        } detail: {
            // 包一层 NavigationStack：detail 内的 navigationDestination push（如流量卡
            // →连接明细）才有宿主。
            NavigationStack {
                detailView(for: state.activeSection)
            }
        }
    }

    /// List(selection:) 要 Optional Binding；置 nil（点空白处取消选中）时保持当前页不变。
    private var sidebarSelectionBinding: Binding<AppSection?> {
        Binding(
            get: { state.activeSection },
            set: { if let section = $0 { state.activeSection = section } }
        )
    }

    @ViewBuilder private func detailView(for section: AppSection) -> some View {
        switch section {
        case .home:          HomeView(state: state)
        case .nodes:         NodesView(state: state)
        case .subscriptions: SubscriptionsView(state: state)
        case .rules:         RulesView(state: state)
        case .connections:   ConnectionsView(state: state)
        case .logs:          LogsView(state: state)
        case .settings:      SettingsView(state: state)
        }
    }
    #endif
}

extension AppSection {
    /// macOS 侧栏显示名。
    var sidebarTitle: String {
        switch self {
        case .home:          return "首页"
        case .nodes:         return "节点"
        case .subscriptions: return "订阅"
        case .rules:         return "规则"
        case .connections:   return "连接"
        case .logs:          return "日志"
        case .settings:      return "设置"
        }
    }
}
