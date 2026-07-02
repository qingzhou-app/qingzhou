import SwiftUI
import QingzhouCore

/// 域名维度的分析视图：按域名 / 每日 / 优化建议三个视角看连接数据。
/// 数据源是 `AppState.connections`（隧道上报的真实连接；access log 接入前是示例数据）。
public struct DomainAnalysisView: View {
    @Bindable var state: AppState
    /// 「忽略 IP」过滤：来自 ConnectionsView 的临时状态（不持久化），两页联动。
    @Binding var hideBareIPs: Bool
    @State private var mode = 0

    public init(state: AppState, hideBareIPs: Binding<Bool>) {
        self.state = state
        self._hideBareIPs = hideBareIPs
    }

    public var body: some View {
        // 「忽略 IP」过滤（与连接页联动）：裸 IP 目标在聚合前剔除 ——
        // FakeDNS 反查不到域名的连接对域名分析没有价值。
        let connections = hideBareIPs
            ? state.connections.filter { !HostClassifier.isBareIP($0.targetHost) }
            : state.connections
        let hiddenIPCount = state.connections.count - connections.count
        // 排序/展示都用连接次数维度：接上 QueryStats 拿到真实字节前，per-连接流量恒 0，
        // 「按流量排序 + 显示 0B」是假数据。有真实字节后把 sortBy 切回 .traffic 并恢复字节列。
        let stats = DomainAnalyzer.aggregate(connections, sortBy: .connections)
        // 「每日」读按天聚合的持久化历史（跨重启、保留 30 天），不再从内存最近 200 条
        // 连接现算 —— 那是假历史。「忽略 IP」必须同样作用到这里，否则和域名 tab 数字对不上。
        let digests = state.domainHistory.digests(excludingBareIPs: hideBareIPs)
        let suggestions = DomainAnalyzer.suggestions(stats)

        List {
            Picker("", selection: $mode) {
                Text("域名").tag(0)
                Text("每日").tag(1)
                Text("建议 \(suggestions.count)").tag(2)
                // 「应用」视角只在 macOS 有：来源 App 靠 content filter 系统扩展标注，
                // iOS 拿不到进程归属（需 MDM 监督），不给一个永远空的 tab。
                #if os(macOS)
                Text("应用").tag(3)
                #endif
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            // 过滤生效时的轻提示，避免用户忘了开着过滤、以为数据少了
            if hiddenIPCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "eye.slash").imageScale(.small)
                    Text("忽略 IP：已隐藏 \(hiddenIPCount) 条纯 IP 连接")
                }
                .font(.caption2)
                .foregroundStyle(.orange)
                .listRowSeparator(.hidden)
            }

