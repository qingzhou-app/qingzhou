import SwiftUI
import QingzhouCore

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
            #if os(macOS)
            macIntegrationSection
            #endif
            iCloudSection
            aboutSection
        }
        .navigationTitle("设置")
        .formStyle(.grouped)
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

            Picker("订阅自动刷新", selection: state.setting(\.subscriptionRefreshIntervalSeconds)) {
                Text("关闭").tag(TimeInterval(0))
                Text("15 分钟").tag(TimeInterval(15 * 60))
                Text("30 分钟").tag(TimeInterval(30 * 60))
                Text("1 小时").tag(TimeInterval(60 * 60))
                Text("6 小时").tag(TimeInterval(6 * 60 * 60))
                Text("24 小时").tag(TimeInterval(24 * 60 * 60))
            }
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

    #if os(macOS)
    private var macIntegrationSection: some View {
        Section("macOS 集成") {
            Toggle("开机自启", isOn: state.setting(\.launchAtLogin))
            Button("立即应用") {
                state.applyMacSystemPreferences()
            }
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
        // 「立即恢复」的版本选择：云端当前版 + 历史版本，各带设备 / 时间 / 内容计数
        .sheet(isPresented: cloudVersionSheetBinding) {
            cloudVersionPicker
        }
    }

    /// iCloud 同步开关走专用方法 —— 开启时要立刻跑一次云端比对（可能提示恢复）。
    private var cloudSyncBinding: Binding<Bool> {
        Binding(
            get: { state.settings.iCloudSyncEnabled },
            set: { state.setCloudSyncEnabled($0) }
        )
    }

    private var cloudVersionSheetBinding: Binding<Bool> {
        Binding(
            get: { state.cloudVersionOptions != nil },
            set: { if !$0 { state.dismissCloudVersionOptions() } }
        )
    }

    private var cloudVersionPicker: some View {
        NavigationStack {
            List(state.cloudVersionOptions ?? []) { option in
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
