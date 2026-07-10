import SwiftUI
import QingzhouCore
import QingzhouProtocols

public struct NodesView: View {
    @Bindable var state: AppState
    @State private var searchText: String = ""
    @State private var showAdd = false
    @State private var showScanner = false
    /// 「什么是经代理延迟？」科普弹窗（工具栏「⋯」菜单入口）
    @State private var showProxiedLatencyExplainer = false
    @State private var addInput: String = ""
    @State private var addError: String?
    @State private var qrShareNode: Node?
    @State private var detailNode: Node?
    @State private var isMeasuring = false
    @State private var isAutoSelecting = false
    /// 批量「经代理延迟」测速中（VPN 开启时经隧道扩展逐个真实走节点测）。
    @State private var isProxiedMeasuring = false
    @State private var proxiedMeasureTotal = 0
    /// 本轮批量测速的总数（开测那刻的非排除节点数）。配合 measuringNodeIds 的
    /// 剩余量算出「12/47」进度 —— measuringNodeIds 只知道还剩几个，不知道总共几个。
    @State private var measureTotal = 0
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
        // 下拉刷新语义取「重测全部延迟」而非「拉订阅」：节点内容的更新入口在订阅页
        //（那边有自己的下拉刷新），而本页用户最常想要的"刷新"是延迟列，且 measureAllNodes
        // 自带逐行转圈 + 「上次测速 刚刚」的可见反馈。
        .refreshable {
            guard !isMeasuring, !isAutoSelecting else { return }
            await runBatchMeasure()
        }
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
                    Task { await runBatchMeasure() }
                } label: {
                    if isMeasuring {
                        // 测速中按钮变进度态：「12/47」告诉用户测到哪了，而不是干转圈
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("\(measureDone)/\(measureTotal)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
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
                            autoSelectMessage = L("未找到比当前节点更快的")
                        } else if let n = state.currentNode {
                            autoSelectMessage = L("已选: \(n.name)") + (n.lastLatencyMs.map { L(" (\($0) ms)") } ?? "")
                        } else {
                            autoSelectMessage = L("所有节点测速失败，未做切换")
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
            ToolbarItem {
                Menu {
                    Button {
                        Task { await runBatchProxiedMeasure() }
                    } label: {
                        if isProxiedMeasuring {
                            Label("经代理测速中 \(proxiedMeasureDone)/\(proxiedMeasureTotal)…",
                                  systemImage: "point.3.connected.trianglepath.dotted")
                        } else {
                            Label("测全部经代理延迟", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    }
                    .disabled(!state.isVPNRunning || isProxiedMeasuring || state.nodes.isEmpty)
                    if !state.isVPNRunning {
                        Text("经代理测速需要 VPN 运行中")
                    }
                    Button {
                        showProxiedLatencyExplainer = true
                    } label: {
                        Label("什么是经代理延迟？", systemImage: "info.circle")
                    }
                    Divider()
                    Button {
                        let text = NodeEncoder.shareLinks(state.nodes)
                        guard !text.isEmpty else { return }
                        copyLink(text)
                        state.showToast(L("已复制 \(text.split(separator: "\n").count) 条节点分享链接"))
                    } label: {
                        Label("导出全部节点链接（复制）", systemImage: "square.and.arrow.up.on.square")
                    }
                    .disabled(state.nodes.isEmpty)
                } label: {
                    if isProxiedMeasuring {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("\(proxiedMeasureDone)/\(proxiedMeasureTotal)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Label("更多", systemImage: "ellipsis.circle")
                    }
                }
                .help("批量操作：经代理测速 / 导出全部节点")
            }
        }
        .alert("经代理延迟是什么？", isPresented: $showProxiedLatencyExplainer) {
            Button("知道了", role: .cancel) {}
        } message: {
            // 单字面量 + 显式 \n\n（多行 """ 的续行符会让 key 难以在字符串目录里精确复现）
            Text("普通测速（无图标的数字）是设备直接对节点服务器握手一次，只说明「节点离你近不近、活着没」——密码错误的节点它也照样显示很快。\n\n经代理延迟（带 ⋱ 图标）是 VPN 运行时，让 xray 携带完整协议真实通过该节点访问一次 google.com，测出的是你实际用它上网的端到端耗时——协议握手、节点转发、出口线路质量全部包含。数值天然比直连大，但它才是真实体感：直连快、经代理慢 = 节点出口绕路；直连快、经代理失败 = 节点不可用（如凭据错误）。")
        }
        .sheet(isPresented: $showAdd) { addSheet }
        .sheet(item: $qrShareNode) { node in qrShareSheet(node) }
        .sheet(item: $detailNode) { node in
            NavigationStack {
                NodeDetailView(state: state, node: node)
            }
            // ⚠️ 这个 minWidth 只能给 macOS：iPhone 屏宽不足 480pt，强设会把 sheet
            // 内容撑出屏幕，观感像「整页被放大」（真机验收打回）。iOS 交给系统 sheet 布局。
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 520)
            #endif
        }
        #if os(iOS)
        .sheet(isPresented: $showScanner) { scannerSheet }
        #endif
        // 批量测速完成时一记 .success（iOS 触觉；macOS no-op）—— 用户等的是这个时刻
        .sensoryFeedback(.success, trigger: isMeasuring) { wasMeasuring, now in
            wasMeasuring && !now
        }
        // App Store 截图 demo 钩子（-qz-screenshot 启动参数才可达，正常启动恒 false）：
        // nodes → 呈现「自动择优刚完成」的反馈条；node-detail → 自动打开当前节点详情 sheet
        //（「为什么选它」评分构成）。都是真实交互后可达的 UI 状态，不伪造新界面。
        .task {
            guard ScreenshotDemoMode.isActive else { return }
            if ScreenshotDemoMode.wantsAutoSelectBanner, let n = state.currentNode {
                autoSelectMessage = L("已选: \(n.name)") + (n.lastLatencyMs.map { L(" (\($0) ms)") } ?? "")
            }
            if ScreenshotDemoMode.wantsNodeDetail {
                try? await Task.sleep(for: .milliseconds(700))
                detailNode = state.currentNode
            }
        }
    }

    /// 批量测速（工具栏按钮 / 下拉刷新共用）：记下总数，进度随 measuringNodeIds 递减。
    private func runBatchMeasure() async {
        isMeasuring = true
        // 与 measureAllNodes 的待测集合同口径（非排除节点）
        measureTotal = state.nodes.filter { !$0.isExcluded }.count
        await state.measureAllNodes()
        isMeasuring = false
    }

    /// 已测完个数 = 总数 - 还在测的。钳位到 0 防御 total 没记上的边界。
    private var measureDone: Int {
        max(0, measureTotal - state.measuringNodeIds.count)
    }

    /// 批量经代理测速（串行逐个，扩展同一时刻只跑一个临时 xray 实例）。
    private func runBatchProxiedMeasure() async {
        guard !isProxiedMeasuring else { return }
        isProxiedMeasuring = true
        proxiedMeasureTotal = state.nodes.filter { !$0.isExcluded }.count
        await state.measureAllProxiedLatencies()
        isProxiedMeasuring = false
    }

    private var proxiedMeasureDone: Int {
        max(0, proxiedMeasureTotal - state.proxiedMeasuringNodeIds.count)
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
                Button("完成") {
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
                        addError = result.errors.first.map { L("解析失败：\(String(describing: $0.1))") } ?? L("输入不像节点链接")
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
            HStack {
                Button {
                    copyLink(shareString(for: node))
                } label: {
                    Label("复制链接", systemImage: "doc.on.doc")
                }
                Button("完成") { qrShareNode = nil }
            }
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

    /// 把节点反序列化成可分享的链接形式。复用规范编码器 `NodeEncoder.shareLink`
    /// （与「启动 VPN 时喂给 xray」同一份逻辑），避免视图里再维护一份会漂移的副本。
    private func shareString(for node: Node) -> String {
        NodeEncoder.shareLink(node) ?? ""
    }

    /// 复制到剪贴板（跨平台）。
    private func copyLink(_ text: String) {
        copyToPasteboard(text)
    }
}

/// 复制到剪贴板（跨平台）—— NodesView / NodeRow 共用。
private func copyToPasteboard(_ text: String) {
    #if canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #elseif canImport(UIKit)
    UIPasteboard.general.string = text
    #endif
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
                    Text(node.name).font(.body).lineLimit(1)
                    if node.isExcluded {
                        tag("已排除", color: .secondary)
                    } else if state.settings.excludedRegions.contains(node.region) {
                        tag("地区已排除", color: .orange)
                    }
                    if node.subscriptionId != nil {
                        tag("订阅", color: .blue)
                    }
                    // 倍率标签：只在非 1 倍时显示（1 倍是绝大多数，标了反而是噪音）。
                    // <1 省流量→绿；>1 费流量→橙。
                    if let rate = node.effectiveRate, rate != 1.0 {
                        rateTag(rate)
                    }
                }
                HStack(spacing: 6) {
                    Text("\(node.protocolType.rawValue.uppercased()) · \(node.host):\(node.port)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    // 被动观测的实测峰值下行带宽（用过才有）—— 零额外流量，反映真实带宽
                    if let bps = node.observedPeakDownBps {
                        Text("· ↓ \(ByteFormatter.speed(bps))")
                            .font(.caption.monospaced()).foregroundStyle(.blue)
                    }
                }
            }
            Spacer(minLength: 8)
            // 两个延迟维度：iOS **竖排**（上直连、下经代理）—— iPhone 窄屏 + 长节点名
            // 横排会把其中一枚挤出屏幕（真机验收打回）；macOS 窗口宽裕，保持横排
            //（左经代理、右直连）信息密度更好。chips 加 layoutPriority，
            // 宁可截断节点名也不截断延迟。
            latencyChips
                .layoutPriority(1)
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
            Button {
                if let link = NodeEncoder.shareLink(node) {
                    copyToPasteboard(link)
                    state.showToast(L("已复制分享链接"))
                }
            } label: {
                Label("复制分享链接", systemImage: "doc.on.doc")
            }
            Divider()
            Button {
                Task { await state.measureProxiedLatency(node) }
            } label: {
                Label(state.isVPNRunning ? "测经代理延迟" : "测经代理延迟（需 VPN 运行中）",
                      systemImage: "point.3.connected.trianglepath.dotted")
            }
            .disabled(!state.isVPNRunning || state.proxiedMeasuringNodeIds.contains(node.id))
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

    @ViewBuilder
    private var latencyChips: some View {
        #if os(iOS)
        VStack(alignment: .trailing, spacing: 3) {
            directChipOrSpinner
            proxiedChipOrSpinner
        }
        #else
        HStack(spacing: 6) {
            proxiedChipOrSpinner
            directChipOrSpinner
        }
        #endif
    }

    @ViewBuilder
    private var directChipOrSpinner: some View {
        if state.measuringNodeIds.contains(node.id) {
            ProgressView().controlSize(.small)
        } else {
            latencyChip(node.lastLatencyMs)
        }
    }

    @ViewBuilder
    private var proxiedChipOrSpinner: some View {
        if state.proxiedMeasuringNodeIds.contains(node.id) {
            ProgressView().controlSize(.small)
        } else if let pms = node.lastProxiedLatencyMs {
            proxiedLatencyChip(pms)
        }
    }

    /// 倍率标签：`0.5x` / `2x`（整数不带小数），<1 省流量绿、>1 费流量橙。
    private func rateTag(_ rate: Double) -> some View {
        let text = rate == rate.rounded() ? String(format: "%.0fx", rate) : String(format: "%gx", rate)
        return Text(text)
            .font(.caption2.monospaced())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((rate < 1 ? Color.green : .orange).opacity(0.18))
            .foregroundStyle(rate < 1 ? Color.green : .orange)
            .clipShape(Capsule())
    }

    // LocalizedStringKey：让 tag("已排除") 这类字面量走字符串目录
    private func tag(_ text: LocalizedStringKey, color: Color) -> some View {
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

    /// 「经代理延迟」chip：icon 区分维度；阈值比直连宽（全链路含 TLS+HTTP，天然更长）。
    private func proxiedLatencyChip(_ ms: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 8))
            Text("\(ms) ms")
                .font(.caption.monospaced())
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(proxiedColor(for: ms).opacity(0.18))
        .foregroundStyle(proxiedColor(for: ms))
        .clipShape(Capsule())
        .help("经代理延迟：真实通过该节点访问网站的全链路耗时")
    }

    private func color(for ms: Int) -> Color {
        // 绿色阈值与经代理精选的候选池同口径（AppState.directGreenThresholdMs）
        if ms < AppState.directGreenThresholdMs { return .green }
        if ms < 500 { return .orange }
        return .red
    }

    private func proxiedColor(for ms: Int) -> Color {
        // 经代理延迟 = 直连 RTT + 协议/TLS 握手 + HTTP + 出口跳数，是**冷测**（每次新起临时
        // xray + 全新 TLS），会放大真实浏览体感的 2–3 倍。阈值取「体感确实跟手」的口径：
        // <900 绿（稳态 ~300–500ms，跟手）、<2200 橙（稍沉但可用）、其余红。
        // 注意：这只反映**响应速度**，不反映带宽 —— 延迟低但带宽小的节点看视频照样卡。
        if ms < 900 { return .green }
        if ms < 2200 { return .orange }
        return .red
    }
}