            switch mode {
            case 0:
                Section("按连接次数排序 · \(stats.count) 个域名") {
                    ForEach(stats) { domainRow($0) }
                }
            case 1:
                if digests.isEmpty {
                    ContentUnavailableView("暂无每日历史", systemImage: "calendar",
                                           description: Text("开启 VPN 浏览后，这里按天保留最近 30 天的域名访问汇总。"))
                } else {
                    ForEach(digests) { d in
                        Section {
                            ForEach(d.domains.prefix(8)) { domainRow($0) }
                            // 只展示 top 8，剩余的说明白 —— 否则行数和 header 的域名数对不上
                            if d.domains.count > 8 {
                                Text("… 还有 \(d.domains.count - 8) 个域名（按连接次数排序，仅显示前 8）")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        } header: { dailyHeader(d) }
                    }
                }
            case 2:
                if suggestions.isEmpty {
                    ContentUnavailableView("暂无优化建议", systemImage: "checkmark.seal",
                                           description: Text("当前域名的代理/直连分流看起来都合理。"))
                } else {
                    ForEach(suggestions) { suggestionRow($0) }
                }
            default:
                #if os(macOS)
                appSections(connections)
                #else
                EmptyView()
                #endif
            }
        }
        .navigationTitle("域名分析")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                IgnoreIPToggle(isOn: $hideBareIPs)
            }
        }
    }

    // MARK: - rows

    private func domainRow(_ s: DomainStat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                routeBadge(s.route)
                Text(s.domain).font(.subheadline).fontWeight(.medium).lineLimit(1)
                Spacer()
                // 流量字节在接上 QueryStats 前恒 0，不显示假 0B；先用连接次数当主指标
                Text("\(s.connectionCount) 次").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if DomainAnalyzer.isUnmatchedRule(s.lastMatchedRule) {
                    Text("未命中规则（默认策略）").font(.caption2).foregroundStyle(.orange)
                } else {
                    Text(s.lastMatchedRule).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        // 一键规则：iOS 长按/左滑，macOS 右键 →「加入直连 / 代理 / 拒绝」
        .quickRuleActions(host: s.domain, state: state)
    }

    #if os(macOS)
    // MARK: - 「应用」视角（macOS：来源 App 由内容过滤系统扩展标注）

    @ViewBuilder private func appSections(_ connections: [Connection]) -> some View {
        let appStats = DomainAnalyzer.aggregateByApp(connections)
        // 一条真实标注都没有（含完全没数据）→ 大概率没启用内容过滤扩展，给启用指引
        if appStats.allSatisfy({ $0.bundleID == nil }) {
            ContentUnavailableView {
                Label("暂无来源 App 数据", systemImage: "app.badge.checkmark")
            } description: {
                Text("按 App 查看流量需要启用「来源 App 标注」（内容过滤系统扩展）：\n"
                     + "设置 → macOS 集成 → 启用来源 App 标注，首次需在系统设置批准扩展。\n"
                     + "注意：只有启用之后建立的连接能标注来源，之前的连接无法补标。")
            }
        } else {
            ForEach(appStats) { appSection($0) }
        }
    }

    @ViewBuilder private func appSection(_ a: DomainAnalyzer.AppUsageStat) -> some View {
        Section {
            ForEach(a.domains) { domainRow($0) }
            // 只展示 top N，剩余的说明白 —— 否则行数和 header 的次数对不上
            if a.totalDomainCount > a.domains.count {
                Text("… 还有 \(a.totalDomainCount - a.domains.count) 个域名（按连接次数排序，仅显示前 \(a.domains.count)）")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        } header: {
            HStack {
                if let bid = a.bundleID {
                    SourceAppLabel(bundleID: bid)
                } else {
                    Label("未知来源", systemImage: "questionmark.app")
                    Text("· 启用过滤前的连接 / 系统流量").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(a.connectionCount) 次连接").font(.caption2)
            }
            .textCase(nil)
        }
    }
    #endif

    private func suggestionRow(_ s: RuleSuggestion) -> some View {
        let (icon, color) = badge(for: s.kind)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.domain).font(.subheadline).fontWeight(.medium)
                Text(s.reason).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func dailyHeader(_ d: DailyDigest) -> some View {
        HStack {
            Text(d.day.formatted(date: .abbreviated, time: .omitted))
            Spacer()
            // 口径：代理/直连/拒绝是**连接次数**（和行里的「N 次」同单位，三者之和 = 当天
            // 总次数）；域名数单独给。不显示 totalBytes —— 接上 QueryStats 前恒 0（假数据）。
            Text("\(d.domains.count) 个域名 · 代理 \(d.proxyCount) / 直连 \(d.directCount) / 拒绝 \(d.rejectCount) 次")
                .font(.caption2).textCase(nil)
        }
    }

    private func routeBadge(_ r: DomainRoute) -> some View {
        let info: (String, Color)
        switch r {
        case .proxy:  info = ("代理", .blue)
        case .direct: info = ("直连", .green)
        case .reject: info = ("拒绝", .red)
        case .mixed:  info = ("混合", .orange)
        }
        return Text(info.0)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(info.1.opacity(0.16), in: Capsule())
            .foregroundStyle(info.1)
    }

    private func badge(for kind: RuleSuggestion.Kind) -> (String, Color) {
        switch kind {
        case .shouldProxy:  return ("arrow.up.right.circle", .blue)
        case .shouldDirect: return ("arrow.down.right.circle", .green)
        case .unmatched:    return ("questionmark.circle", .orange)
        }
    }
}
