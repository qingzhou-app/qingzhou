import SwiftUI
import QingzhouCore
import QingzhouRules

public struct RulesView: View {
    @Bindable var state: AppState
    @State private var searchText: String = ""
    @State private var newType: RuleType = .domainSuffix
    @State private var newValue: String = ""
    @State private var newTarget: RuleTarget = .proxy
    @State private var addError: String?
    @State private var refreshing = false

    public init(state: AppState) { self.state = state }

    public var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                statusSection
                addSection
                customSection
                    .id("qz-rules-custom")   // App Store 截图 demo 的滚动锚点（无副作用）
                remoteSection
            }
            .navigationTitle("规则")
            .searchable(text: $searchText, prompt: "搜索规则")
            // 规则添加成功一记 .success（iOS 触觉；macOS no-op）。用条数增长当触发器 ——
            // 删除（减少）不响，避免误报
            .sensoryFeedback(.success, trigger: state.customRules.count) { old, new in new > old }
            .task {
                if state.remoteRules.isEmpty {
                    await refreshRemote()
                }
            }
            // App Store 截图 demo 钩子（-qz-screenshot 才可达）：添加表单占半屏，
            // -qz-scroll <y> 把「自定义规则」区滚到画面主体 —— 真实下滑即达的状态。
            .task {
                if let y = ScreenshotDemoMode.scrollAnchorY {
                    try? await Task.sleep(for: .milliseconds(700))
                    scrollProxy.scrollTo("qz-rules-custom", anchor: UnitPoint(x: 0.5, y: y))
                }
            }
        }
    }

    private var engine: RuleEngine { state.currentRuleEngine() }

    private var statusSection: some View {
        Section {
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("当前生效规则").font(.subheadline.bold())
                    Text("自定义 \(state.customRules.count) · 远程 \(state.remoteRules.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }
            HStack {
                TextField(
                    "规则源 URL",
                    text: state.setting(\.ruleSourceURL).mapURL()
                )
                .font(.caption.monospaced())
                .textFieldStyle(.roundedBorder)
                Button {
                    Task { await refreshRemote() }
                } label: {
                    if refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(refreshing)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch state.remoteRulesStatus {
        case .idle:
            Text("未拉取").font(.caption2).foregroundStyle(.secondary)
        case .loading:
            ProgressView().controlSize(.small)
        case let .success(at, count):
            Text("\(count) 条 · \(at.formatted(.relative(presentation: .named)))")
                .font(.caption2).foregroundStyle(.green)
        case let .failure(message):
            Text(message).font(.caption2).foregroundStyle(.red).lineLimit(1)
        }
    }

    private var addSection: some View {
        Section("添加自定义规则") {
            // 类型下拉 —— RuleType 是 CaseIterable，直接遍历
            Picker("类型", selection: $newType) {
                ForEach(visibleRuleTypes, id: \.self) { type in
                    Text(Self.displayName(for: type)).tag(type)
                }
            }

            // FINAL 类型不需要 value（它就是"以上全没命中时怎么走"）
            if newType != .final {
                TextField(Self.placeholder(for: newType), text: $newValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    #if os(iOS)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    #endif
            }

            // GEOIP 提示三态：完整版已就位（全部国家码可用）/ 输入了精简版不含的码
            //（需下载完整版 + 一键下载）/ 普通说明。用户一输入就知道，别等真机跑了才发现分流不对。
            if newType == .geoip {
                let v = newValue.trimmingCharacters(in: .whitespaces)
                if state.geoData.hasFullGeoIP {
                    Text("已启用完整版 geo 数据，支持全部国家/地区码。")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if !v.isEmpty && !GeoDataBundle.supportsGeoIP(v) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("「\(v)」需下载完整版 geo 数据后才会生效（内置精简版仅含 cn / private）")
                            .font(.caption2).foregroundStyle(.orange)
                        geoDownloadControl
                    }
                } else {
                    Text("内置 geo 数据为精简版，GEOIP 仅支持 cn 与 private；其他国家码需下载完整版。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            // 命中后动作 —— 三选一，segmented 紧凑
            Picker("匹配后", selection: $newTarget) {
                ForEach(RuleTarget.allCases, id: \.self) { target in
                    Text(Self.displayName(for: target)).tag(target)
                }
            }
            .pickerStyle(.segmented)

            Button {
                addCustomRule()
            } label: {
                Label("添加规则", systemImage: "plus.circle")
            }
            .disabled(newType != .final && newValue.trimmingCharacters(in: .whitespaces).isEmpty)

            if let err = addError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            // 实时预览生成的规则行 —— 让懂语法的用户能确认
            Text("预览：\(previewLine)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var previewLine: String {
        if newType == .final {
            return "\(newType.rawValue),\(newTarget.rawValue)"
        }
        let v = newValue.trimmingCharacters(in: .whitespaces)
        return "\(newType.rawValue),\(v.isEmpty ? "…" : v),\(newTarget.rawValue)"
    }

    /// iOS 上隐藏 PROCESS-NAME —— iOS App 沙箱看不到其他进程名，规则永远命不中。
    private var visibleRuleTypes: [RuleType] {
        #if os(macOS)
        return RuleType.allCases
        #else
        return RuleType.allCases.filter { $0 != .processName }
        #endif
    }

    private func addCustomRule() {
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        if newType != .final, trimmed.isEmpty {
            addError = L("请填写规则值")
            return
        }
        let rule = Rule(type: newType, value: trimmed, target: newTarget)
        state.addCustomRule(rule)
        newValue = ""
        addError = nil
    }

    private static func displayName(for type: RuleType) -> LocalizedStringKey {
        switch type {
        case .domain:        return "域名（精确）"
        case .domainSuffix:  return "域名后缀"
        case .domainKeyword: return "域名关键字"
        case .ipCIDR:        return "IPv4 网段"
        case .ipCIDR6:       return "IPv6 网段"
        case .geoip:         return "GEOIP（国家代码）"
        case .processName:   return "进程名（仅 macOS）"
        case .userAgent:     return "User-Agent"
        case .final:         return "FINAL（兜底）"
        }
    }

    private static func displayName(for target: RuleTarget) -> LocalizedStringKey {
        switch target {
        case .proxy:  return "代理"
        case .direct: return "直连"
        case .reject: return "拒绝"
        }
    }

    private static func placeholder(for type: RuleType) -> String {
        switch type {
        case .domain:        return "example.com"
        case .domainSuffix:  return "google.com"
        case .domainKeyword: return "google"
        case .ipCIDR:        return "192.168.0.0/16"
        case .ipCIDR6:       return "fc00::/7"
        case .geoip:         return "cn / private"
        case .processName:   return "Telegram"
        case .userAgent:     return "MyApp/*"
        case .final:         return ""
        }
    }

    private var customSection: some View {
        Section("自定义规则（优先匹配）") {
            let filtered = engine.search(keyword: searchText).filter { rule in
                state.customRules.contains(where: { $0.id == rule.id })
            }
            if filtered.isEmpty {
                Text(searchText.isEmpty ? "暂无自定义规则" : "无匹配规则")
                    .foregroundStyle(.secondary).font(.caption)
            } else {
                ForEach(filtered) { rule in
                    ruleRow(rule, isCustom: true)
                }
            }
        }
    }

    private var remoteSection: some View {
        Section("远程规则") {
            let filtered = engine.search(keyword: searchText).filter { rule in
                state.remoteRules.contains(where: { $0.id == rule.id })
            }
            if filtered.isEmpty {
                Text(state.remoteRules.isEmpty ? "尚未加载远程规则" : "无匹配规则")
                    .foregroundStyle(.secondary).font(.caption)
            } else {
                ForEach(filtered.prefix(200)) { rule in
                    ruleRow(rule, isCustom: false)
                }
                if filtered.count > 200 {
                    Text("已展示前 200 条，共 \(filtered.count) 条匹配。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 内置 geoip.dat 是精简版（仅 cn/private，给 NE 扩展 50MB 内存预算省地）——
    /// 其他国家码的 GEOIP 规则转换层会跳过（xray 对缺失分类直接启动失败），这里如实标注。
    /// 完整版 geo 数据（此页一键下载 / 设置 → Geo 数据）就位后全部解锁，不再标注。
    private func isIneffectiveGeoIP(_ rule: Rule) -> Bool {
        !state.geoData.hasFullGeoIP && rule.type == .geoip && !GeoDataBundle.supportsGeoIP(rule.value)
    }

    /// 一键下载完整版 geo 数据的控件（下载进度 / 校验中 / 按钮 + 错误三态）。
    /// 下载成功后 AppState.downloadFullGeoData 自动热切换，GEOIP 规则立即生效。
    @ViewBuilder
    private var geoDownloadControl: some View {
        switch state.geoData.phase {
        case .downloading(let sourceName, let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .frame(maxWidth: 140)
                Text("正在从\(sourceName)下载…")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("校验中…").font(.caption2).foregroundStyle(.secondary)
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    Task { await state.downloadFullGeoData() }
                } label: {
                    Label("下载完整版 geo 数据", systemImage: "arrow.down.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                if case .failed(let message) = state.geoData.phase {
                    Text(message).font(.caption2).foregroundStyle(.red)
                }
            }
        }
    }

    private func ruleRow(_ rule: Rule, isCustom: Bool) -> some View {
        HStack {
            targetChip(rule.target)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.lineForm)
                    .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                if isIneffectiveGeoIP(rule) {
                    Text("需下载完整版 geo 数据，该规则暂不生效")
                        .font(.caption2).foregroundStyle(.orange)
                }
                // 命中计数只给自定义规则：远程规则整包换源，id 不稳定，计数没有参考价值
                if isCustom {
                    hitCountLabel(rule)
                }
            }
            Spacer()
            if isCustom {
                Button {
                    state.removeCustomRule(rule)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// 「近 30 天命中 N 次」+ 零命中弱提示。计数口径：MatchedRuleResolver 认领该规则的
    /// **新连接**数（本地统计，不上云）。跟踪不满 7 天观察期时不给「可考虑删除」——
    /// 否则功能上线首日所有规则都被误标（见 RuleHitStats.minObservedDays）。
    @ViewBuilder
    private func hitCountLabel(_ rule: Rule) -> some View {
        let count = state.ruleHitStats.hitCount(for: rule.id)
        HStack(spacing: 6) {
            Text("近 30 天命中 \(count) 次")
                .font(.caption2).foregroundStyle(.secondary)
            if state.ruleHitStats.isIdleCandidate(rule.id) {
                Text("· 长期未命中，可考虑删除")
                    .font(.caption2).foregroundStyle(.orange.opacity(0.85))
            }
        }
    }

    private func targetChip(_ target: RuleTarget) -> some View {
        Text(target.rawValue.prefix(1).uppercased())
            .font(.caption2.bold())
            .frame(width: 22, height: 22)
            .background(color(for: target).opacity(0.22))
            .foregroundStyle(color(for: target))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func color(for target: RuleTarget) -> Color {
        switch target {
        case .proxy:  return .blue
        case .direct: return .green
        case .reject: return .red
        }
    }

    private func refreshRemote() async {
        refreshing = true
        await state.refreshRemoteRules()
        refreshing = false
    }
}

/// Binding<URL?> ↔ Binding<String> 桥接：UI 上展示成字符串。
extension Binding where Value == URL? {
    func mapURL() -> Binding<String> {
        Binding<String>(
            get: { self.wrappedValue?.absoluteString ?? "" },
            set: { self.wrappedValue = URL(string: $0) }
        )
    }
}
