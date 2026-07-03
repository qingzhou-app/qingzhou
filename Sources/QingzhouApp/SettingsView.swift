import SwiftUI
import QingzhouCore
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

public struct SettingsView: View {
    @Bindable var state: AppState
    @State private var filterEnabled = false

    public init(state: AppState) { self.state = state }

    public var body: some View {
        Form {
            proxySection
            autoSelectSection
            regionSection
            appearanceSection
            ruleSourceSection
            geoDataSection
            #if os(macOS)
            macIntegrationSection
            #endif
            iCloudSection
            diagnosticsSection
            aboutSection
        }
        .navigationTitle("设置")
        .formStyle(.grouped)
        // 「立即恢复」的版本选择 sheet。两条呈现纪律（复验 #18 两轮打回换来的）：
        // 1. 挂在 Form 顶层，**不要挂进 Section** —— iOS 的 Form 是惰性容器（UICollectionView），
        //    cell 重渲染会重建 hosting view，呈现动画中的 sheet 会被连带 dismiss（弹出即沉）。
        // 2. isPresented 只依赖专用稳定 Bool —— 加载态 .loading→.loaded 落在呈现动画中，
        //    binding 若依赖它，mid-transition 重渲染同样会打断呈现。
        // onDismiss：sheet 完全收起后才把点选的候选交给确认 alert（挂在 RootView）——
        // 收起动画中就置 cloudRestoreOffer 会撞呈现层，alert 被吞掉。
        .sheet(isPresented: cloudVersionSheetBinding, onDismiss: {
            state.presentPendingCloudRestoreOffer()
        }) {
            cloudVersionPicker
        }
    }

