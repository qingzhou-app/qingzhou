import SwiftUI
import QingzhouCore
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

public struct SettingsView: View {
    @Bindable var state: AppState
    /// 跟随 App 语言设置的 locale（根视图注入），日期/相对时间格式化用
    @Environment(\.locale) private var locale
    @State private var filterEnabled = false
    /// 名单查看器（sheet）。数据在打开时从 App Group 现读，避免长期占内存。
    @State private var listsForDisplay: SplitExitLists?
    @State private var showListsSheet = false
    /// 点了「查看名单内容」但磁盘上还没有文件 —— 显示原因，而不是把按钮藏起来。
    @State private var listsMissingHint = false
    /// 断网开关的安装/拦截状态（命令面板展示用）。每次进页刷新一次。
    @State private var guardStatus: GuardStatus = .checking

    public init(state: AppState) { self.state = state }

    public var body: some View {
        Form {
            proxySection
            splitExitSection
            guardSection
            autoSelectSection
            regionSection
            appearanceSection
            ruleSourceSection
            geoDataSection
            #if os(macOS)
            macIntegrationSection
            #endif
            iCloudSection
            diagnosticsSection
            aboutSection
        }
        // 语言切换时强制整页重建：iOS 的 Form 是 UICollectionView，cell 复用会让个别
        // 收起态 Picker 的**值文案**（L() 预解析的 String）残留旧语种（真机踩过：
        // 切 English 后「定时关闭」的值仍显示「关闭」）。静态 Text 靠 \.locale 环境值
        // 自动刷新不受影响，但 String 值内容不变时 cell 未必重渲染 —— id 直接换树。
        .id(state.settings.language)
        .onAppear { refreshGuardStatus() }
        .navigationTitle(AppSection.settings.localizedTitle(language: state.settings.language))
        .formStyle(.grouped)
        // 「立即恢复」的版本选择 sheet。两条呈现纪律（复验 #18 两轮打回换来的）：
        // 1. 挂在 Form 顶层，**不要挂进 Section** —— iOS 的 Form 是惰性容器（UICollectionView），
        //    cell 重渲染会重建 hosting view，呈现动画中的 sheet 会被连带 dismiss（弹出即沉）。
        // 2. isPresented 只依赖专用稳定 Bool —— 加载态 .loading→.loaded 落在呈现动画中，
        //    binding 若依赖它，mid-transition 重渲染同样会打断呈现。
        // onDismiss：sheet 完全收起后才把点选的候选交给确认 alert（挂在 RootView）——
        // 收起动画中就置 cloudRestoreOffer 会撞呈现层，alert 被吞掉。
        .sheet(isPresented: cloudVersionSheetBinding, onDismiss: {
            state.presentPendingCloudRestoreOffer()
        }) {
            cloudVersionPicker
        }
        .sheet(isPresented: $showListsSheet) {
            if let lists = listsForDisplay {
                SplitExitListsView(lists: lists)
            }
        }
    }

