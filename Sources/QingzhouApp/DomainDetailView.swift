import SwiftUI
import QingzhouCore

/// 单个主域名的趋势详情页（域名分析 sheet 内 push）：
/// 最近 7 天连接次数柱状图（数据源 DomainDailyHistory）+ 路由/规则信息 + 一键规则。
///
/// 柱状图取舍：手绘 Capsule 柱而不是引 SwiftUI Charts —— 7 根柱的迷你图不值得引框架，
/// 且 Capsule/次要色的风格和首页流量波形、状态胶囊一致。单序列不配图例（标题即说明），
/// 数值与星期标签用文本色（primary/secondary），柱身才用强调色。
struct DomainDetailView: View {
    @Bindable var state: AppState
    let stat: DomainStat

    var body: some View {
        List {
            Section("最近 7 天连接次数") {
                trendChart
            }

            Section("路由 / 规则") {
                LabeledContent("当前路由") { routeBadge(stat.route) }
                if TrackerDomains.isTracker(stat.domain) {
                    LabeledContent("类别") {
                        Text("追踪器")
                            .font(.caption).fontWeight(.medium)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(DomainAnalysisView.trackerColor.opacity(0.16), in: Capsule())
                            .foregroundStyle(DomainAnalysisView.trackerColor)
                    }
                }
                LabeledContent("命中规则") {
                    if DomainAnalyzer.isUnmatchedRule(stat.lastMatchedRule) {
                        Text("未命中规则（默认策略）").foregroundStyle(.orange)
                    } else {
                        Text(stat.lastMatchedRule)
                            .font(.caption.monospaced())
                            .lineLimit(2).truncationMode(.middle)
                    }
                }
                LabeledContent("连接次数", value: "\(stat.connectionCount) 次")
                LabeledContent("首次出现", value: stat.firstSeen.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("最近出现", value: stat.lastSeen.formatted(date: .abbreviated, time: .shortened))
            }

            Section("一键规则") {
                HStack(spacing: 10) {
                    quickButton("直连", .green, .direct)
                    quickButton("代理", .blue, .proxy)
                    quickButton("拒绝", .red, .reject)
                }
                Text("为 \(stat.domain) 添加 DOMAIN-SUFFIX 规则（覆盖全部子域名），VPN 运行中立即生效。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(stat.domain)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - 7 天趋势柱状图（手绘）

    private var trendChart: some View {
        let counts = state.domainHistory.dailyCounts(domain: stat.domain)
        let maxCount = counts.map(\.count).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            if maxCount == 0 {
                // 全 0：直说没有历史，别画一排空柱让人猜
                Text("窗口内暂无按天历史（历史按天聚合、保留 30 天，重启后累计）")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(counts) { dc in
                        VStack(spacing: 3) {
                            // 数值标签：文本色不用序列色；0 不标（省视觉噪音）
                            Text(dc.count > 0 ? "\(dc.count)" : " ")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            barBody(count: dc.count, maxCount: maxCount)
                            Text(Self.dayLabel(dc.day))
                                .font(.caption2)
                                .foregroundStyle(Calendar.current.isDateInToday(dc.day)
                                                 ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 130)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func barBody(count: Int, maxCount: Int) -> some View {
        GeometryReader { geo in
            let h = count == 0 ? 3 : max(8, geo.size.height * CGFloat(count) / CGFloat(maxCount))
            VStack {
                Spacer(minLength: 0)
                Capsule()
                    .fill(count == 0 ? AnyShapeStyle(Color.secondary.opacity(0.18))
                                     : AnyShapeStyle(Color.accentColor.opacity(0.85)))
                    .frame(width: 12, height: h)
                    .frame(maxWidth: .infinity)   // 柱居中
            }
        }
    }

    /// 柱下标签：今天标「今天」，其余标 M/d（7 天窗口里星期几不如日期直观）。
    static func dayLabel(_ day: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "今天" }
        let c = calendar.dateComponents([.month, .day], from: day)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    // MARK: - 部件

    private func quickButton(_ title: String, _ color: Color, _ target: RuleTarget) -> some View {
        Button(title) { state.quickAddDomainRule(forHost: stat.domain, target: target) }
            .buttonStyle(.bordered)
            .tint(color)
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
            .font(.caption).fontWeight(.medium)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(info.1.opacity(0.16), in: Capsule())
            .foregroundStyle(info.1)
    }
}
