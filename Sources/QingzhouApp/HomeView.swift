import SwiftUI
import QingzhouCore
import QingzhouSpeedTest

public struct HomeView: View {
    @Bindable var state: AppState
    /// 跟随 App 语言设置的 locale（根视图注入），日期/相对时间格式化用
    @Environment(\.locale) private var locale
    @State private var isRefreshingIP = false
    @State private var isTestingSpeed = false
    @State private var singleTesting: Set<SpeedTestTarget> = []
    #if os(iOS)
    /// iOS 上「连接」不再占 tab（tab 收敛到 5 个），从流量卡的入口 push 进来。
    @State private var showConnections = false
    #endif

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                vpnSwitchCard
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280), spacing: 14)],
                    spacing: 14
                ) {
                    currentNodeCard
                    subscriptionCard
                    networkCard
                    trafficCard
                    speedTestCard
                    systemCard
                }
            }
            .padding()
        }
        .navigationTitle("首页")
        // 注意：之前在这里 .task { await firstLoad() } 会和 app entry 的 .task 重复触发
        // refreshRemoteRules / refreshPublicIPInfo，启动时争抢主线程导致 UI 卡顿。
        // 现在统一由 app entry 调度，HomeView 只读 state。
        .alert(
            "VPN 启动失败",
            isPresented: Binding(
                get: { state.tunnelError != nil },
                set: { if !$0 { state.tunnelError = nil } }
            ),
            presenting: state.tunnelError
        ) { _ in
            Button("好") { state.tunnelError = nil }
        } message: { msg in
            Text(msg)
        }
        #if os(iOS)
        .navigationDestination(isPresented: $showConnections) {
            ConnectionsView(state: state)
        }
        #endif
        // 触觉反馈（iOS；macOS 上这些反馈类型是 no-op）：
        // 开成功 .success、失败 .error、手动关一记轻 impact。只挂关键节点，不滥用。
        .sensoryFeedback(trigger: state.isVPNRunning) { wasOn, isOn in
            if isOn && !wasOn { return .success }
            if wasOn && !isOn { return .impact(weight: .light) }
            return nil
        }
        .sensoryFeedback(.error, trigger: state.tunnelError) { _, new in new != nil }
    }

    // MARK: - 卡片

    private var vpnSwitchCard: some View {
        Card {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(circleFill)
                        .frame(width: 56, height: 56)
                    Image(systemName: statusIcon)
                        .font(.title)
                        .foregroundStyle(statusColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(statusText)
                            .font(.title3.bold())
                        // 定时关闭倒计时：小胶囊贴在状态文字旁，风格对齐状态胶囊但刻意低调
                        //（caption2 + secondary），不喧宾夺主。每秒随 TimelineView 重算。
                        if let deadline = state.autoStopDeadline,
                           state.isVPNRunning, !state.isSwitchingTunnel {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Label(
                                    AutoStopPresets.remainingText(until: deadline, now: context.date),
                                    systemImage: "timer"
                                )
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.14), in: Capsule())
                            }
                        }
                    }
                    if let n = state.currentNode {
                        Text("\(n.name) · \(n.protocolType.rawValue.uppercased())")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("未选择节点").font(.caption).foregroundStyle(.secondary)
                    }
                    // 已连接时长 + 本次会话累计流量：安全感信号，独立一行不挤倒计时胶囊。
                    // 时长起点 = 扩展会话标记的 startedAt（xray 真跑起来那刻）；
                    // 会话流量 = appex 按会话累计的 TrafficStats（隧道重启即归零，口径一致）。
                    if state.isVPNRunning, !state.isSwitchingTunnel,
                       let since = state.connectedSince {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(sessionStatusLine(since: since, now: context.date))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Toggle("", isOn: state.vpnRunningBinding)
                    // 自绘样式：原生 Switch 的"关"位轨道是系统灰、tint 改不了，
                    // 切换中要让滑轨跟着变橙只能自绘。三态颜色与左侧状态胶囊同源。
                    .toggleStyle(TunnelToggleStyle(isSwitching: state.isSwitchingTunnel))
                    .labelsHidden()
                    // 热切换窗口内禁点：重启中途再启停会和 stop→start 时序打架
                    .disabled(state.isSwitchingTunnel)
            }
            // 开关滑动 / 图标变色跟着状态平滑过渡，而不是跳变
            .animation(.spring(duration: 0.35), value: state.isVPNRunning)
            .animation(.spring(duration: 0.35), value: state.isSwitchingTunnel)

            Divider().padding(.vertical, 6)

            HStack {
                Text("代理模式").font(.caption).foregroundStyle(.secondary)
                Spacer()
                #if os(macOS)
                // 原生 .segmented Picker 在 macOS 是 AppKit 桥接（NSSegmentedControl），
                // 窗口失焦时选中段的强调色底会变灰，.controlActiveState 环境覆盖对
                // AppKit 桥接控件不生效 —— 蓝底文字变灰会让人误以为 VPN/模式没生效。
                // 自绘 + 显式颜色（controlAccentColor 不随 key window 变化），失焦仍保持高亮。
                ProxyModeSegmentedControl(selection: state.proxyModeBinding, title: label(for:))
                    .frame(maxWidth: 280)
                #else
                Picker("", selection: state.proxyModeBinding) {
                    ForEach(ProxyMode.allCases, id: \.self) { m in
                        Text(label(for: m)).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                #endif
            }
        }
    }

    /// VPN 主开关的自绘滑轨样式：胶囊轨道 + 白色圆钮，观感对齐系统 Switch。
    /// 轨道三态：切换中橙、开位绿、关位灰 —— 和状态胶囊一个颜色语言。
    /// 圆钮位置只跟 isOn 走（切换中在关位），用 offset 驱动以便随外层 spring 动画滑动。
    private struct TunnelToggleStyle: ToggleStyle {
        var isSwitching: Bool

        // 尺寸对齐各平台原生 Switch：macOS 的 NSSwitch 明显小于 iOS 的 UISwitch。
        #if os(macOS)
        private static let trackWidth: CGFloat = 38
        private static let trackHeight: CGFloat = 22
        #else
        private static let trackWidth: CGFloat = 51
        private static let trackHeight: CGFloat = 31
        #endif

        func makeBody(configuration: Configuration) -> some View {
            let track: Color = isSwitching ? Color.orange.opacity(0.6)
                : (configuration.isOn ? .green : Color.secondary.opacity(0.3))
            // 不用 Button 承载：macOS 上 Button 自带 bezel / 焦点环，会在开关四周画出一圈框。
            // 直接对形状挂 tap 手势，视觉上只剩轨道和圆钮。
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                    .frame(width: Self.trackWidth, height: Self.trackHeight)
                Circle()
                    .fill(.white)
                    .frame(width: Self.trackHeight - 4, height: Self.trackHeight - 4)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                    .padding(2)
                    .offset(x: configuration.isOn ? Self.trackWidth - Self.trackHeight : 0)
            }
            .contentShape(Capsule())
            .onTapGesture { configuration.isOn.toggle() }
        }
    }

    #if os(macOS)
    /// 代理模式的自绘分段选择器（仅 macOS，iOS 继续用原生 segmented Picker）。
    /// 动机：NSSegmentedControl 在窗口失焦时把选中段的强调色底画成灰色，看起来像设置失效。
    /// 选中段用 `NSColor.controlAccentColor` —— 跟随用户系统强调色、深浅色模式下由系统
    /// 自动适配，且是静态语义色，不随 key window 状态去饱和。
    /// 和 TunnelToggleStyle 一样不用 Button 承载（macOS 的 Button 有 bezel / 焦点环）。
    private struct ProxyModeSegmentedControl: View {
        @Binding var selection: ProxyMode
        let title: (ProxyMode) -> String

        var body: some View {
            HStack(spacing: 2) {
                ForEach(ProxyMode.allCases, id: \.self) { mode in
                    let isSelected = selection == mode
                    Text(title(mode))
                        .font(.callout.weight(isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background {
                            if isSelected {
                                Capsule().fill(Color(nsColor: .controlAccentColor))
                            }
                        }
                        .contentShape(Capsule())
                        .onTapGesture { selection = mode }
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .animation(.easeOut(duration: 0.15), value: selection)
        }
    }
    #endif

    /// 「已连接 1:23:45 · ↑ 1.2 MB ↓ 34 MB」。流量读 appex 上报的会话累计值；
    /// 隧道刚起来还没上报时只显示时长。
    private func sessionStatusLine(since: Date, now: Date) -> String {
        var line = L("已连接 \(Self.durationText(max(0, now.timeIntervalSince(since))))")
        if let latest = state.trafficHistory.latest {
            line += L(" · ↑ \(ByteFormatter.format(latest.uploadBytes)) ↓ \(ByteFormatter.format(latest.downloadBytes))")
        }
        return line
    }

    /// 秒数 → "1:23:45"（小时不补零，分秒补零）。
    static func durationText(_ interval: TimeInterval) -> String {
        let s = Int(interval)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    // 状态胶囊三态：切换中（橙）> 已连接（绿）> 未连接（灰）
    private var statusText: String {
        state.isSwitchingTunnel ? L("切换中…") : (state.isVPNRunning ? L("VPN 已连接") : L("VPN 未连接"))
    }
    private var statusIcon: String {
        state.isSwitchingTunnel ? "arrow.triangle.2.circlepath"
            : (state.isVPNRunning ? "bolt.fill" : "bolt.slash.fill")
    }
    private var statusColor: Color {
        state.isSwitchingTunnel ? .orange : (state.isVPNRunning ? .green : .secondary)
    }
    private var circleFill: Color {
        state.isSwitchingTunnel ? Color.orange.opacity(0.18)
            : (state.isVPNRunning ? Color.green.opacity(0.18) : Color.secondary.opacity(0.14))
    }

    private var currentNodeCard: some View {
        Card(title: "当前节点", systemImage: "server.rack") {
            if let node = state.currentNode {
                VStack(alignment: .leading, spacing: 6) {
                    Text(node.name).font(.headline)
                    Text("\(node.protocolType.rawValue.uppercased()) · \(node.host):\(node.port)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    HStack {
                        latencyChip(node.lastLatencyMs)
                        if let t = node.lastTestedAt {
                            Text("测于 \(t.formatted(.relative(presentation: .named).locale(locale)))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                emptyCard(icon: "questionmark.circle", text: "未选择节点", cta: "去节点页选择") {
                    state.activeSection = .nodes
                }
            }
        }
    }

    private var subscriptionCard: some View {
        Card(title: "订阅", systemImage: "tray.full") {
            if state.subscriptions.isEmpty {
                emptyCard(icon: "tray", text: "暂无订阅", cta: "去订阅页添加") {
                    state.activeSection = .subscriptions
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.subscriptions.prefix(2)) { sub in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.name).font(.subheadline.bold())
                            HStack {
                                Text("节点 \(sub.nodeCount)").font(.caption2).foregroundStyle(.secondary)
                                if let upd = sub.lastUpdatedAt {
                                    Text("· 更新于 \(upd.formatted(.relative(presentation: .named).locale(locale)))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            if let used = sub.usedBytes, let total = sub.totalBytes {
                                ProgressView(value: Double(used), total: Double(max(total, 1)))
                                Text("\(ByteFormatter.format(used)) / \(ByteFormatter.format(total))")
                                    .font(.caption2.monospaced())
                            }
                            if let exp = sub.expiresAt {
                                Text("到期：\(exp.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if state.subscriptions.count > 2 {
                        Text("还有 \(state.subscriptions.count - 2) 条订阅…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var networkCard: some View {
        Card(title: "公网 IP", systemImage: "globe") {
            // 按连接状态切换：未连接时不显示「节点出口」——那栏留着只会摆上一次会话的
            // 缓存或直连 IP，误导用户以为还在走节点。连上了才有「节点出口」的语义。
            if state.isVPNRunning {
                ipRow(title: "节点出口", info: state.proxyIPInfo, tint: .blue)
                Divider().padding(.vertical, 4)
                ipRow(title: "直连（不走节点）", info: state.directIPInfo, tint: .green)
            } else {
                ipRow(title: "直连 IP（VPN 未连接）", info: state.directIPInfo, tint: .green)
            }
            HStack {
                Spacer()
                Button {
                    Task {
                        isRefreshingIP = true
                        await state.refreshPublicIPInfo()
                        isRefreshingIP = false
                    }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshingIP)
            }
        }
    }

    private func ipRow(title: LocalizedStringKey, info: PublicIPInfo?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            if let info {
                Text(info.ip).font(.callout.monospaced())
                let loc = [info.city, info.region, info.country].compactMap { $0 }.joined(separator: " · ")
                if !loc.isEmpty {
                    Text(loc).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("更新于 \(info.fetchedAt.formatted(.relative(presentation: .named).locale(locale)))")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text(isRefreshingIP ? "查询中…" : "尚未获取")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trafficCard: some View {
        Card(title: "流量统计", systemImage: "chart.bar") {
            // 文字和波形同源：都读 appex 上报的真实 TrafficStats，不再用示例 connections。
            // （活跃连接数 appex 在 TUN 层看不到，要等 access log 接入，先不显示。）
            let latest = state.trafficHistory.latest
            VStack(alignment: .leading, spacing: 8) {
                TrafficWaveform(history: state.trafficHistory)
                    .frame(height: 56)
                    .padding(.bottom, 2)
                statRow("总上行", value: ByteFormatter.format(latest?.uploadBytes ?? 0))
                statRow("总下行", value: ByteFormatter.format(latest?.downloadBytes ?? 0))
                statRow("当前速率", value: "↑ \(ByteFormatter.format(latest?.uploadSpeedBps ?? 0))/s · ↓ \(ByteFormatter.format(latest?.downloadSpeedBps ?? 0))/s")
                // 代理/直连拆分：xray 内置 per-outbound 统计（QueryStats）。应用层 payload
                // 口径，与上面 TUN 层总量不必对得上；只在扩展有新鲜上报时显示（规则模式
                // 下最有价值 —— 一眼看出多少流量真走了代理）。
                if let xs = state.outboundStats {
                    statRow("代理 / 直连",
                            value: "\(ByteFormatter.format(xs.proxy.totalBytes)) / \(ByteFormatter.format(xs.direct.totalBytes))"
                                + (xs.proxyShare.map { String(format: L("（代理 %.0f%%）"), $0 * 100) } ?? ""))
                }
                #if os(iOS)
                // 连接页在 iOS 上不占 tab，从这里 push（macOS 侧栏有独立「连接」项，不重复放）
                HStack {
                    Spacer()
                    Button {
                        showConnections = true
                    } label: {
                        Label("查看连接明细", systemImage: "list.bullet.rectangle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                #endif
            }
        }
    }

    private var speedTestCard: some View {
        Card(title: "网站测试", systemImage: "speedometer") {
            // 把上次的结果按 URL → result 索引一下，方便和全部 target 列表合并
            let byURL: [URL: LatencyResult] = Dictionary(
                uniqueKeysWithValues: (state.lastSpeedTestReport?.results ?? []).map { ($0.url, $0) }
            )
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SpeedTestTarget.allCases, id: \.self) { target in
                    HStack {
                        Text(L10n.lookup(target.displayName)).font(.caption)
                        Spacer()
                        if singleTesting.contains(target) {
                            ProgressView().controlSize(.small)
                        } else if let r = byURL[target.url], let ms = r.latencyMs {
                            Text("\(ms) ms").font(.caption.monospaced())
                                .foregroundStyle(color(for: ms))
                        } else if let r = byURL[target.url], r.latencyMs == nil {
                            Text("失败").font(.caption.monospaced()).foregroundStyle(.red)
                        } else {
                            Text("—").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Button {
                            Task { await runSingle(target) }
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(singleTesting.contains(target) || isTestingSpeed)
                        .help("测试 \(L10n.lookup(target.displayName))")
                    }
                }
            }
            HStack {
                Spacer()
                Button {
                    Task { await runAll() }
                } label: {
                    if isTestingSpeed {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("一键全部测试", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isTestingSpeed)
            }
        }
    }

    private func runAll() async {
        isTestingSpeed = true
        state.lastSpeedTestReport = await state.speedTestRunner.runBuiltInTargets()
        isTestingSpeed = false
    }

    /// 测单个 target，结果合并到 `state.lastSpeedTestReport` 里。
    private func runSingle(_ target: SpeedTestTarget) async {
        singleTesting.insert(target)
        defer { singleTesting.remove(target) }
        let report = await state.speedTestRunner.run(urls: [target.url])
        guard let result = report.results.first else { return }
        // 合并到 lastSpeedTestReport
        var existing = state.lastSpeedTestReport?.results ?? []
        existing.removeAll(where: { $0.url == result.url })
        existing.append(result)
        state.lastSpeedTestReport = SpeedTestReport(
            startedAt: state.lastSpeedTestReport?.startedAt ?? Date(),
            finishedAt: Date(),
            results: existing
        )
    }

    private var systemCard: some View {
        Card(title: "系统信息", systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 6) {
                statRow("App 版本", value: appVersion)
                if let xv = state.coreVersion, !xv.isEmpty {
                    statRow("xray-core", value: xv)
                }
                #if os(macOS)
                statRow("平台", value: "macOS")
                #else
                statRow("平台", value: "iOS")
                #endif
                statRow("模式", value: L("TUN（虚拟网卡）"))
                statRow("日志级别", value: state.settings.logLevel)
                statRow("规则数", value: "\(state.customRules.count + state.remoteRules.count)")
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    // MARK: - helpers

    private func latencyChip(_ ms: Int?) -> some View {
        Group {
            if let ms {
                Text("\(ms) ms")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(color(for: ms).opacity(0.18))
                    .foregroundStyle(color(for: ms))
                    .clipShape(Capsule())
            } else {
                Text("未测速")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.18))
                    .clipShape(Capsule())
            }
        }
    }

    private func color(for ms: Int) -> Color {
        if ms < 200 { return .green }
        if ms < 500 { return .orange }
        return .red
    }

    private func statRow(_ title: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospaced())
        }
    }

    /// 空态卡：说明文字 + 可点的 CTA 按钮（跳到对应页面）。
    /// 早期 CTA 是灰色纯文字，新用户第一屏看到「去节点页选择」却无处可点 —— 死路。
    private func emptyCard(icon: String, text: LocalizedStringKey, cta: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(text).foregroundStyle(.secondary)
            }
            Button(action: action) {
                Label(cta, systemImage: "arrow.right.circle.fill")
                    .font(.caption)
            }
            // borderless：macOS 上带 bezel 的按钮在卡片里显得笨重，tint 色文字即可
            .buttonStyle(.borderless)
        }
    }

    private func label(for mode: ProxyMode) -> String {
        switch mode {
        case .global: return L("全局")
        case .rule:   return L("规则")
        case .direct: return L("直连")
        }
    }
}

/// 通用卡片容器：圆角、淡背景、可选 title + icon。
struct Card<Content: View>: View {
    var title: LocalizedStringKey?
    var systemImage: String?
    @ViewBuilder var content: () -> Content

    init(title: LocalizedStringKey? = nil, systemImage: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage).foregroundStyle(.tint)
                    }
                    Text(title).font(.headline)
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// 实时流量波形：下行（蓝）/上行（绿）两条速率曲线，最新样本贴右端滚入。
/// 纵轴按窗口峰值归一化。数据来自 `AppState.trafficHistory`（真隧道上报或采样驱动）。
struct TrafficWaveform: View {
    let history: TrafficHistory

    var body: some View {
        Canvas { ctx, size in
            let samples = history.samples
            guard samples.count > 1 else { return }
            let peak = CGFloat(max(history.peakSpeed, 1))
            let stepX = size.width / CGFloat(max(history.capacity - 1, 1))
            let n = samples.count

            func line(_ keyPath: (TrafficStats) -> Int64) -> Path {
                var p = Path()
                for (i, s) in samples.enumerated() {
                    let x = size.width - CGFloat(n - 1 - i) * stepX
                    let y = size.height - CGFloat(keyPath(s)) / peak * size.height
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
                return p
            }
            ctx.stroke(line(\.downloadSpeedBps), with: .color(.blue), lineWidth: 1.6)
            ctx.stroke(line(\.uploadSpeedBps), with: .color(.green), lineWidth: 1.6)
        }
        .overlay(alignment: .topLeading) {
            if history.samples.count <= 1 {
                Text("等待流量…").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Label("下行", systemImage: "circle.fill").foregroundStyle(.blue)
                Label("上行", systemImage: "circle.fill").foregroundStyle(.green)
            }
            .font(.system(size: 9)).labelStyle(.titleAndIcon)
        }
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
