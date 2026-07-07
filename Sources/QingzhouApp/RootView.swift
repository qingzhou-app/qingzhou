import SwiftUI
import QingzhouCore

/// 跨平台根视图。iOS 用 TabView，macOS 用 NavigationSplitView。
public struct RootView: View {
    @Bindable public var state: AppState
    /// 「更新」按钮打开 App Store 页面（trackViewUrl）用。
    @Environment(\.openURL) private var openURL

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        rootContent
            .toastOverlay(state: state)
            // App Store 截图 demo（-qz-screenshot 启动参数才激活，正常启动不可达）
            .task { ScreenshotDemoMode.applyIfRequested(to: state) }
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
                // 内容计数放最前 —— 「0 个订阅 · 0 个节点」一眼可见，防止误恢复空数据；
                // 第二行是与本机配置的差异摘要（生成 offer 时算好），读不到云端全文时降级省略。
                // 单条长字面量（不用 + 拼接）以命中本地化 —— Text("a"+"b") 会落到 Text(String) 重载不翻译。
                if let diff = offer.diffSummary {
                    Text("内容：\(offer.header.contentSummary)\n\(diff)\n来自 \(offer.header.deviceName)，\(offer.header.modifiedAt.formatted(date: .abbreviated, time: .shortened))。\n恢复会用它覆盖本机配置；本机当前配置会先自动备份。")
                } else {
                    Text("内容：\(offer.header.contentSummary)\n来自 \(offer.header.deviceName)，\(offer.header.modifiedAt.formatted(date: .abbreviated, time: .shortened))。\n恢复会用它覆盖本机配置；本机当前配置会先自动备份。")
                }
            }
            // App 内更新提醒：启动时静默查到 App Store 有新版本才弹。系统更新照常，这里只提示。
            .alert(
                updateAlertTitle,
                isPresented: updateAlertBinding,
                presenting: state.availableUpdate
            ) { update in
                Button("更新") {
                    if let url = update.trackViewURL { openURL(url) }
                    state.dismissUpdate()
                }
                Button("忽略此版本") { state.ignoreUpdate(update.version) }
                Button("稍后", role: .cancel) { state.dismissUpdate() }
            } message: { update in
                if let notes = update.releaseNotes, !notes.isEmpty {
                    Text(notes)
                } else {
                    Text("有新版本可在 App Store 更新。")
                }
            }
    }

    /// alert 的显隐 Binding：关掉（点按钮 / 系统 dismiss）等价于「暂不恢复」。
    private var cloudRestoreAlertBinding: Binding<Bool> {
        Binding(
            get: { state.cloudRestoreOffer != nil },
            set: { if !$0 { state.declineCloudRestore() } }
        )
    }

    /// 更新 alert 的标题（带版本号）。只在 availableUpdate 非 nil 时呈现，故此处读得到版本。
    private var updateAlertTitle: Text {
        Text("发现新版本 \(state.availableUpdate?.version ?? "")")
    }

    /// 更新 alert 的显隐 Binding：关掉（点按钮 / 系统 dismiss）等价于「稍后」——不记忽略，下次再提示。
    private var updateAlertBinding: Binding<Bool> {
        Binding(
            get: { state.availableUpdate != nil },
            set: { if !$0 { state.dismissUpdate() } }
        )
    }

    @ViewBuilder private var rootContent: some View {
        #if os(iOS)
        iOSRoot
        #else
        macOSRoot
        #endif
    }

    #if os(iOS)
    private var iOSRoot: some View {
        // iPhone 的 tab bar 只放得下 5 个，多了会被塞进 "More" tab（设置/日志曾因此
        // 藏了两层）。收敛到 5：连接页挂在首页流量卡的「查看连接明细」入口（push），
        // 日志挂在设置页的「日志」入口（push）；macOS 侧栏不受限，保持全量列表。
        // 规则和订阅不合并 —— 一个是路由策略、一个是节点来源，语义无关。
        // selection 绑定 state.activeSection —— 首页空态按钮等可编程式切 tab。
        TabView(selection: iOSTabBinding) {
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
            NavigationStack { SettingsView(state: state) }
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(AppSection.settings)
        }
    }

    /// iOS 只有 5 个 tab：activeSection 被设成非 tab 页（连接/日志）时就近落到
    /// 承载它入口的 tab（连接→首页、日志→设置），不让 TabView 拿到无 tag 可匹配的值。
    private var iOSTabBinding: Binding<AppSection> {
        Binding(
            get: {
                switch state.activeSection {
                case .connections: return .home
                case .logs:        return .settings
                default:           return state.activeSection
                }
            },
            set: { state.activeSection = $0 }
        )
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
        case .home:          return L("首页")
        case .nodes:         return L("节点")
        case .subscriptions: return L("订阅")
        case .rules:         return L("规则")
        case .connections:   return L("连接")
        case .logs:          return L("日志")
        case .settings:      return L("设置")
        }
    }
}
