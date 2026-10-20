import SwiftUI
import QingzhouCore

/// 节点详情 / 编辑表单。
///
/// 字段分两层：
/// - 协议无关字段（name / host / port / password 等）以 typed text field 渲染；
/// - 协议特有的 `parameters: [String: String]` 用 key/value 表格，允许增删改。
public struct NodeDetailView: View {
    @Bindable var state: AppState
    /// 跟随 App 语言设置的 locale（根视图注入），日期格式化用
    @Environment(\.locale) private var locale
    @State var draft: Node
    @State private var diagnosticTask: Task<Void, Never>?
    @State private var diagnosticReport: NodeDiagnosticReport?
    @State private var diagnosticInterrupted = false
    @State private var newParamKey: String = ""
    @State private var newParamValue: String = ""
    /// 「为什么选它」评分构成，**进入详情时算一次**缓存（用户主动看才算 —— 节点多时
    /// 别每帧重算，同 NodeRateParser 预编译正则的教训）。测速/经代理测速改了数据后
    /// 在按钮回调里刷新。
    @State private var scoreBreakdown: NodeScorer.Score?
    @Environment(\.dismiss) private var dismiss

    public init(state: AppState, node: Node) {
        self.state = state
        _draft = State(initialValue: node)
    }

    public var body: some View {
        Form {
            identitySection
            diagnosticSection
            scoreSection
            basicSection
            credentialSection
            parametersSection
            stateSection
            footerSection
        }
        .formStyle(.grouped)
        .navigationTitle(draft.name.isEmpty ? L("节点详情") : draft.name)
        .onAppear { scoreBreakdown = state.scoreForAutoSelect(draft) }
        .onChange(of: state.measurementNetworkID) {
            if let live = state.nodes.first(where: { $0.id == draft.id }) {
                draft.lastLatencyMs = live.lastLatencyMs; draft.lastTestedAt = live.lastTestedAt
                draft.lastProxiedLatencyMs = live.lastProxiedLatencyMs; draft.lastProxiedTestedAt = live.lastProxiedTestedAt
                scoreBreakdown = state.scoreForAutoSelect(live)
            }
        }
        .onDisappear { diagnosticTask?.cancel(); diagnosticTask = nil }
        .onChange(of: draft.identityFingerprint) { invalidateDiagnostic() }
        .onChange(of: state.measurementNetworkID) { invalidateDiagnostic() }
        .onChange(of: state.nodes.first { $0.id == draft.id }?.identityFingerprint) { invalidateDiagnostic() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(!isValid)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
    }

    private func invalidateDiagnostic() {
        diagnosticTask?.cancel(); diagnosticTask = nil
        diagnosticReport = nil
        diagnosticInterrupted = true
    }

    private var diagnosticSection: some View {
        Section {
            if let report = diagnosticReport {
                LabeledContent("TCP 直连", value: report.directSummary)
                LabeledContent("真实代理链路", value: report.proxySummary)
                Text(report.explanation).font(.caption).foregroundStyle(.secondary)
                Text(report.completedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(locale)))
                    .font(.caption2).foregroundStyle(.secondary)
                Button("复制脱敏诊断报告") {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.sanitizedText, forType: .string)
                    #else
                    UIPasteboard.general.string = report.sanitizedText
                    #endif
                    state.showToast(L("已复制"))
                }
            }
            if diagnosticInterrupted {
                Text("诊断已失效，请重新运行。未保存的节点修改请先保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if diagnosticTask != nil {
                HStack { ProgressView().controlSize(.small); Button("取消诊断") { invalidateDiagnostic() } }
            } else {
                Button("运行连接诊断") {
                    diagnosticReport = nil; diagnosticInterrupted = false
                    diagnosticTask = Task {
                        let report = await state.diagnoseNode(draft)
                        guard !Task.isCancelled else { return }
                        diagnosticReport = report; diagnosticInterrupted = report == nil
                        if let live = state.nodes.first(where: { $0.id == draft.id && $0.identityFingerprint == draft.identityFingerprint }) {
                            draft.lastLatencyMs = live.lastLatencyMs; draft.lastTestedAt = live.lastTestedAt
                            draft.lastProxiedLatencyMs = live.lastProxiedLatencyMs; draft.lastProxiedTestedAt = live.lastProxiedTestedAt
                            scoreBreakdown = state.scoreForAutoSelect(live)
                        }
                        diagnosticTask = nil
                    }
                }
            }
        } header: {
            Text("连接诊断")
        } footer: {
            Text("分别检查直连与真实代理，不切换当前节点。报告不含节点名称、地址、凭据或订阅链接。")
        }
    }

