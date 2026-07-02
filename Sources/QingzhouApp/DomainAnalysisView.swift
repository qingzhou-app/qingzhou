import SwiftUI
import QingzhouCore

/// 域名维度的分析视图：按域名 / 每日 / 优化建议三个视角看连接数据。
/// 数据源是 `AppState.connections`（隧道上报的真实连接；access log 接入前是示例数据）。
public struct DomainAnalysisView: View {
    @Bindable var state: AppState
    /// 「忽略 IP」过滤：来自 ConnectionsView 的临时状态（不持久化），两页联动。
    @Binding var hideBareIPs: Bool
    @State private var mode = 0
    /// 域名关键字搜索：作用于所有 tab（页内搜索框 —— 本页是 sheet，
    /// macOS 上 .searchable 在 sheet 的 toolbar 里没有稳定落点，页内框两平台一致）。
    @State private var keyword = ""
    #if os(macOS)
    /// 「应用」tab 是否可用 = 内容过滤扩展（来源 App 标注）当前已启用。
    /// 跟随运行时开关而不是编译期 flag —— 用户在设置里关掉标注后，这个 tab 应当消失。
    @State private var appTabAvailable = false
    #endif

    public init(state: AppState, hideBareIPs: Binding<Bool>) {
        self.state = state
        self._hideBareIPs = hideBareIPs
    }

