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
        List {
            statusSection
            addSection
            customSection
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

            // GEOIP 精简版提示：内置 geo 数据只含 cn/private（NE 扩展 50MB 内存预算），
            // 其他国家码的规则不会生效 —— 用户一输入就知道，别等真机跑了才发现分流不对。
            if newType == .geoip {
                let v = newValue.trimmingCharacters(in: .whitespaces)
                if !v.isEmpty && !GeoDataBundle.supportsGeoIP(v) {
                    Text("当前 geo 数据不含「\(v)」，该规则将不生效（内置精简版仅含 cn / private，完整版下载后续提供）")
                        .font(.caption2).foregroundStyle(.orange)
                } else {
                    Text("内置 geo 数据为精简版，GEOIP 仅支持 cn 与 private。")
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
            addError = "请填写规则值"
            return
        }
        let rule = Rule(type: newType, value: trimmed, target: newTarget)
        state.addCustomRule(rule)
        newValue = ""
        addError = nil
    }

    private static func displayName(for type: RuleType) -> String {
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

    private static func displayName(for target: RuleTarget) -> String {
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
    private func isIneffectiveGeoIP(_ rule: Rule) -> Bool {
        rule.type == .geoip && !GeoDataBundle.supportsGeoIP(rule.value)
    }

    private func ruleRow(_ rule: Rule, isCustom: Bool) -> some View {
        HStack {
            targetChip(rule.target)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.lineForm)
                    .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                if isIneffectiveGeoIP(rule) {
                    Text("当前 geo 数据不含 \(rule.value)，规则将不生效")
                        .font(.caption2).foregroundStyle(.orange)
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
