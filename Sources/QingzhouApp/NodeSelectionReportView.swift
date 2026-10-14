import SwiftUI
import QingzhouCore

/// 在原生列表中按需展开；内容均为当轮证据，不跟随后来的设置或测速重算。
struct NodeSelectionReportView: View {
    let report: NodeSelectionReport
    @Environment(\.locale) private var locale
    var body: some View {
        Section("最近一次择优") {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Text(report.completedAt.formatted(.dateTime.month().day().hour().minute().locale(locale)))
                        .foregroundStyle(.secondary)
                    Text(report.origin == .manual ? L("触发方式：手动或配置恢复") : L("触发方式：自动调度"))
                    Text(profileText)
                    if let region = report.preferredRegion, report.challenger != nil {
                        Text(report.usedPreferredRegion
                             ? L("优先地区：\(region)，本轮已采用")
                             : L("优先地区：\(region)，无合格候选，使用其他地区"))
                    }
                    Text("有效排除 \(report.excludedCount) 个节点；本轮直连握手成功 \(report.directSucceeded) 个、失败 \(report.directFailed) 个")
                    if report.unmeasuredUDPCount > 0 {
                        Text("\(report.unmeasuredUDPCount) 个 UDP 节点缺少新鲜代理测量，未用 TCP 失败判定它们不可用")
                    }
                    proxyEvidence
                    if let selected = report.selected {
                        scoreEvidence(selected, title: L("当时选择"))
                    }
                    if let challenger = report.challenger, challenger.id != report.selected?.id {
                        scoreEvidence(challenger, title: L("本轮候选"))
                    }
                    switch report.reason {
                    case .insufficientLead, .confirmingLead:
                        Text("这里显示的评分偏好与节点分数用于本轮保持判断；地区记录反映候选筛选时的设置。")
                        Text("自动切换需综合分领先至少 \(Int(AppState.autoSwitchScoreMargin)) 分，并连续 \(AppState.autoSwitchScoreStreakRounds) 轮满足；当前节点无有效测量时不等待。")
                    default: EmptyView()
                    }
                    Text("这是当轮选择记录。VPN 实际使用的节点以首页连接状态为准。")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.vertical, 6)
            } label: {
                Text(report.summary).font(.subheadline)
            }
        }
    }
    private var profileText: String {
        let title: String
        switch report.profile {
        case .speed: title = L("速度优先")
        case .balanced: title = L("均衡")
        case .saver: title = L("省流量优先")
        }
        return report.prefersLowerRate ? L("择优偏好：\(title)，倍率参与评分") : L("择优偏好：\(title)，倍率不参与评分")
    }
    @ViewBuilder private var proxyEvidence: some View {
        switch report.proxy.state {
        case .notRequested: Text("本轮未进行代理精选")
        case .vpnUnavailable: Text("VPN 未运行，未进行代理精选；直连握手成功不代表出口可上网")
        case .switchInProgress: Text("VPN 正在切换，未进行代理精选")
        case .completed, .interrupted:
            Text("本轮精选 \(report.proxy.candidateCount) 个候选，含轮换探索 \(report.proxy.explorationCount) 个；最多 6 个候选及 2 次复核")
            Text("本轮代理探测 \(report.proxy.attempted) 次：成功 \(report.proxy.succeeded) 次、失败 \(report.proxy.failed) 次")
            if report.proxy.state == .interrupted { Text("代理精选中途停止") }
            if report.proxy.keptCurrentSelection { Text("未取得可用的精选结果，本轮保持原选择；出口可用性尚未确认") }
            if report.proxy.environmentFailures > 0 { Text("本轮有 \(report.proxy.environmentFailures) 次探测条件不足或被中断，未据此惩罚节点") }
            if report.proxy.configurationFailures > 0 { Text("本轮有 \(report.proxy.configurationFailures) 次节点配置转换失败") }
            if report.proxy.confirmationAttempts > 0 { Text("额外复核 \(report.proxy.confirmationAttempts) 次；双目标失败且有成功对照的节点 \(report.proxy.confirmedFailureCount) 个，暂缓自动选择 5 分钟，手动复测成功可立即恢复") }
            if report.proxy.coolingDownCount > 0 { Text("本轮暂缓探测 \(report.proxy.coolingDownCount) 个冷却中的候选") }
            if report.proxy.usedBackupTarget { Text("主目标未取得成功结果，本轮按同一备用目标的成功测量排名") }
            if report.proxy.failed > 0 { Text("探测失败可能来自节点、目标站点、网络或扩展资源限制，不能据此认定节点永久失效。") }
        }
    }
    private func scoreEvidence(_ candidate: NodeSelectionReport.Candidate, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("\(title)：\(candidate.name) · 综合评分 \(Int(candidate.score.total.rounded())) 分"))
                .fontWeight(.medium)
            Text("延迟 \(Int(candidate.score.latency.score.rounded())) · 稳定性 \(Int(candidate.score.stability.score.rounded())) · 带宽 \(Int(candidate.score.bandwidth.score.rounded())) · 成本 \(Int(candidate.score.cost.score.rounded()))")
                .monospacedDigit()
            if candidate.stabilitySampleCount < NodeScorer.minStabilitySamples { Text("稳定性样本不足，使用中性分") }
            if !candidate.hasBandwidthObservation { Text("尚无被动带宽观测，使用中性分") }
        }
    }
}
