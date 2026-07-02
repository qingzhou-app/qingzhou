import SwiftUI
import QingzhouCore

/// 节点详情 / 编辑表单。
///
/// 字段分两层：
/// - 协议无关字段（name / host / port / password 等）以 typed text field 渲染；
/// - 协议特有的 `parameters: [String: String]` 用 key/value 表格，允许增删改。
public struct NodeDetailView: View {
    @Bindable var state: AppState
    @State var draft: Node
    @State private var newParamKey: String = ""
    @State private var newParamValue: String = ""
    @Environment(\.dismiss) private var dismiss

    public init(state: AppState, node: Node) {
        self.state = state
        _draft = State(initialValue: node)
    }

    public var body: some View {
        Form {
            identitySection
            basicSection
            credentialSection
            parametersSection
            stateSection
            footerSection
        }
        .formStyle(.grouped)
        .navigationTitle(draft.name.isEmpty ? "节点详情" : draft.name)
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

    private var identitySection: some View {
        Section("身份") {
            LabeledContent("协议", value: draft.protocolType.rawValue.uppercased())
            LabeledContent("ID", value: draft.id.uuidString)
                .font(.caption2.monospaced())
            LabeledContent("指纹", value: draft.identityFingerprint)
                .font(.caption2.monospaced())
                .lineLimit(1)
            if let subId = draft.subscriptionId,
               let sub = state.subscriptions.first(where: { $0.id == subId }) {
                LabeledContent("来源订阅", value: sub.name)
            } else {
                LabeledContent("来源", value: "手动添加")
            }
        }
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
                LabeledContent("直连延迟", value: "\(ms) ms")
            }
            if let t = draft.lastTestedAt {
                LabeledContent("最近测速", value: t.formatted(date: .abbreviated, time: .shortened))
            }
            if let pms = draft.lastProxiedLatencyMs {
                LabeledContent("经代理延迟", value: "\(pms) ms")
            } else if draft.lastProxiedTestedAt != nil {
                LabeledContent("经代理延迟", value: "上次测试失败")
            }
            if let pt = draft.lastProxiedTestedAt {
                LabeledContent("最近经代理测速", value: pt.formatted(date: .abbreviated, time: .shortened))
            }
            Button {
                Task {
                    if let ms = await state.measureProxiedLatency(draft) {
                        draft.lastProxiedLatencyMs = ms
                        draft.lastProxiedTestedAt = Date()
                    } else if state.isVPNRunning {
                        draft.lastProxiedLatencyMs = nil
                        draft.lastProxiedTestedAt = Date()
                    }
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
        if let idx = state.nodes.firstIndex(where: { $0.id == draft.id }) {
            // 直接替换：保留 lastLatencyMs/lastTestedAt/subscriptionId 等
            state.nodes[idx] = draft
            state.logger.info("Edited node \(draft.name)", category: "app")
            state.persist()
        }
        dismiss()
    }
}
