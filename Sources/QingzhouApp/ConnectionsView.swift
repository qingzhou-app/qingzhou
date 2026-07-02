import SwiftUI
import QingzhouCore

public struct ConnectionsView: View {
    @Bindable var state: AppState
    @State private var keyword: String = ""
    @State private var filter: ConnectionFilter = .active
    @State private var showDomainAnalysis = false
    /// 「忽略 IP」过滤：临时状态，不持久化 —— 离开本页自动复位。
    /// 经 Binding 传给域名分析页，两页联动。
    @State private var hideBareIPs = false

    enum ConnectionFilter: String, CaseIterable, Identifiable {
        case active = "活跃"
        case closed = "已关闭"
        case all = "全部"
        var id: String { rawValue }
    }

    public init(state: AppState) { self.state = state }

    public var body: some View {
        let result = filtered
        VStack(spacing: 0) {
            controls(hiddenIPCount: result.hiddenIPCount)
            if result.visible.isEmpty {
                ContentUnavailableView {
                    Label("暂无连接", systemImage: "antenna.radiowaves.left.and.right.slash")
                } description: {
                    if result.hiddenIPCount > 0 {
                        Text("「忽略 IP」已隐藏 \(result.hiddenIPCount) 条纯 IP 连接。")
                    } else {
                        Text("开启 VPN 后，这里会展示真实的访问记录。")
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                List(result.visible) { c in
                    connectionRow(c)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("连接")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showDomainAnalysis = true } label: {
                    // 图标 + 文字并显：toolbar 默认只出图标，第一眼看不懂。
                    // iOS 的 ToolbarItem 里 .labelStyle(.titleAndIcon) 经常不生效
                    // （仍渲染成 icon-only），用 HStack 强制横排；macOS 用 Label 即可。
                    #if os(iOS)
                    HStack(spacing: 4) {
                        Image(systemName: "chart.pie")
                        Text("域名分析")
                    }
                    #else
                    Label("域名分析", systemImage: "chart.pie")
                        .labelStyle(.titleAndIcon)
                    #endif
                }
            }
        }
        .sheet(isPresented: $showDomainAnalysis) {
            NavigationStack {
                DomainAnalysisView(state: state, hideBareIPs: $hideBareIPs)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showDomainAnalysis = false }
                        }
                    }
            }
            // sheet 盖住 RootView 的 toast 浮层，一键规则的反馈要在 sheet 里再挂一份才可见
            .toastOverlay(state: state)
            // macOS 上 sheet 不给尺寸会缩成一个小空框（看起来"啥都没有"）——显式给最小尺寸。
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 560)
            #endif
        }
        .searchable(text: $keyword, prompt: "搜索 host / route / app")
    }

    private func controls(hiddenIPCount: Int) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Picker("", selection: $filter) {
                    ForEach(ConnectionFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                // 放在分段控件旁而不是 toolbar：iOS 工具栏空间紧，这里文字能完整展示
                IgnoreIPToggle(isOn: $hideBareIPs)
            }
            // 过滤生效时的轻提示：避免用户忘了开着「忽略 IP」，以为数据丢了
            if hiddenIPCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "eye.slash").imageScale(.small)
                    Text("忽略 IP：已隐藏 \(hiddenIPCount) 条纯 IP 连接")
                }
                .font(.caption2)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// 三层过滤：状态（活跃/已关闭）→ 关键字 → 「忽略 IP」。
    /// `hiddenIPCount` 只统计前两层已命中、仅因裸 IP 被隐藏的条数，用于轻提示。
    private var filtered: (visible: [Connection], hiddenIPCount: Int) {
        let kw = keyword.lowercased()
        let hideIP = hideBareIPs
        var visible: [Connection] = []
        var hiddenIP = 0
        for c in state.connections {
            let scopeOK: Bool
            switch filter {
            case .active: scopeOK = c.isActive
            case .closed: scopeOK = !c.isActive
            case .all:    scopeOK = true
            }
            let kwOK = kw.isEmpty
                || c.targetHost.lowercased().contains(kw)
                || c.route.lowercased().contains(kw)
                || c.matchedRule.lowercased().contains(kw)
                || (c.sourceApp?.lowercased().contains(kw) ?? false)
            guard scopeOK && kwOK else { continue }
            if hideIP && HostClassifier.isBareIP(c.targetHost) {
                hiddenIP += 1
                continue
            }
            visible.append(c)
        }
        // 「已关闭」按关闭时间倒序 —— 刚关闭的在最上面；其他分组保持摄入序（新连接在前）
        if filter == .closed {
            visible.sort { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
        }
        return (visible, hiddenIP)
    }

    private func connectionRow(_ c: Connection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(statusDotColor(c))
                    .frame(width: 8, height: 8)
                Text(c.targetHost).font(.headline)
                Spacer()
                Text(c.type.rawValue.uppercased())
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.18))
                    .clipShape(Capsule())
            }
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.swap").imageScale(.small)
                Text(c.matchedRule).font(.caption.monospaced()).lineLimit(1)
                Text("→ \(c.route)").font(.caption.monospaced())
                Spacer()
                // 字节/速率在接上 xray QueryStats 前没有真实来源（恒 0），先不显示假数字；
                // 接上后在这里恢复 upload/download 字节 + 速率展示。
                // 活跃连接显示建立时间；已关闭的显示关闭时间（更有信息量）
                if let closedAt = c.closedAt {
                    Text("关闭于 \(closedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption2.monospaced())
                } else {
                    Text(c.openedAt.formatted(.relative(presentation: .named)))
                        .font(.caption2.monospaced())
                }
            }
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                // 来源 app：macOS 由 content-filter 提供 bundle id，显示真实图标+名字；iOS 拿不到时省略。
                if let app = c.sourceApp, !app.isEmpty {
                    SourceAppLabel(bundleID: app)
                    Text("·")
                }
                Text("\(c.sourceAddress) → \(c.targetAddress)").lineLimit(1)
            }
            .font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        // 一键规则：iOS 长按/左滑，macOS 右键 →「加入直连 / 代理 / 拒绝」
        .quickRuleActions(host: c.targetHost, state: state)
    }

    /// 行首状态点：被拒绝的连接恒为红色 —— xray reject 是即时的，没有「连通」阶段，
    /// 沿用 isActive 的绿点会让用户以为连接成功了（真实验收反馈）。
    ///
    /// 只改显示层、不在摄入时置 closedAt：被拒目标（典型是广告域名）会高频重试，
    /// ConnectionTracker 靠「活跃身份」去重才让它们合并成一行；摄入即关闭会破坏去重
    /// （每次重试都成新行，连接页和每日拒绝计数一起灌水），或者得给 tracker 引入
    /// 「已关闭仍去重」的特殊态。显示层修复已消除误导，域名分析的拒绝统计口径不变。
    private func statusDotColor(_ c: Connection) -> Color {
        if DomainAnalyzer.routeCategory(c.route) == .reject { return .red }
        return c.isActive ? .green : .secondary
    }
}