    public var body: some View {
        // 「忽略 IP」过滤（与连接页联动）：裸 IP 目标在聚合前剔除 ——
        // FakeDNS 反查不到域名的连接对域名分析没有价值。
        let unsearched = hideBareIPs
            ? state.connections.filter { !HostClassifier.isBareIP($0.targetHost) }
            : state.connections
        let hiddenIPCount = state.connections.count - unsearched.count
        // 搜索：在连接层（聚合之前）按域名关键字过滤 —— 域名/建议/应用三个 tab 吃同一份
        // 过滤结果，口径天然一致；「每日」吃持久化 digest，用 filtered(byDomainKeyword:) 单独过。
        let kw = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        let connections = kw.isEmpty
            ? unsearched
            : unsearched.filter { $0.targetHost.lowercased().contains(kw) }
        // 排序/展示都用连接次数维度：接上 QueryStats 拿到真实字节前，per-连接流量恒 0，
        // 「按流量排序 + 显示 0B」是假数据。有真实字节后把 sortBy 切回 .traffic 并恢复字节列。
        let stats = DomainAnalyzer.aggregate(connections, sortBy: .connections)
        // 「每日」读按天聚合的持久化历史（跨重启、保留 30 天），不再从内存最近 200 条
        // 连接现算 —— 那是假历史。「忽略 IP」必须同样作用到这里，否则和域名 tab 数字对不上。
        let digests = state.domainHistory.digests(excludingBareIPs: hideBareIPs)
            .compactMap { $0.filtered(byDomainKeyword: kw) }
        let suggestions = DomainAnalyzer.suggestions(stats)

        List {
            Picker("", selection: $mode) {
                Text("域名").tag(0)
                Text("每日").tag(1)
                Text("建议 \(suggestions.count)").tag(2)
                // 「应用」视角只在 macOS 有（iOS 拿不到进程归属，需 MDM 监督）。
                // tab 常驻：来源 App 标注没开时不藏 tab，在 tab 内给开启指引 ——
                // 藏起来用户不知道有这个能力（验收反馈定的交互）。
                #if os(macOS)
                Text("应用").tag(3)
                #endif
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            // 页内搜索框：搜索体验与连接页一致（按域名关键字过滤，所有 tab 生效）
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .imageScale(.small).foregroundStyle(.secondary)
                TextField("搜索域名", text: $keyword)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.small).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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

            let searching = !kw.isEmpty
            switch mode {
            case 0:
                if stats.isEmpty && searching {
                    searchEmptyState
                } else {
                    Section("按连接次数排序 · \(stats.count) 个域名") {
                        ForEach(stats) { domainRow($0) }
                    }
                }
            case 1:
                if digests.isEmpty {
                    if searching {
                        searchEmptyState
                    } else {
                        ContentUnavailableView("暂无每日历史", systemImage: "calendar",
                                               description: Text("开启 VPN 浏览后，这里按天保留最近 30 天的域名访问汇总。"))
                    }
                } else {
                    ForEach(digests) { d in
                        Section {
                            ForEach(d.domains.prefix(8)) { domainRow($0) }
                            // 只展示 top 8，剩余的说明白 —— 否则行数和 header 的域名数对不上
                            if d.domains.count > 8 {
                                Text("… 还有 \(d.domains.count - 8) 个域名（按连接次数排序，仅显示前 8）")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        } header: { dailyHeader(d, searching: searching) }
                    }
                }
            case 2:
                // 非规则模式：分流建议没有直接行动含义（全局=全走代理、直连=全直连都是
                // 预期），顶部说明 + 条目弱化，但不吞掉数据 —— 连接可能是规则模式时期的
                // 历史，建议的事实层仍有参考价值，切回规则模式立即恢复常态显示。
                let modeNotice = Self.suggestionModeNotice(for: state.settings.proxyMode)
                if let modeNotice {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle").imageScale(.small)
                        Text(modeNotice)
                    }
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .listRowSeparator(.hidden)
                }
                if suggestions.isEmpty {
                    if searching {
                        searchEmptyState
                    } else {
                        ContentUnavailableView("暂无优化建议", systemImage: "checkmark.seal",
                                               description: Text("当前域名的代理/直连分流看起来都合理。"))
                    }
                } else {
                    ForEach(suggestions) { suggestionRow($0).opacity(modeNotice == nil ? 1 : 0.55) }
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
        #if os(macOS)
        .task {
            // 每次进入本页刷新一次开关状态（页面是 sheet，改设置必先关掉它，够新鲜）。
            // tab 常驻，这个状态只用来区分「应用」tab 的两种空态：未开启 vs 已开启但暂无数据。
            // 必须走 loadFromPreferences 的版本 —— 冷启动后直接读 isEnabled 恒 false 会误判。
            // 注：不能写 `flag && (await …)`，&& 右侧是 autoclosure，不支持 await。
            if FeatureFlags.sourceAppLabeling {
                appTabAvailable = await ContentFilterManager.loadIsEnabled()
            } else {
                appTabAvailable = false
            }
        }
        #endif
    }

    /// 非规则模式下「建议」tab 顶部的说明（nil = 规则模式，不需要说明）。
    /// 全局/直连模式不吃分流规则，「国内域名走了代理」这类建议是预期行为而非问题，
    /// 不说明会误导（真实验收反馈）。static 纯函数，单测直接断言文案语义。
    static func suggestionModeNotice(for mode: ProxyMode) -> String? {
        switch mode {
        case .rule:   return nil
        case .global: return "全局模式下所有流量都走代理，分流建议仅供参考（切回规则模式后可按建议行动）"
        case .direct: return "直连模式下所有流量都直连，分流建议仅供参考（切回规则模式后可按建议行动）"
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
        // 标注未开启：给开启指引（tab 常驻的代价是要在这里把「为什么没数据」说明白）。
        // 优先级最高 —— 没开标注时搜索/数据状态都没意义。
        // 不放「直达设置」按钮：设置页在主窗口导航里，本页是模态 sheet，跳转需要
        // 关 sheet + 全局导航状态联动，改动面大于收益，指引文案已足够找到入口。
        if !appTabAvailable {
            ContentUnavailableView {
                Label("来源 App 标注未开启", systemImage: "app.dashed")
            } description: {
                Text("开启后这里会按 App 分组展示各自访问的域名与连接次数。\n"
                     + "入口：设置 → macOS 集成 → 启用来源 App 标注（首次需在系统设置批准扩展）。")
            }
        }
        // 搜索无结果时明确说「是搜索导致的空」——下面的「暂无来源 App 数据」会误导
        else if appStats.isEmpty && !keyword.trimmingCharacters(in: .whitespaces).isEmpty {
            searchEmptyState
        }
        // 已开启但还没标注到任何连接（含完全没数据）
        else if appStats.allSatisfy({ $0.bundleID == nil }) {
            ContentUnavailableView {
                Label("暂无来源 App 数据", systemImage: "app.badge.checkmark")
            } description: {
                Text("「来源 App 标注」已启用，还没有可归属的连接。\n"
                     + "确认 VPN 已开启并浏览一会儿；启用标注之前建立的连接无法补标。")
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

    private func dailyHeader(_ d: DailyDigest, searching: Bool) -> some View {
        HStack {
            Text(d.day.formatted(date: .abbreviated, time: .omitted))
            Spacer()
            if searching {
                // 搜索态：domains 已被关键字过滤，代理/直连/拒绝的全天次数和行数对不上，
                // 只报匹配数（口径对账的老教训，别混着显示）
                Text("匹配 \(d.domains.count) 个域名")
                    .font(.caption2).textCase(nil)
            } else {
                // 口径：代理/直连/拒绝是**连接次数**（和行里的「N 次」同单位，三者之和 = 当天
                // 总次数）；域名数单独给。不显示 totalBytes —— 接上 QueryStats 前恒 0（假数据）。
                Text("\(d.domains.count) 个域名 · 代理 \(d.proxyCount) / 直连 \(d.directCount) / 拒绝 \(d.rejectCount) 次")
                    .font(.caption2).textCase(nil)
            }
        }
    }

    /// 搜索无结果的空态：和连接页一样明确说「是搜索导致的空」，别让用户以为没数据。
    private var searchEmptyState: some View {
        ContentUnavailableView.search(text: keyword)
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
