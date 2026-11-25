#if os(macOS)
import SwiftUI
import QingzhouCore

/// 分流方案：「国内直连、其余全走海外出口」。
///
/// 只放两个手选项 + 一个开关，不提供"自动"选项 —— 出口挂了就应该断网，
/// 任何自动择优/故障切换都会破坏这个语义（AppState 在开启期间也会跳过择优）。
struct SettingsSplitExitSection: View {
    @Bindable var state: AppState
    @Environment(\.locale) private var locale

    /// 名单查看器（sheet）。数据在打开时从 App Group 现读，避免长期占内存。
    @State private var listsForDisplay: SplitExitLists?
    @State private var showListsSheet = false
    /// 点了「查看名单内容」但磁盘上还没有文件 —— 显示原因，而不是把按钮藏起来。
    @State private var listsMissingHint = false

    var body: some View {
        Section("分流方案") {
            Toggle("国内直连、其余全走海外出口", isOn: Binding(
                get: { state.settings.splitExitEnabled },
                set: { state.setSplitExitEnabled($0) }
            ))
            if state.settings.splitExitEnabled {
                nodePicker(
                    title: "海外出口",
                    selected: state.settings.splitExitExitNodeID,
                    set: { state.setSplitExitExitNode($0) }
                )
                nodePicker(
                    title: "跳板",
                    selected: state.settings.splitExitHopNodeID,
                    set: { state.setSplitExitHopNode($0) }
                )
                if let blocked = state.splitExitBlockedReason {
                    Text(blocked).font(.caption2).foregroundStyle(.orange)
                } else {
                    Text("出口的手选节点挂了就是断网，不会自动换节点、不会回落到直连。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("出口自身的流量经「跳板」连出去；跳板不通时海外整体不通，国内直连不受影响。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("住宅 SOCKS5 的地址/端口/账号/密码请在「节点」里编辑该节点。")
                    .font(.caption2).foregroundStyle(.secondary)

                Divider()

                Toggle("跟随出口地区（全局系统时区 + 界面语言）",
                       isOn: state.setting(\.followExitRegion))
                if state.settings.followExitRegion {
                    if let region = state.exitRegion {
                        Text("出口地区：\(region.localizedSummary)")
                            .font(.caption2).foregroundStyle(.secondary)
                        if let lang = region.suggestedLanguage {
                            Text("界面语言 → \(lang.rawValue)（仅连接期间生效，不改你的语言设置）")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text("该地区没有对应的界面语言，语言保持你现在的选择。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        // 系统时区由 guard（root 常驻中继）自动改：App 通过回环 TCP 控制端口（10809）
                        // 发送分离控制凭据 AUTH + SET-TZ <IANA> / RESTORE 指令，由 root 调 systemsetup；
                        // VPN 断开后自动还原。
                        if region.timezoneID != nil {
                            Text("系统时区将自动切换为 \(region.localizedSummary)（由 guard 执行，断开 VPN 自动还原）。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("注意：需要先安装并启用 guard（见下方「断网开关」）。系统语言不自动改（需注销登录，副作用大），浏览器语言仍由浏览器自己决定。")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("连上 VPN 并拿到出口信息后显示。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Divider()

                Toggle("经 root 中继出网", isOn: state.setting(\.guardRelayEnabled))
                if state.settings.guardRelayEnabled {
                    Text("所有出站先连 127.0.0.1 的 root 中继，由它拨号。断网开关（pf 只放行 root）必须依赖这一条，否则开拦截会连代理一起拦死。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("需要先安装 guard：sudo sh Tools/qingzhou-guard/install.sh。没装时打开此项会拒绝连接并提示。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            // 国内名单：每天自动更新一次；这里给当前状态 + 手动更新入口。
            // 没拉到名单也能用（退回内置 geosite:cn / geoip:cn），所以不做成阻断项。
            HStack {
                Text(splitExitListsText)
                    .font(.caption2)
                    .foregroundStyle(state.splitExitListsStatus.error == nil ? Color.secondary : Color.orange)
                Spacer()
                Button(state.splitExitListsStatus.isLoading ? LocalizedStringKey("更新中…") : LocalizedStringKey("更新名单")) {
                    Task { await state.refreshSplitExitLists(force: true) }
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .disabled(state.splitExitListsStatus.isLoading)
            }
            // 按钮**始终可见**：之前按「已加载」隐藏，导致用户根本找不到入口
            //（名单还没下载时连提示都没有）。现在点了没文件就说明原因。
            Button {
                if let lists = SplitExitListsUpdater.loadCached(), !lists.isEmpty {
                    listsForDisplay = lists
                    showListsSheet = true
                    listsMissingHint = false
                } else {
                    listsForDisplay = nil
                    listsMissingHint = true
                }
            } label: {
                Label("查看名单内容", systemImage: "list.bullet.rectangle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            if listsMissingHint {
                Text("磁盘上还没有名单文件。先点上面的「更新名单」，成功后再看。")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .onAppear { state.loadSplitExitListsStatus() }
        .sheet(isPresented: $showListsSheet) {
            if let lists = listsForDisplay {
                SplitExitListsView(lists: lists)
            }
        }
    }

    private var splitExitListsText: String {
        let status = state.splitExitListsStatus
        if let error = status.error { return L("国内名单不可用：\(error)") }
        guard status.isLoaded else { return L("国内名单尚未下载，当前只用内置 geosite/geoip") }
        let when = status.updatedAt.map { $0.formatted(.relative(presentation: .named).locale(locale)) } ?? "—"
        // 去重后只对非 geosite:cn 余集做抽样，避免把已去重部分误算成抽样丢弃
        let effectiveSource = max(status.domainCount, status.sourceDomainCount - status.deduplicatedDomainCount)
        let domainText = effectiveSource > status.domainCount
            ? "\(status.domainCount)/\(effectiveSource)"
            : "\(status.domainCount)"
        let cidrText = status.sourceCIDRCount > status.cidrCount
            ? "\(status.cidrCount)/\(status.sourceCIDRCount)"
            : "\(status.cidrCount)"
        return L("国内名单：\(domainText) 域名 / \(cidrText) 网段（\(when)）")
    }

    /// 节点下拉：`nil` 表示未选。列表用 `id` 作 tag，重名节点也不会串。
    private func nodePicker(title: LocalizedStringKey,
                            selected: UUID?,
                            set: @escaping @MainActor (UUID?) -> Void) -> some View {
        Picker(title, selection: Binding(get: { selected }, set: set)) {
            Text("未选择").tag(UUID?.none)
            ForEach(state.splitExitCandidates) { node in
                Text("\(node.name)（\(node.protocolType.rawValue)）").tag(UUID?.some(node.id))
            }
        }
    }
}
#endif
