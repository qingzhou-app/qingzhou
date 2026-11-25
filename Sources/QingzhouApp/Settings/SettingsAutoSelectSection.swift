import SwiftUI
import QingzhouCore

struct SettingsAutoSelectSection: View {
    @Bindable var state: AppState

    var body: some View {
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
}
