import SwiftUI
import VPNCore
import VPNProtocols

public struct NodesView: View {
    @Bindable var state: AppState
    @State private var searchText: String = ""
    @State private var showAdd = false
    @State private var showScanner = false
    @State private var addInput: String = ""
    @State private var addError: String?
    @State private var qrShareNode: Node?
    @State private var detailNode: Node?
    @State private var isMeasuring = false
    @State private var isAutoSelecting = false
    /// 自动择优完成后短暂显示的反馈条 —— 不弹 alert，省得用户被打断。
    @State private var autoSelectMessage: String?

    public init(state: AppState) { self.state = state }

    public var body: some View {
        List {
            controlsSection
            ForEach(filtered) { node in
                NodeRow(
                    state: state,
                    node: node,
                    onShare: { qrShareNode = $0 },
                    onDetail: { detailNode = $0 }
                )
            }
        }
        .navigationTitle("节点")
        .searchable(text: $searchText, prompt: "搜索节点 / 主机 / 协议")
        .toolbar {
            ToolbarItem {
                Button { showAdd = true } label: {
                    Label("添加", systemImage: "plus")
                }
                .help("粘贴节点链接 / 扫码添加 / 导入 Clash YAML")
            }
            ToolbarItem {
                Button {
                    Task {
                        isMeasuring = true
                        await state.measureAllNodes()
                        isMeasuring = false
                    }
                } label: {
                    if isMeasuring {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("测速", systemImage: "speedometer")
                    }
                }
                .disabled(isMeasuring || isAutoSelecting || state.nodes.isEmpty)
                .help("给所有未排除的节点测一次延迟")
            }
            ToolbarItem {
                Button {
                    Task {
                        isAutoSelecting = true
                        let before = state.currentNodeId
                        await state.autoSelectBestNode()
                        isAutoSelecting = false
                        if state.currentNodeId == before, before != nil {
                            autoSelectMessage = "未找到比当前节点更快的"
                        } else if let n = state.currentNode {
                            autoSelectMessage = "已选: \(n.name)" + (n.lastLatencyMs.map { " (\($0) ms)" } ?? "")
                        } else {
                            autoSelectMessage = "所有节点测速失败，未做切换"
                        }
                        // 4 秒后自动消失
                        try? await Task.sleep(for: .seconds(4))
                        autoSelectMessage = nil
                    }
                } label: {
                    if isAutoSelecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("自动择优", systemImage: "wand.and.stars")
                    }
                }
                .disabled(state.nodes.isEmpty || isMeasuring || isAutoSelecting)
                .help("先测速再选延迟最低的节点为当前节点")
            }
        }
        .sheet(isPresented: $showAdd) { addSheet }
        .sheet(item: $qrShareNode) { node in qrShareSheet(node) }
        .sheet(item: $detailNode) { node in
            NavigationStack {
                NodeDetailView(state: state, node: node)
            }
            .frame(minWidth: 480, minHeight: 520)
        }
        #if os(iOS)
        .sheet(isPresented: $showScanner) { scannerSheet }
        #endif
    }

    private var filtered: [Node] {
        let kw = searchText.lowercased()
        let sorted = state.sortedNodes
        guard !kw.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.lowercased().contains(kw) ||
            $0.host.lowercased().contains(kw) ||
            $0.protocolType.rawValue.contains(kw)
        }
    }

    @ViewBuilder
    private var controlsSection: some View {
        Section {
            Picker("排序", selection: state.setting(\.nodeSortOrder)) {
                Text("按名称").tag(NodeSortOrder.name)
                Text("按延迟").tag(NodeSortOrder.latency)
            }
            .pickerStyle(.segmented)
            if let mostRecent = state.nodes.compactMap(\.lastTestedAt).max() {
                Label {
                    // .relative 会自动随系统时钟刷新文字（"刚刚" / "3 分钟前" / ...）
                    Text("上次测速 \(mostRecent, format: .relative(presentation: .named))")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "speedometer").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if let msg = autoSelectMessage {
                Label(msg, systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .transition(.opacity)
            }
            if state.nodes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("还没有节点", systemImage: "tray")
                        .foregroundStyle(.secondary)
                    Text("通过订阅页添加订阅，或右上 + 按钮粘贴单条链接 / 扫码添加。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("添加节点").font(.headline)
                Spacer()
                Button("关闭") {
                    showAdd = false
                    addInput = ""
                    addError = nil
                }
            }
            Text("支持：trojan:// / ss:// / vmess:// / vless:// / hysteria2:// 链接（多行），或整段 Clash / Mihomo YAML 配置。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $addInput)
                .frame(minHeight: 100)
                .font(.system(.caption, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            if let err = addError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                #if os(iOS)
                Button {
                    showAdd = false
                    showScanner = true
                } label: {
                    Label("扫码", systemImage: "qrcode.viewfinder")
                }
                #endif
                Spacer()
                Button("添加") {
                    let result = state.addNodes(fromText: addInput)
                    if result.added == 0 {
                        addError = result.errors.first.map { "解析失败：\($0.1)" } ?? "输入不像节点链接"
                        return
                    }
                    showAdd = false
                    addInput = ""
                    addError = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(addInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 380, minHeight: 260)
    }

    private func qrShareSheet(_ node: Node) -> some View {
        VStack(spacing: 14) {
            Text(node.name).font(.headline)
            QRCodeView(text: shareString(for: node), size: 240)
            Text(shareString(for: node))
                .font(.caption2.monospaced()).lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled).foregroundStyle(.secondary).padding(.horizontal)
            Button("关闭") { qrShareNode = nil }
        }
        .padding()
        .frame(minWidth: 320, minHeight: 360)
    }

    #if os(iOS)
    private var scannerSheet: some View {
        ZStack(alignment: .bottom) {
            QRCodeScannerView { value in
                do {
                    try state.addNode(fromURL: value)
                    showScanner = false
                } catch {
                    state.logger.warn("Scanned QR not parseable: \(error)", category: "app")
                }
            }
            .ignoresSafeArea()
            HStack {
                Button("取消") { showScanner = false }
                    .padding().background(.regularMaterial).clipShape(Capsule())
                Spacer()
            }
            .padding()
        }
    }
    #endif

    /// 把节点反序列化成可分享的链接形式。
    /// 阶段 1 简化：trojan / ss / vless / hy2 直接拼回 URL；vmess 拼 base64 JSON。
    private func shareString(for node: Node) -> String {
        var queryItems: [URLQueryItem] = []
        for (k, v) in node.parameters {
            queryItems.append(URLQueryItem(name: k, value: v))
        }
        var comps = URLComponents()
        comps.scheme = node.protocolType.urlScheme
        comps.host = node.host
        comps.port = node.port
        if !queryItems.isEmpty { comps.queryItems = queryItems }
        comps.fragment = node.name

        switch node.protocolType {
        case .trojan, .hysteria2:
            comps.user = node.password
            return comps.url?.absoluteString ?? ""
        case .vless:
            comps.user = node.uuid
            return comps.url?.absoluteString ?? ""
        case .shadowsocks:
            // SIP002: ss://base64(method:password)@host:port#name
            let credential = "\(node.cipher ?? ""):\(node.password ?? "")"
            let b64 = Data(credential.utf8).base64EncodedString()
            comps.user = b64
            return comps.url?.absoluteString ?? ""
        case .vmess:
            var json: [String: Any] = [
                "v": "2",
                "ps": node.name,
                "add": node.host,
                "port": "\(node.port)",
                "id": node.uuid ?? "",
                "aid": node.alterId ?? 0,
                "scy": node.cipher ?? "auto"
            ]
            for (k, v) in node.parameters { json[k] = v }
            if let data = try? JSONSerialization.data(withJSONObject: json) {
                return "vmess://" + data.base64EncodedString()
            }
            return ""
        }
    }
}

private struct NodeRow: View {
    @Bindable var state: AppState
    let node: Node
    let onShare: (Node) -> Void
    let onDetail: (Node) -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if state.currentNodeId == node.id {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text(node.name).font(.body)
                    if node.isExcluded {
                        tag("已排除", color: .secondary)
                    }
                    if node.subscriptionId != nil {
                        tag("订阅", color: .blue)
                    }
                }
                Text("\(node.protocolType.rawValue.uppercased()) · \(node.host):\(node.port)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            latencyChip(node.lastLatencyMs)
        }
        .contentShape(Rectangle())
        .onTapGesture { state.select(node) }
        .contextMenu {
            Button(state.currentNodeId == node.id ? "✓ 已选中" : "选为当前") { state.select(node) }
                .disabled(state.currentNodeId == node.id)
            Button(node.isExcluded ? "取消排除" : "排除节点") { state.toggleExclusion(node) }
            Button {
                onDetail(node)
            } label: {
                Label("查看详情 / 编辑", systemImage: "info.circle")
            }
            Button {
                onShare(node)
            } label: {
                Label("分享二维码", systemImage: "qrcode")
            }
            Divider()
            Button(role: .destructive) {
                state.removeNode(node)
            } label: {
                Label("删除节点", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { state.removeNode(node) } label: {
                Label("删除", systemImage: "trash")
            }
            Button { onShare(node) } label: {
                Label("分享", systemImage: "qrcode")
            }
            .tint(.blue)
            Button { onDetail(node) } label: {
                Label("详情", systemImage: "info.circle")
            }
            .tint(.gray)
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

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
                Text("—")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func color(for ms: Int) -> Color {
        if ms < 200 { return .green }
        if ms < 500 { return .orange }
        return .red
    }
}
