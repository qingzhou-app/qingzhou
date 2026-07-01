import SwiftUI
import VPNCore

/// 域名维度的分析视图：按域名 / 每日 / 优化建议三个视角看连接数据。
/// 数据源是 `AppState.connections`（隧道上报的真实连接；access log 接入前是示例数据）。
public struct DomainAnalysisView: View {
    @Bindable var state: AppState
    @State private var mode = 0

    public init(state: AppState) { self.state = state }

    public var body: some View {
        let connections = state.connections
        let stats = DomainAnalyzer.aggregate(connections)
        let digests = DomainAnalyzer.daily(connections)
        let suggestions = DomainAnalyzer.suggestions(stats)

        List {
            Picker("", selection: $mode) {
                Text("域名").tag(0)
                Text("每日").tag(1)
                Text("建议 \(suggestions.count)").tag(2)
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            switch mode {
            case 0:
                Section("按流量排序 · \(stats.count) 个域名") {
                    ForEach(stats) { domainRow($0) }
                }
            case 1:
                ForEach(digests) { d in
                    Section { ForEach(d.domains.prefix(8)) { domainRow($0) } } header: { dailyHeader(d) }
                }
            default:
                if suggestions.isEmpty {
                    ContentUnavailableView("暂无优化建议", systemImage: "checkmark.seal",
                                           description: Text("当前域名的代理/直连分流看起来都合理。"))
                } else {
                    ForEach(suggestions) { suggestionRow($0) }
                }
            }
        }
        .navigationTitle("域名分析")
    }

    // MARK: - rows

    private func domainRow(_ s: DomainStat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                routeBadge(s.route)
                Text(s.domain).font(.subheadline).fontWeight(.medium).lineLimit(1)
                Spacer()
                Text(ByteFormatter.format(s.totalBytes)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("\(s.connectionCount) 次").font(.caption2).foregroundStyle(.secondary)
                if s.lastMatchedRule.isEmpty {
                    Text("未命中规则").font(.caption2).foregroundStyle(.orange)
                } else {
                    Text(s.lastMatchedRule).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

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
            Text("代理 \(d.proxyCount) · 直连 \(d.directCount) · 拒绝 \(d.rejectCount) · \(ByteFormatter.format(d.totalBytes))")
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
