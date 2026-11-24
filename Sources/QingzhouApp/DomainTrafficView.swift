import SwiftUI
import QingzhouCore

/// 只读扩展写入的真实载荷账本，不把连接次数估算成流量。
struct DomainTrafficView: View {
    @Bindable var state: AppState
    @State private var monthKey = DomainTrafficLedger.monthKey(Date())
    @State private var dayKey = DomainTrafficLedger.dayKey(Date())
    @State private var period = Period.session
    @State private var route = Route.all
    @State private var order = Order.total
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private enum Period: String, CaseIterable {
        case session = "本次", daily = "日度", monthly = "月度"
    }
    private enum Route: String, CaseIterable {
        case proxy = "代理", direct = "直连", all = "全部"
        func bytes(_ row: DomainTrafficRow) -> DomainTrafficBytes {
            switch self { case .proxy: row.proxy; case .direct: row.direct; case .all: row.all }
        }
    }
    private enum Order: String, CaseIterable {
        case total = "总流量", download = "下载", upload = "上传"
        func value(_ bytes: DomainTrafficBytes) -> Int64 {
            switch self { case .total: bytes.total; case .download: bytes.download; case .upload: bytes.upload }
        }
    }
    private var month: DomainTrafficMonth? {
        guard let ledger = state.domainTrafficHistory else { return nil }
        switch period {
        case .monthly: return ledger.months[monthKey]
        case .daily: return ledger.days[dayKey]
        case .session:
            if !state.isVPNRunning { return ledger.currentSession }
            guard !state.isSwitchingTunnel,
                  let id = state.activeTrafficSessionID, ledger.vpnSessionID == id else { return nil }
            return ledger.currentSession
        }
    }
    private var days: [String] {
        Set((state.domainTrafficHistory?.days.keys.map { $0 } ?? []) + [DomainTrafficLedger.dayKey(Date()), dayKey]).sorted(by: >)
    }
    private var months: [String] {
        Set((state.domainTrafficHistory?.months.keys.map { $0 } ?? []) + [DomainTrafficLedger.monthKey(Date()), monthKey]).sorted(by: >)
    }
    private var total: DomainTrafficBytes {
        (month?.rows ?? []).reduce(into: DomainTrafficBytes()) { $0.add(route.bytes($1)) }
    }
    private var rows: [DomainTrafficRow] {
        (month?.rows ?? []).filter {
            route.bytes($0).total > 0 && (search.isEmpty || title($0.domain).localizedCaseInsensitiveContains(search))
        }.sorted {
            let a = order.value(route.bytes($0)), b = order.value(route.bytes($1))
            return a == b ? $0.domain < $1.domain : a > b
        }
    }
    private func title(_ domain: String) -> String {
        switch domain {
        case DomainTrafficLedger.unknownDomain: L("未识别域名")
        case DomainTrafficLedger.otherDomain: L("其他域名（超出记录上限）")
        default: domain
        }
    }

    var body: some View {
        List {
            Section {
                Picker("统计周期", selection: $period) {
                    ForEach(Period.allCases, id: \.self) { Text(L10n.lookup($0.rawValue)).tag($0) }
                }.pickerStyle(.segmented)
                if period == .monthly {
                    Picker("月份", selection: $monthKey) {
                        ForEach(months, id: \.self) { Text($0).tag($0) }
                    }
                } else if period == .daily {
                    Picker("日期", selection: $dayKey) {
                        ForEach(days, id: \.self) { Text($0).tag($0) }
                    }
                }
                Picker("流量范围", selection: $route) {
                    ForEach(Route.allCases, id: \.self) { Text(L10n.lookup($0.rawValue)).tag($0) }
                }.pickerStyle(.segmented)
                if period == .session, !state.isVPNRunning, month != nil {
                    Text("VPN 未连接，显示最近一次会话。").font(.footnote).foregroundStyle(.secondary)
                }
                if month != nil {
                    LabeledContent("总流量", value: ByteFormatter.format(total.total))
                    LabeledContent("上传", value: ByteFormatter.format(total.upload))
                    LabeledContent("下载", value: ByteFormatter.format(total.download))
                }
            } footer: {
                Text("仅统计这台设备经过轻舟的流量；搜索不改变上方总量。")
            }
            if state.domainTrafficReadFailed {
                Section {
                    Label("统计文件暂时无法读取，已保留原文件；下方可能是上次读取的数据。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            if state.isVPNRunning, let last = state.domainTrafficHistory?.lastObservedAt {
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    if context.date.timeIntervalSince(last) > 45 {
                        Label("记录暂未更新，当前数字可能不包含最近的流量。", systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section {
                if month == nil {
                    ContentUnavailableView("当前周期暂无流量记录", systemImage: "chart.bar", description: Text(period == .session ? L("开启 VPN 后开始记录本次流量；重新开启隧道会开始新一轮，重开主 App 不清零。") : (period == .daily ? L("从此版本开始记录日度流量，无法从月度总量补回历史每日用量。") : L("安装此版本并重新开启 VPN 后开始记录，无法补回此前的域名流量。"))))
                } else {
                    Picker("排序", selection: $order) {
                        ForEach(Order.allCases, id: \.self) { Text(L10n.lookup($0.rawValue)).tag($0) }
                    }
                    TextField("搜索域名", text: $search)
                        .textFieldStyle(.roundedBorder)
                    if rows.isEmpty {
                        Text(search.isEmpty ? L("当前范围尚未记录到流量。") : L("没有匹配的域名。"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row in
                        let bytes = route.bytes(row)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(title(row.domain)).font(.headline).textSelection(.enabled)
                                Spacer(minLength: 12)
                                Text(ByteFormatter.format(bytes.total)).monospacedDigit()
                            }
                            HStack {
                                Label(ByteFormatter.format(bytes.upload), systemImage: "arrow.up")
                                    .accessibilityLabel(L("上传") + " " + ByteFormatter.format(bytes.upload))
                                Label(ByteFormatter.format(bytes.download), systemImage: "arrow.down")
                                    .accessibilityLabel(L("下载") + " " + ByteFormatter.format(bytes.download))
                                Spacer()
                                Text((total.total > 0 ? Double(bytes.total) / Double(total.total) : 0).formatted(.percent.precision(.fractionLength(1))))
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
            } header: { Text("域名流量排行") }
            Section("记录范围与计费差异") {
                if period == .session {
                    Text("本次统计以 VPN 隧道会话为准。关闭再开启、模式或规则变更引发的隧道重启都会开始新一轮；仅重开主 App 不清零。")
                }
                if let month {
                    LabeledContent("开始记录", value: month.firstObservedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("最近更新", value: month.lastObservedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("归档时区", value: month.timeZoneIdentifier)
                }
                Text("按主域名合并，日度保留最近 31 天，月度保留最近 6 个月，仅存本机，不参与云同步。无法识别域名或超出记录上限的流量仍计入总量。")
                Text("关闭主窗口仍会记录，约每 10 秒保存一次。日期和月份按保存时的本地时间划分，跨日/月附近可能有少量偏差；隧道停止时最后数秒可能尚未保存。")
                Text("这里统计应用载荷，不等于订阅账单。节点倍率、加密封装、重传和其他设备的用量，可能让账单更高；没有经过轻舟的流量不在这里。")
            }.font(.footnote)
        }
        .navigationTitle("域名流量分析")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .task { await state.refreshDomainTrafficHistory() }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        #endif
    }
}