    private var identitySection: some View {
        Section("身份") {
            LabeledContent("协议", value: draft.protocolType.rawValue.uppercased())
            LabeledContent("ID", value: draft.id.uuidString)
                .font(.caption2.monospaced())
            LabeledContent("指纹", value: AppliedTunnelConfiguration.digest(draft))
                .font(.caption2.monospaced())
                .lineLimit(1)
            if let subId = draft.subscriptionId,
               let sub = state.subscriptions.first(where: { $0.id == subId }) {
                LabeledContent("来源订阅", value: sub.name)
            } else {
                LabeledContent("来源", value: L("手动添加"))
            }
        }
    }

    /// 「为什么选它」评分构成条：总分 + 四维分量（横向 bar，标注每维得分与权重）。
    /// 透明度是信任来源 —— 让用户看懂自动择优凭什么选它，而非黑箱。
    private var scoreSection: some View {
        Section {
            if let s = scoreBreakdown {
                HStack(alignment: .firstTextBaseline) {
                    Text("综合评分").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(String(format: L("%lld 分"), Int(s.total.rounded())))
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(.tint)
                }
                dimensionRow(L("延迟"), comp: s.latency, color: .blue)
                dimensionRow(L("稳定性"), comp: s.stability, color: .green)
                dimensionRow(L("带宽"), comp: s.bandwidth, color: .purple)
                dimensionRow(L("成本"), comp: s.cost, color: .orange)
                Text("自动择优按此综合评分选节点：延迟 / 稳定性 / 带宽 / 成本四维各归一到 0–100 分再加权求和。每维右侧是它的得分与权重，权重由「设置 → 择优偏好」的档位决定。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("暂无评分数据 —— 先给节点测一次速。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("评分参考")
        } footer: {
            Text("这里是当前详情数据的评分参考；最近一次实际择优的结果与保持原因请看节点页。")
        }
    }

    /// 单维分量行：维度名 + 「N 分 · 权重 M%」+ 横向 bar（填充比例 = 得分/100）。
    private func dimensionRow(_ title: String, comp: NodeScorer.Component, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: L("%lld 分 · 权重 %lld%%"),
                            Int(comp.score.rounded()), Int((comp.weight * 100).rounded())))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.15))
                    Capsule().fill(color)
                        .frame(width: max(0, geo.size.width * comp.score / 100))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 2)
    }

    private var basicSection: some View {
        Section("基本") {
            TextField("名称", text: $draft.name)
            TextField("主机", text: $draft.host)
                .font(.body.monospaced())
            TextField("端口", value: $draft.port, format: .number.grouping(.never))
                .font(.body.monospaced())
        }
    }

    private var credentialSection: some View {
        Section("凭据 / 加密") {
            switch draft.protocolType {
            case .trojan, .hysteria2:
                SecureField("密码", text: Binding(
                    get: { draft.password ?? "" },
                    set: { draft.password = $0 }
                ))
            case .shadowsocks:
                TextField("加密方式", text: Binding(
                    get: { draft.cipher ?? "" },
                    set: { draft.cipher = $0 }
                ))
                SecureField("密码", text: Binding(
                    get: { draft.password ?? "" },
                    set: { draft.password = $0 }
                ))
            case .vmess:
                TextField("UUID", text: Binding(
                    get: { draft.uuid ?? "" },
                    set: { draft.uuid = $0 }
                ))
                .font(.caption.monospaced())
                Stepper(value: Binding(
                    get: { draft.alterId ?? 0 },
                    set: { draft.alterId = $0 }
                ), in: 0...65535) {
                    LabeledContent("alterId", value: "\(draft.alterId ?? 0)")
                }
                TextField("加密 (scy)", text: Binding(
                    get: { draft.cipher ?? "auto" },
                    set: { draft.cipher = $0 }
                ))
            case .vless:
                TextField("UUID", text: Binding(
                    get: { draft.uuid ?? "" },
                    set: { draft.uuid = $0 }
                ))
                .font(.caption.monospaced())
            }
        }
    }

    private var parametersSection: some View {
        Section("传输参数") {
            if draft.parameters.isEmpty {
                Text("无").foregroundStyle(.secondary).font(.caption)
            } else {
                ForEach(draft.parameters.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                    HStack {
                        Text(entry.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        TextField("值", text: Binding(
                            get: { draft.parameters[entry.key] ?? "" },
                            set: { draft.parameters[entry.key] = $0 }
                        ))
                        .font(.caption.monospaced())
                        Button {
                            draft.parameters.removeValue(forKey: entry.key)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                TextField("键 (如 sni)", text: $newParamKey)
                    .font(.caption.monospaced())
                    .frame(width: 110)
                TextField("值", text: $newParamValue)
                    .font(.caption.monospaced())
                Button {
                    let k = newParamKey.trimmingCharacters(in: .whitespaces)
                    let v = newParamValue.trimmingCharacters(in: .whitespaces)
                    guard !k.isEmpty else { return }
                    draft.parameters[k] = v
                    newParamKey = ""
                    newParamValue = ""
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(newParamKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var stateSection: some View {
        Section("状态") {
            Toggle("排除（不参与自动择优）", isOn: $draft.isExcluded)
            if let ms = draft.lastLatencyMs {
                LabeledContent("直连延迟", value: L("\(ms) ms"))
            }
            if let t = draft.lastTestedAt {
                LabeledContent("最近测速", value: t.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))
            }
            if let pms = draft.lastProxiedLatencyMs {
                LabeledContent("经代理延迟", value: L("\(pms) ms"))
            } else if draft.lastProxiedTestedAt != nil {
                LabeledContent("经代理延迟", value: L("上次测试失败"))
            }
            if let pt = draft.lastProxiedTestedAt {
                LabeledContent("最近经代理测速", value: pt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))
            }
            if let bps = state.recentBandwidth(for: draft) {
                LabeledContent("近期下载观测", value: "↓ " + ByteFormatter.speed(bps))
                if let bt = draft.observedBandwidthAt {
                    LabeledContent("观测于", value: bt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))
                }
                Text("近 30 分钟可归属到此节点的代理下载观测，至少覆盖 3 个分钟，过滤孤立尖峰。未额外下载，不能视为线路最大带宽。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button {
                Task {
                    await state.measureProxiedLatency(draft)
                    if let live = state.nodes.first(where: { $0.id == draft.id && $0.identityFingerprint == draft.identityFingerprint }) {
                        draft.lastProxiedLatencyMs = live.lastProxiedLatencyMs
                        draft.lastProxiedTestedAt = live.lastProxiedTestedAt
                    }
                    // 经代理延迟变了 → 刷新「为什么选它」评分（延迟维会重新混合）
                    scoreBreakdown = state.scoreForAutoSelect(draft)
                }
            } label: {
                if state.proxiedMeasuringNodeIds.contains(draft.id) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("经代理测速中…")
                    }
                } else {
                    Label(state.isVPNRunning ? "测经代理延迟" : "测经代理延迟（需 VPN 运行中）",
                          systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            .disabled(!state.isVPNRunning || state.proxiedMeasuringNodeIds.contains(draft.id))
        }
    }

    private var footerSection: some View {
        Section {
            Button(role: .destructive) {
                state.removeNode(draft)
                dismiss()
            } label: {
                Label("删除节点", systemImage: "trash")
            }
        }
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.host.trimmingCharacters(in: .whitespaces).isEmpty
            && draft.port > 0 && draft.port < 65536
    }

    private func save() {
        state.updateNode(draft)
        dismiss()
    }
}