    /// 诊断：隧道扩展进程的内存水位。iOS 对 NE 扩展有 50MB jetsam 硬上限，超限即"断流"——
    /// 高速测速 / 大流量下载是竞品翻车的典型场景，这里给用户/开发者一个随时可查的数字。
    ///
    /// 用 TimelineView **每秒自驱动重算**，不依赖任何数据变更就能走字 —— 于是
    /// 「上次采样：N 秒前」这行读数把故障环节一劈两半：秒数持续增大 = 扩展没在写
    /// （旧扩展进程没换新代码 / 写入失败）；秒数一直 ≤2 秒但数字不动 = 不可能
    /// （数字和采样时间在同一个文件里）。「扩展尚未上报」= 文件根本不存在。
    private var diagnosticsSection: some View {
        Section("诊断") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let mem = state.tunnelMemory {
                    let age = context.date.timeIntervalSince(mem.sampledAt)
                    let live = age <= 3
                    // footprint==0 && error != nil = 扩展在写但采样失败 —— 显示失败而不是"0 B"
                    let samplingFailed = mem.footprintBytes <= 0 && mem.error != nil
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("扩展内存", value: live
                            ? (samplingFailed
                               ? L("采样失败")
                               : L("\(ByteFormatter.format(mem.footprintBytes)) · 峰值 \(ByteFormatter.format(mem.sessionPeakBytes))"))
                            : L("未在上报"))
                        Text(live && !samplingFailed
                            ? memoryCaption(mem)
                            : idleMemoryCaption(mem))
                            .font(.caption2)
                            .foregroundStyle(live && mem.warningCount > 0 ? .orange : .secondary)
                        // 采样诊断（扩展带出的失败/降级原因）—— 用户截图这一行就能远程定位
                        if let err = mem.error {
                            Text("采样诊断：\(err)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.orange)
                        }
                        Text("上次采样：\(Self.ageText(age))")
                            .font(.caption2)
                            .foregroundStyle(live ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("扩展内存", value: L("暂无数据"))
                        Text("扩展尚未上报 —— 需 VPN 处于开启状态，且隧道扩展为最新版本（更新 App 后要关-开一次 VPN，运行中的旧扩展进程才会换成新代码）。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            #if os(iOS)
            // iOS tab 收敛到 5 个后「日志」不再占 tab，从这里 push 进去（macOS 侧栏有独立项）
            NavigationLink {
                LogsView(state: state)
            } label: {
                Label("日志", systemImage: "doc.text.magnifyingglass")
            }
            #endif
        }
    }

    /// 「上次采样」的人话时间差。负值（时钟偏差）并进"刚刚"。
    static func ageText(_ age: TimeInterval) -> String {
        if age < 2 { return L("刚刚") }
        if age < 60 { return L("\(Int(age)) 秒前") }
        if age < 3600 { return L("\(Int(age / 60)) 分钟前") }
        return L("\(Int(age / 3600)) 小时前")
    }

    private func memoryCaption(_ mem: TunnelMemoryStats) -> String {
        var parts: [String] = []
        if mem.limitBytes > 0 {
            let headroom = max(0, mem.limitBytes - mem.footprintBytes)
            parts.append(L("距 \(ByteFormatter.format(mem.limitBytes)) 上限余 \(ByteFormatter.format(headroom))"))
        } else {
            // macOS：NE 扩展没有 iOS 那条 50MB jetsam 硬上限，如实说，别让人找"余量"
            parts.append(L("无硬性内存上限"))
        }
        parts.append(L("历史最高 \(ByteFormatter.format(mem.allTimePeakBytes))"))
        if mem.warningCount > 0 {
            parts.append(L("本次会话越过 40 MB 告警线 \(mem.warningCount) 次"))
        }
        return parts.joined(separator: " · ")
    }

    /// 扩展没有实时上报时的内存说明行（上次会话峰值 + 历史最高 + 可选上限）。
    private func idleMemoryCaption(_ mem: TunnelMemoryStats) -> String {
        var line = L("上次会话峰值 \(ByteFormatter.format(mem.sessionPeakBytes)) · 历史最高 \(ByteFormatter.format(mem.allTimePeakBytes))")
        if mem.limitBytes > 0 {
            line += L("（上限 \(ByteFormatter.format(mem.limitBytes))）")
        }
        return line
    }

    private var proxySection: some View {
        Section("代理") {
            Picker("代理模式", selection: state.proxyModeBinding) {
                ForEach(ProxyMode.allCases, id: \.self) { m in
                    Text(label(for: m)).tag(m)
                }
            }
            Text("全程走虚拟网卡（TUN），整机流量自动经隧道转发，无需配置系统代理。")
                .font(.caption2).foregroundStyle(.secondary)
            Picker("阻断 QUIC", selection: state.quicPolicyBinding) {
                Text("自动").tag(QUICPolicy.auto)
                Text("强制开启").tag(QUICPolicy.alwaysBlock)
                Text("强制关闭").tag(QUICPolicy.neverBlock)
            }
            Text("自动：hysteria2 节点放行并实测，其余挡 QUIC 走 TCP")
                .font(.caption2).foregroundStyle(.secondary)
            // 当前 QUIC 运行态（隧道开着才显示）—— auto 档的「放行→实测→通过/改挡」过程
            // 从此在真机上可见，不再是黑箱。状态推导是 QingzhouCore 纯函数，见 docs/QUIC.md §9。
            if let quicStatus = state.quicRuntimeStatus {
                Text(Self.quicStatusText(quicStatus))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Picker("日志级别", selection: state.setting(\.logLevel)) {
                Text("DEBUG").tag("DEBUG")
                Text("INFO").tag("INFO")
                Text("WARN").tag("WARN")
                Text("ERROR").tag("ERROR")
            }
        }
    }

    /// 分流方案：「国内直连、其余全走海外出口」。
    ///
    /// 只放两个手选项 + 一个开关，不提供"自动"选项 —— 出口挂了就应该断网，
    /// 任何自动择优/故障切换都会破坏这个语义（AppState 在开启期间也会跳过择优）。
    private var splitExitSection: some View {
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
                        Text("出口地区：\(region.summary)")
                            .font(.caption2).foregroundStyle(.secondary)
                        if let lang = region.suggestedLanguage {
                            Text("界面语言 → \(lang.rawValue)（仅连接期间生效，不改你的语言设置）")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text("该地区没有对应的界面语言，语言保持你现在的选择。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        // 系统时区现在由 guard（root 常驻进程）自动改：App 写指令到
                        // App Group，guard 每 10 秒读一次并调 systemsetup。断开自动还原。
                        if region.timezoneID != nil {
                            Text("系统时区将自动切换为 \(region.summary)（由 guard 执行，断开 VPN 自动还原）。")
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
                Button(state.splitExitListsStatus.isLoading ? "更新中…" : "更新名单") {
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
    }

    /// 断网开关：命令面板。root 操作没法在 App 内完成（sudo 密码框不允许预填），
    /// 所以把命令摆出来让用户一键复制、到终端粘贴执行，并显示当前状态。
    private var guardSection: some View {
        Group {
            Section {
                statusRow("已安装（中继 + 守护进程）", ok: guardStatus.installed)
                statusRow("拦截已启用", ok: guardStatus.enabled)
                statusRow("中继在监听 10808", ok: guardStatus.relayListening)

                if !guardStatus.installed {
                    Text("尚未安装。先装 guard，再配分流 + 「经 root 中继出网」，确认能上网后开拦截。")
                        .font(.caption2).foregroundStyle(.orange)
                }
            } header: {
                Text("断网开关")
            } footer: {
                Text("以下命令需要 root（sudo）。App 无法代替你敲密码，请点「复制」后到终端粘贴执行。")
            }

            Section("命令（复制到终端执行）") {
                commandRow("安装 guard（只装不拦）", cmd: guardInstallCommand, danger: false)
                commandRow("启用拦截", cmd: guardEnableCommand, danger: false)
                commandRow("解除拦截（断网时急救）", cmd: guardOffCommand, danger: true)
                commandRow("彻底卸载", cmd: guardUninstallCommand, danger: false)
            }
        }
    }

    /// 断网开关的运行状态（命令面板展示）。检测只读、不触发任何 root 操作。
    private struct GuardStatus {
        var installed = false
        var enabled = false
        var relayListening = false
        static let checking = GuardStatus()
    }

    /// 只读检测断网开关三态：装没装（目录+守护进程）、开没开（enabled 标记）、
    /// 中继在不在听（127.0.0.1:10808）。不做任何特权操作。
    private func refreshGuardStatus() {
        var s = GuardStatus()
        let base = "/Library/Application Support/qingzhou-guard"
        let fm = FileManager.default
        s.installed = fm.fileExists(atPath: base + "/qingzhou-relay")
            && fm.fileExists(atPath: "/Library/LaunchDaemons/com.sbraveyoung.qingzhou.guard.plist")
        s.enabled = fm.fileExists(atPath: base + "/enabled")
        // 探测 10808 是否在听（不产生副作用，连上就关）
        s.relayListening = Self.isPortOpen(10808)
        guardStatus = s
    }

    private static func isPortOpen(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                connect(sock, sap, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }

    private func statusRow(_ title: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            Text(title).font(.caption)
            Spacer()
        }
    }

    private func commandRow(_ title: String, cmd: String, danger: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).fontWeight(.medium)
            Text(cmd)
                .font(.caption2.monospaced())
                .foregroundStyle(danger ? Color.red : Color.secondary)
                .textSelection(.enabled)
            Button {
                copyGuardCommand(cmd)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
        }
    }

    private func copyGuardCommand(_ cmd: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        #else
        UIPasteboard.general.string = cmd
        #endif
    }

    private static let guardBase = "/Library/Application Support/qingzhou-guard"

    private var guardInstallCommand: String {
        "sudo sh \"/Library/Application Support/qingzhou-guard/install.sh\""
    }
    private var guardEnableCommand: String {
        "sudo sh \"/Library/Application Support/qingzhou-guard/enable.sh\""
    }
    private var guardOffCommand: String {
        "sudo sh \"/Library/Application Support/qingzhou-guard/off.sh\""
    }
    private var guardUninstallCommand: String {
        "sudo sh \"/Library/Application Support/qingzhou-guard/uninstall.sh\""
    }

    private var splitExitListsText: String {
        let status = state.splitExitListsStatus
        if let error = status.error { return L("国内名单不可用：\(error)") }
        guard status.isLoaded else { return L("国内名单尚未下载，当前只用内置 geosite/geoip") }
        let when = status.updatedAt.map { $0.formatted(.relative(presentation: .named).locale(locale)) } ?? "—"
        // 截断后要显示「实收/源总数」，否则用户会以为 11 万条全生效了
        let domainText = status.sourceDomainCount > status.domainCount
            ? "\(status.domainCount)/\(status.sourceDomainCount)"
            : "\(status.domainCount)"
        let cidrText = status.sourceCIDRCount > status.cidrCount
            ? "\(status.cidrCount)/\(status.sourceCIDRCount)"
            : "\(status.cidrCount)"
        return L("国内名单：\(domainText) 域名 / \(cidrText) 网段（\(when)）")
    }

    /// 节点下拉：`nil` 表示未选。列表用 `id` 作 tag，重名节点也不会串。
    private func nodePicker(title: LocalizedStringKey,
                            selected: UUID?,
                            set: @escaping @Sendable (UUID?) -> Void) -> some View {
        Picker(title, selection: Binding(get: { selected }, set: set)) {
            Text("未选择").tag(UUID?.none)
            ForEach(state.splitExitCandidates) { node in
                Text("\(node.name)（\(node.protocolType.rawValue)）").tag(UUID?.some(node.id))
            }
        }
    }

    /// QUIC 运行态 → 状态行文案。状态推导在 QingzhouCore（纯函数、有单测），这里只做文案映射。
    static func quicStatusText(_ status: QUICRuntimeStatus) -> String {
        switch status {
        case .forcedBlock:         return L("当前：已阻断 QUIC（策略强制开启）")
        case .forcedAllow:         return L("当前：放行 QUIC（策略强制关闭）")
        case .autoBlockedTCPBased: return L("当前：已阻断 QUIC（TCP 系协议节点）")
        case .autoProbing:         return L("当前：暂放行 QUIC，HTTP/3 实测中…")
        case .autoProbePassed:     return L("当前：放行 QUIC（HTTP/3 实测通过）")
        case .autoBrokenBlocked:   return L("当前：已阻断 QUIC（实测不通，已自动改挡）")
        }
    }

    private var autoSelectSection: some View {
        Section("自动化") {
            // 自动测速：周期性刷延迟列，不改 currentNodeId
            Picker("自动测速", selection: state.setting(\.autoMeasureIntervalSeconds)) {
                Text("关闭").tag(TimeInterval(0))
                Text("15 分钟").tag(TimeInterval(15 * 60))
                Text("30 分钟").tag(TimeInterval(30 * 60))
                Text("1 小时").tag(TimeInterval(60 * 60))
                Text("6 小时").tag(TimeInterval(6 * 60 * 60))
            }
            Text("只刷新延迟数据，不会自动切换当前节点。")
                .font(.caption2).foregroundStyle(.secondary)

            // 自动择优：测速 + 自动切节点
            Picker("自动择优时机", selection: state.setting(\.autoSelectTrigger)) {
                Text("启动时").tag(AutoSelectTrigger.onAppLaunch)
                Text("定时").tag(AutoSelectTrigger.interval)
                Text("启动 + 定时").tag(AutoSelectTrigger.onAppLaunchAndInterval)
                Text("关闭").tag(AutoSelectTrigger.off)
            }
            // 固定档位 Picker，样式与上面「自动测速」一致（label 左、值右）。
            // 旧版是 Stepper（任意分钟值），binding 的 get 里做就近回退，
            // 保证 Picker 永远有合法选中项；用户不动它就不改写已存的旧值。
            Picker("择优间隔", selection: autoSelectIntervalBinding) {
                Text("5 分钟").tag(TimeInterval(5 * 60))
                Text("15 分钟").tag(TimeInterval(15 * 60))
                Text("30 分钟").tag(TimeInterval(30 * 60))
                Text("1 小时").tag(TimeInterval(60 * 60))
                Text("6 小时").tag(TimeInterval(6 * 60 * 60))
                Text("24 小时").tag(TimeInterval(24 * 60 * 60))
            }
            Text("开启后按地区偏好与综合评分自动择优。正常切换需连续两轮领先；若希望保留手选节点，请关闭自动择优。")
                .font(.caption2).foregroundStyle(.secondary)

            Toggle("择优用经代理延迟精选", isOn: Binding(
                get: { state.settings.autoSelectUsesProxiedLatency },
                set: { state.setAutoSelectUsesProxiedLatency($0) }
            ))
            Text("VPN 运行中，每轮最多对 6 个候选做真实代理测量，并可额外复核 2 次；包含当前节点、可用 TCP 候选及 UDP 节点。未确认可用时保留当前选择。自动测速仍只测直连，关闭本开关会清空经代理延迟。")
                .font(.caption2).foregroundStyle(.secondary)

            Picker("择优偏好", selection: state.setting(\.scoringProfile)) {
                Text("速度优先").tag(ScoringProfile.speed)
                Text("均衡").tag(ScoringProfile.balanced)
                Text("省流量").tag(ScoringProfile.saver)
            }
            Text("按延迟、稳定性、近期下载观测与成本综合评分。速度优先更看重延迟；均衡兼顾四项；省流量更看重低倍率。改选下轮择优生效。")
                .font(.caption2).foregroundStyle(.secondary)

            Toggle("延迟接近时优先低倍率", isOn: state.setting(\.preferLowerRate))
            Text("自动择优时，若几个节点延迟差不多，优先选倍率低的（更省流量）。倍率从节点名 / 订阅元数据识别，非 1 倍会在节点上标出（0.5x 绿、2x 橙）。")
                .font(.caption2).foregroundStyle(.secondary)

            // 节点故障提醒（健康触发的故障切换，opt-in，默认关）。受编译期总开关约束。
            if FeatureFlags.autoFailoverAlert {
                Toggle("节点故障提醒", isOn: state.setting(\.autoFailoverAlert))
                Text("当前节点疑似故障（代理上行还在发、下行却没有回流）时发通知提醒你，首页显示一键「切换到最优节点」。开启后会请求通知权限。只提醒不自动切换，不影响正常上网。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Picker("测速探测目标", selection: proxiedTargetBinding) {
                Text("自动（Cloudflare，最稳）").tag("")
                ForEach(ConnectivityProbe.presets) { t in
                    Text(t.name).tag(t.url)
                }
            }
            Text("经代理测速和「已连接但无法上网」检测用哪个站点探测。有些节点出口对 Google 会 reset —— 默认用 Cloudflare 更稳。改这里也影响连通性提示的判定。")
                .font(.caption2).foregroundStyle(.secondary)

            NavigationLink {
                AutomationGuideView()
            } label: {
                Label("自动化玩法指南", systemImage: "sparkles")
            }
            Text("快捷指令 / Siri / 打开某 App 自动连 / 小组件 —— 全部配方一页看懂。")
                .font(.caption2).foregroundStyle(.secondary)

            Picker("订阅自动刷新", selection: state.setting(\.subscriptionRefreshIntervalSeconds)) {
                Text("关闭").tag(TimeInterval(0))
                Text("15 分钟").tag(TimeInterval(15 * 60))
                Text("30 分钟").tag(TimeInterval(30 * 60))
                Text("1 小时").tag(TimeInterval(60 * 60))
                Text("6 小时").tag(TimeInterval(6 * 60 * 60))
                Text("24 小时").tag(TimeInterval(24 * 60 * 60))
            }

            // 定时关闭（防忘关）：档位样式与「择优间隔」一致。倒计时在隧道扩展进程里生效，
            // 主 App 被系统回收也照样到点断开。DEBUG 构建带 1 分钟调试档。
            Picker("定时关闭", selection: autoStopBinding) {
                ForEach(AutoStopPresets.values, id: \.self) { v in
                    Text(AutoStopPresets.label(for: v)).tag(v)
                }
            }
            Text("到点自动断开 VPN，只对本次连接生效 —— 断开后不会自动重连，手动重开会重新计时。VPN 运行中修改会立即从现在起重新计时。注意：启用定时的连接不开启系统自动重连（On-Demand），若扩展异常退出需手动重开。")
                .font(.caption2).foregroundStyle(.secondary)

            #if os(iOS)
            Toggle("显示灵动岛实时活动", isOn: state.setting(\.showLiveActivity))
            Text("连接期间在灵动岛 / 锁屏显示实时活动：连接状态、已连时长、实时上下行速率。关掉后不再显示。若系统「设置 → 面容 ID 与密码 / 实时活动」里全局关了实时活动，这里开也不会出现。")
                .font(.caption2).foregroundStyle(.secondary)
            #endif

            // 专注模式（Focus）联动：过滤器在系统「设置 → 专注模式」里配置，App 内无法代配
            // （Apple 安全设计，同「打开某 App 自动连」）—— 这里只给一句说明引导。
            Label("专注模式联动", systemImage: "moon.fill")
                .font(.subheadline.weight(.semibold))
            Text("在系统「设置 → 专注模式 → 选一个专注 → 添加过滤器 → 轻舟」里，可让该专注开启时自动「连接 / 断开」VPN（例：工作专注自动连、睡眠专注自动断）。专注切换时在后台生效，无需打开轻舟。")
                .font(.caption2).foregroundStyle(.secondary)

            Text("当前节点：\(state.currentNode?.name ?? L("未选"))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var regionSection: some View {
        Section {
            let regions = state.regionCounts
            if regions.isEmpty {
                Text("还没有节点，添加订阅后这里会列出各地区。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // 优先地区
                Picker("优先地区", selection: state.setting(\.preferredRegion)) {
                    Text("无（按综合评分）").tag(String?.none)
                    ForEach(regions, id: \.region) { item in
                        Text(L10n.lookup(item.region)).tag(String?.some(item.region))
                    }
                }
                Text("优先地区有符合条件的候选时，在该地区内按综合评分选择；否则在所有符合条件的候选中选择。")
                    .font(.caption2).foregroundStyle(.secondary)

                // 地区排除列表
                ForEach(regions, id: \.region) { item in
                    Toggle(isOn: regionExcludedBinding(item.region)) {
                        HStack {
                            Text(L10n.lookup(item.region))
                            Text("\(item.count) 个节点")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel(Text(L10n.lookup(item.region)))
                    .accessibilityHint(Text("\(item.count) 个节点；开启后排除此地区"))
                }
                Text("打开开关 = 排除该地区的所有节点（不参与自动择优、不会被自动选中）。例如排除「香港」以避开 Anthropic / OpenAI 等对香港 IP 的限制。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text("地区")
        }
    }

    /// 「择优间隔」的 Binding：读取时把旧版 Stepper 存下的任意值就近吸附到固定档位
    /// （见 `AutoSelectIntervalPresets.nearest`），写入时按用户所选档位持久化。
    private var autoSelectIntervalBinding: Binding<TimeInterval> {
        let raw = state.setting(\.autoSelectIntervalSeconds)
        return Binding(
            get: { AutoSelectIntervalPresets.nearest(to: raw.wrappedValue) },
            set: { raw.wrappedValue = $0 }
        )
    }

    /// 「定时关闭」的 Binding：读取时把任意存量值（iCloud 同步来的等）就近吸附到档位；
    /// 写入走 AppState.setAutoStopSeconds —— VPN 运行中改档会热生效（重新计时），不只是存值。
    private var autoStopBinding: Binding<TimeInterval> {
        Binding(
            get: { AutoStopPresets.nearest(to: state.settings.autoStopSeconds) },
            set: { state.setAutoStopSeconds($0) }
        )
    }

    /// 「测速探测目标」Binding：存量值不在预设列表里（旧自定义 / 同步来的）→ get 归一成「自动」，
    /// 保证 Picker 永远有合法选中项（否则 iOS Picker 会显示空白）。
    private var proxiedTargetBinding: Binding<String> {
        let raw = state.setting(\.proxiedTestTarget)
        let known = Set(ConnectivityProbe.presets.map(\.url))
        return Binding(
            get: { known.contains(raw.wrappedValue) ? raw.wrappedValue : "" },
            set: { raw.wrappedValue = $0 }
        )
    }

    /// 某地区是否被排除的 Binding（toggle）。
    private func regionExcludedBinding(_ region: String) -> Binding<Bool> {
        Binding(
            get: { state.settings.excludedRegions.contains(region) },
            set: { _ in state.toggleRegionExclusion(region) }
        )
    }

    private var appearanceSection: some View {
        Section("外观") {
            Picker("主题", selection: state.setting(\.theme)) {
                Text("跟随系统").tag(AppearanceTheme.system)
                Text("浅色").tag(AppearanceTheme.light)
                Text("深色").tag(AppearanceTheme.dark)
            }
            // 已放出的语种（E.18 补齐繁中 / 日语翻译）。每种语言的 Text 用其母语自称，
            // 不随当前界面语言变化（惯例：语言选择项永远显示各自的原生名）。
            Picker("语言", selection: state.setting(\.language)) {
                Text("简体中文").tag(AppLanguage.zhHans)
                Text("繁體中文").tag(AppLanguage.zhHant)
                Text("English").tag(AppLanguage.en)
                Text("日本語").tag(AppLanguage.ja)
            }
        }
    }

    private var ruleSourceSection: some View {
        Section("规则源") {
            TextField(
                "Rule source URL",
                text: state.setting(\.ruleSourceURL).mapURL()
            )
            .font(.caption.monospaced())
            Button {
                Task { await state.refreshRemoteRules() }
            } label: {
                Label("立即刷新", systemImage: "arrow.clockwise")
            }
        }
    }

    /// Geo 数据：内置精简版（geoip 仅 cn/private）↔ 完整版（全部国家码，~20MB）。
    /// 下载走主备源（轻舟源 → v2fly 官方），sha256 校验通过才落盘；成功后自动热切换生效。
    private var geoDataSection: some View {
        Section {
            LabeledContent("当前版本") {
                if state.geoData.hasFullGeoIP, let info = state.geoData.info {
                    Text("完整版 · \(info.downloadedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))) · 来源：\(L10n.lookup(info.sourceName))")
                        .font(.caption)
                } else {
                    Text("精简版（内置，GEOIP 仅 cn / private）")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            switch state.geoData.phase {
            case .downloading(let sourceName, let progress):
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                    Text("正在从\(sourceName)下载…")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize()
                }
            case .verifying:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("sha256 校验中…").font(.caption).foregroundStyle(.secondary)
                }
            default:
                Button {
                    Task { await state.downloadFullGeoData() }
                } label: {
                    Label(state.geoData.hasFullGeoIP ? "重新下载完整版" : "下载完整版（约 20 MB）",
                          systemImage: "arrow.down.circle")
                }
                Button {
                    Task { await state.geoData.checkForUpdate() }
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                if let message = state.geoData.lastCheckMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if case .failed(let message) = state.geoData.phase {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Geo 数据")
        } footer: {
            Text("完整版解锁所有国家/地区码的 GEOIP 规则（如 GEOIP,us）。数据来自 v2fly 上游，主源为轻舟自建发布仓库、每周自动同步，主源不可用时自动切换 v2fly 官方源。")
                .font(.caption2)
        }
    }

    #if os(macOS)
    private var macIntegrationSection: some View {
        Section("macOS 集成") {
            Toggle("开机自启", isOn: state.setting(\.launchAtLogin))
            Button("立即应用") {
                state.applyMacSystemPreferences()
            }
            autoConnectRows
            // 「来源 App 标注」入口暂时隐藏（功能搁置，见 FeatureFlags.sourceAppLabeling）。
            if FeatureFlags.sourceAppLabeling {
                Button(filterEnabled ? "关闭来源 App 标注" : "启用来源 App 标注") {
                    ContentFilterManager.shared.onNeedsApproval = {
                        state.showToast(L("请到「系统设置 → 通用 → 登录项与扩展 → 网络扩展」批准轻舟"))
                    }
                    Task {
                        do {
                            if filterEnabled {
                                try await ContentFilterManager.shared.disable()
                            } else {
                                try await ContentFilterManager.shared.activateAndEnable()
                            }
                            filterEnabled = ContentFilterManager.isEnabled
                            state.showToast(filterEnabled ? L("已启用来源 App 标注") : L("已关闭来源 App 标注"))
                        } catch {
                            let ns = error as NSError
                            state.showToast(L("失败 [\(ns.domain) #\(ns.code)] \(ns.localizedDescription)"))
                            state.logger.error("Content filter toggle failed: domain=\(ns.domain) code=\(ns.code) info=\(ns.userInfo)", category: "filter")
                        }
                    }
                }
                .task { filterEnabled = ContentFilterManager.isEnabled }
                Text("开启后「连接」页会标注每条流量是哪个 App 发起的。首次要在系统设置批准扩展 + 授权过滤。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// 「打开指定 App 自动连」：开关 + 触发 App 列表 + 添加按钮。
    /// iOS 没有对应系统能力（Shortcuts 自动化可实现同样效果），故仅 macOS。
    @ViewBuilder
    private var autoConnectRows: some View {
        Toggle("打开指定 App 时自动连接", isOn: state.setting(\.autoConnectOnAppLaunch))
        if state.settings.autoConnectOnAppLaunch {
            ForEach(state.settings.autoConnectApps.sorted(), id: \.self) { bundleID in
                HStack {
                    let info = Self.appDisplayInfo(for: bundleID)
                    if let icon = info.icon {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    }
                    Text(info.name)
                    Spacer()
                    Button {
                        var apps = state.settings.autoConnectApps
                        apps.remove(bundleID)
                        state.setting(\.autoConnectApps).wrappedValue = apps
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("移除")
                }
            }
            Button {
                addAutoConnectApps()
            } label: {
                Label("添加 App…", systemImage: "plus")
            }
            Text("任一所选 App 启动 → 自动连接；全部退出 → 自动断开（只断开由自动连接拉起的会话，手动开启的 VPN 不受影响）。iPhone/iPad 上可用「快捷指令 → 自动化 → App」实现同样效果。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// NSOpenPanel 选 .app → 读 bundle id 存入设置。选不出 bundle id 的（损坏包）静默跳过。
    private func addAutoConnectApps() {
        let panel = NSOpenPanel()
        panel.title = L("选择触发自动连接的 App")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        var apps = state.settings.autoConnectApps
        for url in panel.urls {
            if let bid = Bundle(url: url)?.bundleIdentifier { apps.insert(bid) }
        }
        state.setting(\.autoConnectApps).wrappedValue = apps
    }

    /// bundle id → 展示名 + 图标（App 已卸载时退化显示 bundle id）。
    private static func appDisplayInfo(for bundleID: String) -> (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return (bundleID, nil)
        }
        let name = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? FileManager.default.displayName(atPath: url.path)
        return (name, NSWorkspace.shared.icon(forFile: url.path))
    }
    #endif

    private var iCloudSection: some View {
        Section("iCloud 同步") {
            Toggle("同步到 iCloud Drive", isOn: cloudSyncBinding)
            LabeledContent("状态", value: state.cloudSyncStatus.displayText)
                .font(.caption)
            Button {
                Task { await state.requestManualCloudRestore() }
            } label: {
                Label("立即恢复 iCloud 数据", systemImage: "icloud.and.arrow.down")
            }
            .disabled(!state.settings.iCloudSyncEnabled)
            Text("不会自动弹出恢复提示。需要恢复时，请点上方按钮选择云端版本；出现版本差异时会暂停自动上传，保留两边配置。")
                .font(.caption2).foregroundStyle(.secondary)
            Text("配置（订阅、节点、规则、设置）会镜像到你 iCloud Drive 的「轻舟」文件夹，卸载 App 不会丢失，重装或换设备时可一键恢复。云端保留最近 \(CloudVaultStore.maxBackups) 份历史版本。不含连接记录与流量统计。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// iCloud 同步开关走专用方法 —— 开启时要立刻跑一次云端比对（只更新状态，不弹恢复提示）。
    private var cloudSyncBinding: Binding<Bool> {
        Binding(
            get: { state.settings.iCloudSyncEnabled },
            set: { state.setCloudSyncEnabled($0) }
        )
    }

    /// 只读专用稳定 Bool（呈现开关），不读会中途变化的加载态 —— 见 body 上 sheet 的注释。
    private var cloudVersionSheetBinding: Binding<Bool> {
        Binding(
            get: { state.isCloudVersionSheetPresented },
            set: { if !$0 { state.dismissCloudVersionOptions() } }
        )
    }

    /// 版本选择 sheet 三态：点击瞬间以 .loading 呈现（iCloud 读取秒级，sheet 不能干等），
    /// 读完切列表；失败留在 sheet 内展示 + 重试。
    private var cloudVersionPicker: some View {
        NavigationStack {
            Group {
                switch state.cloudVersionLoad {
                case nil, .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在读取 iCloud 版本…")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.icloud")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text(message)
                            .font(.subheadline).multilineTextAlignment(.center)
                        Button("重试") {
                            Task { await state.loadCloudVersionOptions() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let options):
                    List(options) { option in
                        Button {
                            state.chooseCloudRestoreCandidate(option)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(option.backupFileName == nil ? "云端当前版本" : "历史版本")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("r\(option.header.revision)")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                // 内容计数醒目展示 —— 空数据（0 订阅）一眼可见
                                Text(option.header.contentSummary)
                                    .font(.subheadline)
                                    .foregroundStyle(
                                        (option.header.nodeCount ?? 1) == 0 ? AnyShapeStyle(.orange)
                                                                            : AnyShapeStyle(.primary))
                                Text("\(option.header.deviceName) · "
                                     + option.header.modifiedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("选择要恢复的版本")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { state.dismissCloudVersionOptions() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("App 版本", value: appVersion)
            LabeledContent("数据目录", value: dataDir).font(.caption.monospaced())
            Link("GitHub 仓库", destination: URL(string: "https://github.com/qingzhou-app/qingzhou")!)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var dataDir: String {
        Persistence.defaultDirectory().path
    }

    private func label(for mode: ProxyMode) -> String {
        switch mode {
        case .global: return L("全局代理")
        case .rule:   return L("规则代理")
        case .direct: return L("直连")
        }
    }
}
