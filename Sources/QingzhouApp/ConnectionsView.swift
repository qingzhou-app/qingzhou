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
    /// 「隐藏 DNS」过滤：同款临时状态，两页联动。
    @State private var hideDNS = false

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
            controls(hiddenIPCount: result.hiddenIPCount, hiddenDNSCount: result.hiddenDNSCount)
            if result.visible.isEmpty {
                let empty = Self.emptyState(filter: filter, searching: !keyword.isEmpty,
                                            hiddenIPCount: result.hiddenIPCount,
                                            vpnRunning: state.isVPNRunning)
                ContentUnavailableView {
                    Label(empty.title, systemImage: empty.icon)
                } description: {
                    Text(empty.description)
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
                DomainAnalysisView(state: state, hideBareIPs: $hideBareIPs, hideDNS: $hideDNS)
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
        // App Store 截图 demo 钩子（-qz-screenshot 才可达）：-qz-tab analysis 时自动弹出
        // 域名分析 sheet —— 与真实点工具栏「域名分析」到达的状态一致。
        .task {
            if ScreenshotDemoMode.wantsDomainAnalysisSheet {
                try? await Task.sleep(for: .milliseconds(600))
                showDomainAnalysis = true
            }
        }
    }

    /// 空态文案：按「为什么空」区分。踩过的坑：三个分组共用「开启 VPN 后…」——
    /// VPN 明明开着时用户会以为开关没开（真实验收反馈）。
    /// 优先级：过滤导致（搜索词/忽略 IP）> 「已关闭」分组语义 > VPN 状态。
    static func emptyState(filter: ConnectionFilter, searching: Bool,
                           hiddenIPCount: Int, vpnRunning: Bool)
        -> (title: String, description: String, icon: String) {
        if searching || hiddenIPCount > 0 {
            var d = L("当前搜索/过滤条件下没有匹配项。")
            if hiddenIPCount > 0 {
                d += L("「忽略 IP」已隐藏 \(hiddenIPCount) 条纯 IP 连接。")
            }
            return (L("没有匹配的连接"), d, "line.3.horizontal.decrease.circle")
        }
        if filter == .closed {
            return (L("还没有已关闭的连接"),
                    L("活跃连接约 \(Int(ConnectionTracker.idleTimeout)) 秒无活动后会归入这里。"),
                    "clock.arrow.circlepath")
        }
        if vpnRunning {
            return (L("暂无连接记录"), L("浏览网页后这里会实时更新。"),
                    "antenna.radiowaves.left.and.right")
        }
        return (L("暂无连接"), L("开启 VPN 后，这里会展示真实的访问记录。"),
                "antenna.radiowaves.left.and.right.slash")
    }

    private func controls(hiddenIPCount: Int, hiddenDNSCount: Int) -> some View {
        VStack(spacing: 4) {
            Picker("", selection: $filter) {
                ForEach(ConnectionFilter.allCases) { f in
                    Text(L10n.lookup(f.rawValue)).tag(f)
                }
            }
            .pickerStyle(.segmented)
            // 两个过滤开关并排在分段控件下方：iOS 工具栏空间紧，这里文字能完整展示
            HStack(spacing: 8) {
                IgnoreIPToggle(isOn: $hideBareIPs)
                HideDNSToggle(isOn: $hideDNS)
                Spacer()
            }
            // DoH 检测：裸 IP 连接占比异常高时说明原因（可关闭，会话级）
            if DoHNoticeBanner.shouldShow(state: state) {
                DoHNoticeBanner(state: state)
            }
            // 「仅 IPv6」站点提示：这类站点连不上、没有连接行，per-row 徽标挂不上，
            // 在这里独立列出。复用 filterHint（与「忽略 IP」等提示同款布局，窄窗口稳妥；
            // 别用 fixedSize + 自定义 frame，macOS 窄窗口 VStack 里会布局塌缩）。
            // 详细域名 + 说明在日志页（docs/IPV6.md）。
            if !state.ipv6OnlyHosts.isEmpty {
                filterHint(icon: "6.circle",
                           text: L("仅 IPv6 站点（无 IPv4 地址、直连不可达）：\(state.ipv6OnlyHosts.sorted().joined(separator: "、"))"))
            }
            // 过滤生效时的轻提示：避免用户忘了开着过滤，以为数据丢了
            if hiddenIPCount > 0 {
                filterHint(icon: "eye.slash", text: L("忽略 IP：已隐藏 \(hiddenIPCount) 条纯 IP 连接"))
            }
            if hiddenDNSCount > 0 {
                filterHint(icon: "point.3.filled.connected.trianglepath.dotted",
                           text: L("隐藏 DNS：已隐藏 \(hiddenDNSCount) 条 DNS 查询"))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func filterHint(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).imageScale(.small)
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 四层过滤：状态（活跃/已关闭）→ 关键字 →「隐藏 DNS」→「忽略 IP」。
    /// `hiddenIPCount` / `hiddenDNSCount` 只统计前面层已命中、仅因该项被隐藏的条数，
    /// 用于轻提示。DNS 判定在「忽略 IP」之前：DNS 查询目标是 IP，两个开关都会命中它，
    /// 先归给 DNS 计数更贴合用户心智（这条被隐藏是因为它是 DNS，不是因为它是裸 IP）。
    private var filtered: (visible: [Connection], hiddenIPCount: Int, hiddenDNSCount: Int) {
        let kw = keyword.lowercased()
        var visible: [Connection] = []
        var hiddenIP = 0
        var hiddenDNS = 0
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
            if hideDNS && c.isDNSQuery {
                hiddenDNS += 1
                continue
            }
            if hideBareIPs && HostClassifier.isBareIP(c.targetHost) {
                hiddenIP += 1
                continue
            }
            visible.append(c)
        }
        // 「已关闭」按关闭时间倒序 —— 刚关闭的在最上面；其他分组保持摄入序（新连接在前）
        if filter == .closed {
            visible.sort { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
        }
        return (visible, hiddenIP, hiddenDNS)
    }

    private func connectionRow(_ c: Connection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(statusDotColor(c))
                    .frame(width: 8, height: 8)
                Text(c.targetHost).font(.headline)
                Spacer()
                // 「仅 IPv6」标注：该域名没有 IPv4 地址，全 IPv4 链路直连不可达 ——
                // 用户遇到时一眼看懂是站点地址族问题，不是轻舟坏了（docs/IPV6.md）
                if state.ipv6OnlyHosts.contains(c.targetHost) {
                    Text("仅 IPv6")
                        .font(.caption2.monospaced().weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                        .help("该站点只有 IPv6 地址（无 A 记录）。轻舟为保护按域名分流走全 IPv4 链路，这类站点直连不可达；走代理时由节点解析、或可正常。详见 docs/IPV6.md")
                }
                // DNS 查询标注：一眼区分「隧道解析查询」和「用户主动访问」
                if c.isDNSQuery {
                    Text("DNS")
                        .font(.caption2.monospaced().weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.18))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
                Text(c.type.rawValue.uppercased())
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.18))
                    .clipShape(Capsule())
            }
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.swap").imageScale(.small)
                Text(L10n.lookup(c.matchedRule)).font(.caption.monospaced()).lineLimit(1)
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
