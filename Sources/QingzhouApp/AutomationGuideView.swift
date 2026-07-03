import SwiftUI

/// 「自动化玩法」引导页 —— 把轻舟全部自动化能力和配方集中一页，最小化用户心智负担。
///
/// 背景：动作（开/关/切换/状态查询）经 AppShortcutsProvider **零配置**出现在快捷指令 App；
/// 但「打开某 App 自动连」这类**自动化**，Apple 不允许任何 App 替用户预装（系统安全设计），
/// 用户必须亲手在快捷指令里创建。我们能做的极限 = 把步骤讲到不用动脑 + 一键跳转到位。
/// 入口：设置 → 自动化 → 「自动化玩法指南」。
public struct AutomationGuideView: View {
    @Environment(\.openURL) private var openURL

    public init() {}

    public var body: some View {
        Form {
            readyMadeSection
            siriSection
            #if os(iOS)
            appTriggerRecipeSection
            conditionalRecipeSection
            surfacesSection
            #else
            macAutoConnectSection
            macSurfacesSection
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle("自动化玩法")
    }

    // MARK: - 通用

    private var readyMadeSection: some View {
        Section {
            recipe("power", "切换轻舟", "在跑就断开，没跑就连接 —— 一个动作两用")
            recipe("play.fill", "开启轻舟", "连接到上次使用的节点")
            recipe("stop.fill", "关闭轻舟", "断开当前连接")
            recipe("questionmark.circle", "轻舟是否已连接", "返回是/否，给自动化做条件判断")
            Button {
                openShortcutsApp()
            } label: {
                Label("打开「快捷指令」看看", systemImage: "arrow.up.forward.app")
            }
        } header: {
            Text("现成的动作（零配置）")
        } footer: {
            Text("这四个动作已自动出现在「快捷指令」App 里（搜索“轻舟”即可），无需任何设置，"
                 + "可直接运行或编进你自己的快捷指令。刚安装完可能需要几分钟被系统索引。")
        }
    }

    private var siriSection: some View {
        Section {
            Label("“开启轻舟”", systemImage: "mic.fill")
            Label("“关闭轻舟”", systemImage: "mic")
            Label("“切换轻舟”", systemImage: "mic.badge.plus")
        } header: {
            Text("对 Siri 说")
        } footer: {
            Text("免解锁、免找图标，说一句就连。")
        }
    }

    // MARK: - iOS

    #if os(iOS)
    private var appTriggerRecipeSection: some View {
        Section {
            step(1, "打开「快捷指令」App → 底部「自动化」标签")
            step(2, "右上 + → 「App」")
            step(3, "选择目标 App（比如 ChatGPT / Slack），勾「已打开」")
            step(4, "把「运行前询问」改成「立即运行」 —— 这步决定它是全自动还是每次弹确认")
            step(5, "下一步 → 搜索“轻舟” → 选「开启轻舟」→ 完成")
            Text("再建一条对称的：同一个 App 勾「已关闭」→ 动作选「关闭轻舟」。"
                 + "从此打开它就有网、关掉它就断开。")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                openShortcutsApp()
            } label: {
                Label("去快捷指令创建", systemImage: "arrow.up.forward.app")
            }
        } header: {
            Text("配方 · 打开某 App 自动连接")
        } footer: {
            Text("Apple 不允许任何 App 替你预装自动化（安全设计），所以这五步必须亲手点一次 —— "
                 + "只需一次，之后永久生效。")
        }
    }

    private var conditionalRecipeSection: some View {
        Section {
            step(1, "上面配方的第 5 步改为：搜索“轻舟” → 「轻舟是否已连接」")
            step(2, "加「如果」动作：条件 = 结果 为 否")
            step(3, "「如果」里放「开启轻舟」→ 完成")
            Text("效果：已连接时什么都不做，未连接才连 —— 避免重复启动打断在跑的会话。")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("进阶 · 条件版（推荐）")
        }
    }

    private var surfacesSection: some View {
        Section {
            recipe("square.grid.2x2", "主屏小组件", "长按主屏空白处 → 编辑 → 添加小组件 → 搜“轻舟” —— 小/中/大三种尺寸，按钮直接启停")
            recipe("lock", "锁屏小组件", "长按锁屏 → 自定义 → 添加轻舟圆形/矩形 —— 不解锁看状态")
            recipe("switch.2", "控制中心（iOS 18+）", "控制中心 → 左上 + → 添加控件 → 搜“轻舟 VPN” —— 从任何界面下拉一键开关")
        } header: {
            Text("更快的入口")
        }
    }
    #endif

    // MARK: - macOS

    #if os(macOS)
    private var macAutoConnectSection: some View {
        Section {
            Text("macOS 的快捷指令没有「App 打开/关闭」触发器 —— 轻舟原生实现了这个能力，"
                 + "不需要快捷指令：")
                .font(.callout)
            step(1, "设置 → macOS 集成 → 打开「打开指定 App 时自动连接」")
            step(2, "「添加 App…」选择触发 App（可多选）")
            Text("任一触发 App 启动 → 自动连接；全部退出 → 自动断开（只断自动拉起的会话，"
                 + "你手动开的 VPN 不受影响）。")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("打开某 App 自动连接（原生支持）")
        }
    }

    private var macSurfacesSection: some View {
        Section {
            recipe("menubar.rectangle", "菜单栏", "常驻状态与开关，随点随用")
            recipe("square.grid.2x2", "通知中心小组件", "点菜单栏时钟 → 编辑小组件 → 添加轻舟")
            recipe("command", "快捷指令 / Siri", "四个动作同样零配置可用，可编入任何 macOS 工作流")
        } header: {
            Text("更快的入口")
        }
    }
    #endif

    // MARK: - 小部件

    private func recipe(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold().monospacedDigit())
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
                .foregroundStyle(Color.accentColor)
            Text(text)
        }
    }

    /// 跳到「快捷指令」App（双平台都注册了 shortcuts:// scheme）。
    private func openShortcutsApp() {
        if let url = URL(string: "shortcuts://") {
            openURL(url)
        }
    }
}