    /// 诊断：隧道扩展进程的内存水位。iOS 对 NE 扩展有 50MB jetsam 硬上限，超限即"断流"——
    /// 高速测速 / 大流量下载是竞品翻车的典型场景，这里给用户/开发者一个随时可查的数字。
    ///
    /// 用 TimelineView **每秒自驱动重算**，不依赖任何数据变更就能走字 —— 于是
    /// 「上次采样：N 秒前」这行读数把故障环节一劈两半：秒数持续增大 = 扩展没在写
    /// （旧扩展进程没换新代码 / 写入失败）；秒数一直 ≤2 秒但数字不动 = 不可能
    /// （数字和采样时间在同一个文件里）。「扩展尚未上报」= 文件根本不存在。
    private var diagnosticsSection: some View {
        Section("诊断") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let mem = state.tunnelMemory {
                    let age = context.date.timeIntervalSince(mem.sampledAt)
                    let live = age <= 3
                    // footprint==0 && error != nil = 扩展在写但采样失败 —— 显示失败而不是"0 B"
                    let samplingFailed = mem.footprintBytes <= 0 && mem.error != nil
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("扩展内存", value: live
                            ? (samplingFailed
                               ? "采样失败"
                               : "\(ByteFormatter.format(mem.footprintBytes))"
                                 + " · 峰值 \(ByteFormatter.format(mem.sessionPeakBytes))")
                            : "未在上报")
                        Text(live && !samplingFailed
                            ? memoryCaption(mem)
                            : "上次会话峰值 \(ByteFormatter.format(mem.sessionPeakBytes))"
                              + " · 历史最高 \(ByteFormatter.format(mem.allTimePeakBytes))"
                              + (mem.limitBytes > 0 ? "（上限 \(ByteFormatter.format(mem.limitBytes))）" : ""))
                            .font(.caption2)
                            .foregroundStyle(live && mem.warningCount > 0 ? .orange : .secondary)
                        // 采样诊断（扩展带出的失败/降级原因）—— 用户截图这一行就能远程定位
                        if let err = mem.error {
                            Text("采样诊断：\(err)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.orange)
                        }
                        Text("上次采样：\(Self.ageText(age))")
                            .font(.caption2)
                            .foregroundStyle(live ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("扩展内存", value: "暂无数据")
                        Text("扩展尚未上报 —— 需 VPN 处于开启状态，且隧道扩展为最新版本"
                             + "（更新 App 后要关-开一次 VPN，运行中的旧扩展进程才会换成新代码）。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            #if os(iOS)
            // iOS tab 收敛到 5 个后「日志」不再占 tab，从这里 push 进去（macOS 侧栏有独立项）
            NavigationLink {
                LogsView(state: state)
            } label: {
                Label("日志", systemImage: "doc.text.magnifyingglass")
            }
            #endif
        }
    }

    /// 「上次采样」的人话时间差。负值（时钟偏差）并进"刚刚"。
    static func ageText(_ age: TimeInterval) -> String {
        if age < 2 { return "刚刚" }
        if age < 60 { return "\(Int(age)) 秒前" }
        if age < 3600 { return "\(Int(age / 60)) 分钟前" }
        return "\(Int(age / 3600)) 小时前"
    }

    private func memoryCaption(_ mem: TunnelMemoryStats) -> String {
        var parts: [String] = []
        if mem.limitBytes > 0 {
            let headroom = max(0, mem.limitBytes - mem.footprintBytes)
            parts.append("距 \(ByteFormatter.format(mem.limitBytes)) 上限余 \(ByteFormatter.format(headroom))")
        } else {
            // macOS：NE 扩展没有 iOS 那条 50MB jetsam 硬上限，如实说，别让人找"余量"
            parts.append("无硬性内存上限")
        }
        parts.append("历史最高 \(ByteFormatter.format(mem.allTimePeakBytes))")
        if mem.warningCount > 0 {
            parts.append("本次会话越过 40 MB 告警线 \(mem.warningCount) 次")
        }
        return parts.joined(separator: " · ")
    }

    private var proxySection: some View {
        Section("代理") {
            Picker("代理模式", selection: state.proxyModeBinding) {
                ForEach(ProxyMode.allCases, id: \.self) { m in
                    Text(label(for: m)).tag(m)
                }
            }
            Text("全程走虚拟网卡（TUN），整机流量自动经隧道转发，无需配置系统代理。")
                .font(.caption2).foregroundStyle(.secondary)
            Picker("日志级别", selection: state.setting(\.logLevel)) {
                Text("DEBUG").tag("DEBUG")
                Text("INFO").tag("INFO")
                Text("WARN").tag("WARN")
                Text("ERROR").tag("ERROR")
            }
        }
    }

    private var autoSelectSection: some View {
        Section("自动化") {
            // 自动测速：周期性刷延迟列，不改 currentNodeId
            Picker("自动测速", selection: state.setting(\.autoMeasureIntervalSeconds)) {
                Text("关闭").tag(TimeInterval(0))
                Text("15 分钟").tag(TimeInterval(15 * 60))
                Text("30 分钟").tag(TimeInterval(30 * 60))
                Text("1 小时").tag(TimeInterval(60 * 60))
                Text("6 小时").tag(TimeInterval(6 * 60 * 60))
            }
            Text("只刷新延迟数据，不会自动切换当前节点。")
                .font(.caption2).foregroundStyle(.secondary)

            // 自动择优：测速 + 自动切节点
            Picker("自动择优时机", selection: state.setting(\.autoSelectTrigger)) {
                Text("启动时").tag(AutoSelectTrigger.onAppLaunch)
                Text("定时").tag(AutoSelectTrigger.interval)
                Text("启动 + 定时").tag(AutoSelectTrigger.onAppLaunchAndInterval)
                Text("关闭").tag(AutoSelectTrigger.off)
            }
            // 固定档位 Picker，样式与上面「自动测速」一致（label 左、值右）。
            // 旧版是 Stepper（任意分钟值），binding 的 get 里做就近回退，
            // 保证 Picker 永远有合法选中项；用户不动它就不改写已存的旧值。
            Picker("择优间隔", selection: autoSelectIntervalBinding) {
                Text("5 分钟").tag(TimeInterval(5 * 60))
                Text("15 分钟").tag(TimeInterval(15 * 60))
                Text("30 分钟").tag(TimeInterval(30 * 60))
                Text("1 小时").tag(TimeInterval(60 * 60))
                Text("6 小时").tag(TimeInterval(6 * 60 * 60))
                Text("24 小时").tag(TimeInterval(24 * 60 * 60))
            }
            Text("开启后会主动把「当前节点」切到测速最快的那个 —— 如果你手选了节点不想被换，关掉这一项。")
                .font(.caption2).foregroundStyle(.secondary)

            Toggle("择优用经代理延迟精选", isOn: state.setting(\.autoSelectUsesProxiedLatency))
            Text("VPN 运行中择优时，把直连最快的前 5 个节点真实走一遍代理再选（更准，多花几秒）："
                 + "能避开「直连快但出口绕路或已失效」的假好节点。VPN 未开启时自动退回直连结果。")
                .font(.caption2).foregroundStyle(.secondary)

            NavigationLink {
                AutomationGuideView()
            } label: {
                Label("自动化玩法指南", systemImage: "sparkles")
            }
            Text("快捷指令 / Siri / 打开某 App 自动连 / 小组件 —— 全部配方一页看懂。")
                .font(.caption2).foregroundStyle(.secondary)

            Picker("订阅自动刷新", selection: state.setting(\.subscriptionRefreshIntervalSeconds)) {
                Text("关闭").tag(TimeInterval(0))
                Text("15 分钟").tag(TimeInterval(15 * 60))
                Text("30 分钟").tag(TimeInterval(30 * 60))
                Text("1 小时").tag(TimeInterval(60 * 60))
                Text("6 小时").tag(TimeInterval(6 * 60 * 60))
                Text("24 小时").tag(TimeInterval(24 * 60 * 60))
            }

            // 定时关闭（防忘关）：档位样式与「择优间隔」一致。倒计时在隧道扩展进程里生效，
            // 主 App 被系统回收也照样到点断开。DEBUG 构建带 1 分钟调试档。
            Picker("定时关闭", selection: autoStopBinding) {
                ForEach(AutoStopPresets.values, id: \.self) { v in
                    Text(AutoStopPresets.label(for: v)).tag(v)
                }
            }
            Text("到点自动断开 VPN，只对本次连接生效 —— 断开后不会自动重连，手动重开会重新计时。"
                 + "VPN 运行中修改会立即从现在起重新计时。注意：启用定时的连接不开启系统自动重连"
                 + "（On-Demand），若扩展异常退出需手动重开。")
                .font(.caption2).foregroundStyle(.secondary)

            Text("当前节点：\(state.currentNode?.name ?? "未选")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var regionSection: some View {
        Section {
            let regions = state.regionCounts
            if regions.isEmpty {
                Text("还没有节点，添加订阅后这里会列出各地区。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // 优先地区
                Picker("优先地区", selection: state.setting(\.preferredRegion)) {
                    Text("无（只比延迟）").tag(String?.none)
                    ForEach(regions, id: \.region) { item in
                        Text(item.region).tag(String?.some(item.region))
                    }
                }
                Text("自动择优时，若优先地区有可用节点，从中选最快的；否则全局选最快。")
                    .font(.caption2).foregroundStyle(.secondary)

                // 地区排除列表
                ForEach(regions, id: \.region) { item in
                    Toggle(isOn: regionExcludedBinding(item.region)) {
                        HStack {
                            Text(item.region)
                            Text("\(item.count) 个节点")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("打开开关 = 排除该地区的所有节点（不参与自动择优、不会被自动选中）。"
                     + "例如排除「香港」以避开 Anthropic / OpenAI 等对香港 IP 的限制。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text("地区")
        }
    }

    /// 「择优间隔」的 Binding：读取时把旧版 Stepper 存下的任意值就近吸附到固定档位
    /// （见 `AutoSelectIntervalPresets.nearest`），写入时按用户所选档位持久化。
    private var autoSelectIntervalBinding: Binding<TimeInterval> {
        let raw = state.setting(\.autoSelectIntervalSeconds)
        return Binding(
            get: { AutoSelectIntervalPresets.nearest(to: raw.wrappedValue) },
            set: { raw.wrappedValue = $0 }
        )
    }

    /// 「定时关闭」的 Binding：读取时把任意存量值（iCloud 同步来的等）就近吸附到档位；
    /// 写入走 AppState.setAutoStopSeconds —— VPN 运行中改档会热生效（重新计时），不只是存值。
    private var autoStopBinding: Binding<TimeInterval> {
        Binding(
            get: { AutoStopPresets.nearest(to: state.settings.autoStopSeconds) },
            set: { state.setAutoStopSeconds($0) }
        )
    }

    /// 某地区是否被排除的 Binding（toggle）。
    private func regionExcludedBinding(_ region: String) -> Binding<Bool> {
        Binding(
            get: { state.settings.excludedRegions.contains(region) },
            set: { _ in state.toggleRegionExclusion(region) }
        )
    }

    private var appearanceSection: some View {
        Section("外观") {
            Picker("主题", selection: state.setting(\.theme)) {
                Text("跟随系统").tag(AppearanceTheme.system)
                Text("浅色").tag(AppearanceTheme.light)
                Text("深色").tag(AppearanceTheme.dark)
            }
            Picker("语言", selection: state.setting(\.language)) {
                Text("跟随系统").tag(AppLanguage.system)
                Text("简体中文").tag(AppLanguage.zhHans)
                Text("繁體中文").tag(AppLanguage.zhHant)
                Text("English").tag(AppLanguage.en)
                Text("日本語").tag(AppLanguage.ja)
            }
        }
    }

    private var ruleSourceSection: some View {
        Section("规则源") {
            TextField(
                "Rule source URL",
                text: state.setting(\.ruleSourceURL).mapURL()
            )
            .font(.caption.monospaced())
            Button {
                Task { await state.refreshRemoteRules() }
            } label: {
                Label("立即刷新", systemImage: "arrow.clockwise")
            }
        }
    }

    /// Geo 数据：内置精简版（geoip 仅 cn/private）↔ 完整版（全部国家码，~20MB）。
    /// 下载走主备源（轻舟源 → v2fly 官方），sha256 校验通过才落盘；成功后自动热切换生效。
    private var geoDataSection: some View {
        Section {
            LabeledContent("当前版本") {
                if state.geoData.hasFullGeoIP, let info = state.geoData.info {
                    Text("完整版 · \(info.downloadedAt.formatted(date: .abbreviated, time: .shortened)) · 来源：\(info.sourceName)")
                        .font(.caption)
                } else {
                    Text("精简版（内置，GEOIP 仅 cn / private）")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            switch state.geoData.phase {
            case .downloading(let sourceName, let progress):
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                    Text("正在从\(sourceName)下载…")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize()
                }
            case .verifying:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("sha256 校验中…").font(.caption).foregroundStyle(.secondary)
                }
            default:
                Button {
                    Task { await state.downloadFullGeoData() }
                } label: {
                    Label(state.geoData.hasFullGeoIP ? "重新下载完整版" : "下载完整版（约 20 MB）",
                          systemImage: "arrow.down.circle")
                }
                Button {
                    Task { await state.geoData.checkForUpdate() }
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                if let message = state.geoData.lastCheckMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if case .failed(let message) = state.geoData.phase {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Geo 数据")
        } footer: {
            Text("完整版解锁所有国家/地区码的 GEOIP 规则（如 GEOIP,us）。数据来自 v2fly 上游，主源为轻舟自建发布仓库、每周自动同步，主源不可用时自动切换 v2fly 官方源。")
                .font(.caption2)
        }
    }

    #if os(macOS)
    private var macIntegrationSection: some View {
        Section("macOS 集成") {
            Toggle("开机自启", isOn: state.setting(\.launchAtLogin))
            Button("立即应用") {
                state.applyMacSystemPreferences()
            }
            autoConnectRows
            // 「来源 App 标注」入口暂时隐藏（功能搁置，见 FeatureFlags.sourceAppLabeling）。
            if FeatureFlags.sourceAppLabeling {
                Button(filterEnabled ? "关闭来源 App 标注" : "启用来源 App 标注") {
                    ContentFilterManager.shared.onNeedsApproval = {
                        state.showToast("请到「系统设置 → 通用 → 登录项与扩展 → 网络扩展」批准轻舟")
                    }
                    Task {
                        do {
                            if filterEnabled {
                                try await ContentFilterManager.shared.disable()
                            } else {
                                try await ContentFilterManager.shared.activateAndEnable()
                            }
                            filterEnabled = ContentFilterManager.isEnabled
                            state.showToast(filterEnabled ? "已启用来源 App 标注" : "已关闭来源 App 标注")
                        } catch {
                            let ns = error as NSError
                            state.showToast("失败 [\(ns.domain) #\(ns.code)] \(ns.localizedDescription)")
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
            Text("任一所选 App 启动 → 自动连接；全部退出 → 自动断开（只断开由自动连接拉起的会话，"
                 + "手动开启的 VPN 不受影响）。iPhone/iPad 上可用「快捷指令 → 自动化 → App」实现同样效果。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// NSOpenPanel 选 .app → 读 bundle id 存入设置。选不出 bundle id 的（损坏包）静默跳过。
    private func addAutoConnectApps() {
        let panel = NSOpenPanel()
        panel.title = "选择触发自动连接的 App"
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
    #endif

    private var iCloudSection: some View {
        Section("iCloud 同步") {
            Toggle("同步到 iCloud Drive", isOn: cloudSyncBinding)
            LabeledContent("状态", value: state.cloudSyncStatus.displayText)
                .font(.caption)
            Button {
                Task { await state.requestManualCloudRestore() }
            } label: {
                Label("立即恢复 iCloud 数据", systemImage: "icloud.and.arrow.down")
            }
            .disabled(!state.settings.iCloudSyncEnabled)
            Text("配置（订阅、节点、规则、设置）会镜像到你 iCloud Drive 的「轻舟」文件夹，"
                 + "卸载 App 不会丢失，重装或换设备时可一键恢复。云端保留最近 "
                 + "\(CloudVaultStore.maxBackups) 份历史版本。不含连接记录与流量统计。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// iCloud 同步开关走专用方法 —— 开启时要立刻跑一次云端比对（可能提示恢复）。
    private var cloudSyncBinding: Binding<Bool> {
        Binding(
            get: { state.settings.iCloudSyncEnabled },
            set: { state.setCloudSyncEnabled($0) }
        )
    }

    /// 只读专用稳定 Bool（呈现开关），不读会中途变化的加载态 —— 见 body 上 sheet 的注释。
    private var cloudVersionSheetBinding: Binding<Bool> {
        Binding(
            get: { state.isCloudVersionSheetPresented },
            set: { if !$0 { state.dismissCloudVersionOptions() } }
        )
    }

    /// 版本选择 sheet 三态：点击瞬间以 .loading 呈现（iCloud 读取秒级，sheet 不能干等），
    /// 读完切列表；失败留在 sheet 内展示 + 重试。
    private var cloudVersionPicker: some View {
        NavigationStack {
            Group {
                switch state.cloudVersionLoad {
                case nil, .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在读取 iCloud 版本…")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.icloud")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text(message)
                            .font(.subheadline).multilineTextAlignment(.center)
                        Button("重试") {
                            Task { await state.loadCloudVersionOptions() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let options):
                    List(options) { option in
                        Button {
                            state.chooseCloudRestoreCandidate(option)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(option.backupFileName == nil ? "云端当前版本" : "历史版本")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("r\(option.header.revision)")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                // 内容计数醒目展示 —— 空数据（0 订阅）一眼可见
                                Text(option.header.contentSummary)
                                    .font(.subheadline)
                                    .foregroundStyle(
                                        (option.header.nodeCount ?? 1) == 0 ? AnyShapeStyle(.orange)
                                                                            : AnyShapeStyle(.primary))
                                Text("\(option.header.deviceName) · "
                                     + option.header.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("选择要恢复的版本")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { state.dismissCloudVersionOptions() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("App 版本", value: appVersion)
            LabeledContent("数据目录", value: dataDir).font(.caption.monospaced())
            Link("GitHub 仓库", destination: URL(string: "https://github.com/qingzhou-app/qingzhou")!)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var dataDir: String {
        Persistence.defaultDirectory().path
    }

    private func label(for mode: ProxyMode) -> String {
        switch mode {
        case .global: return "全局代理"
        case .rule:   return "规则代理"
        case .direct: return "直连"
        }
    }
}
