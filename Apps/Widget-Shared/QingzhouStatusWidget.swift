// 轻舟状态小组件：主屏 systemSmall（iOS/macOS 通知中心共用）+ iOS 锁屏 accessory 两族。
//
// - systemSmall：状态图标 + 节点名 + 已连接时长 + 一键开关按钮。
//   按钮用 Button(intent: ToggleVPNIntent())（iOS 17 / macOS 14 交互式 widget）——
//   intent 在 **widget 扩展进程**里执行，所以本 target 的 entitlements 必须带 NE 键
//   （见 project.yml）。intent 跑完 WidgetKit 会自动重载时间线刷新显示。
// - accessory（锁屏）：纯展示，点按走系统默认行为打开主 App（无需 widgetURL/URL scheme）。
//
// 时间线策略：拉模型 + 两个刷新源。
// 1. 主 App 在 isVPNRunning 变化处调 WidgetRefresher.reload()（集成点，见该文件注释）；
// 2. 自身兜底：稳态 30 分钟一刷；过渡态（connecting…）15 秒后再刷 —— 点开关后
//    自动重载常落在 connecting 窗口里，不补一刷会长时间停留在"连接中"。
// 已连接时长用 Text(style: .timer) 自走字，不需要密集时间线条目。

import QingzhouApp
import SwiftUI
import WidgetKit

struct QingzhouStatusEntry: TimelineEntry {
    let date: Date
    let snapshot: VPNWidgetSnapshot
}

struct QingzhouStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> QingzhouStatusEntry {
        QingzhouStatusEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (QingzhouStatusEntry) -> Void) {
        // 小组件库预览用静态样本，别让预览等 NE preferences IO
        if context.isPreview {
            completion(QingzhouStatusEntry(date: .now, snapshot: .placeholder))
            return
        }
        Task { @MainActor in
            completion(QingzhouStatusEntry(date: .now, snapshot: await VPNWidgetSnapshot.read()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<QingzhouStatusEntry>) -> Void) {
        Task { @MainActor in
            let snapshot = await VPNWidgetSnapshot.read()
            let refresh: TimeInterval = snapshot.phase == .transitioning ? 15 : 30 * 60
            completion(Timeline(
                entries: [QingzhouStatusEntry(date: .now, snapshot: snapshot)],
                policy: .after(Date().addingTimeInterval(refresh))
            ))
        }
    }
}

struct QingzhouStatusWidget: Widget {
    // kind 是系统持久化 widget 实例的键，改了用户已放置的 widget 会失效 —— 定死别动
    static let kind = "QingzhouStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: QingzhouStatusProvider()) { entry in
            QingzhouStatusView(entry: entry)
        }
        .configurationDisplayName("轻舟 VPN")
        .description("查看连接状态，一键启停。")
        #if os(iOS)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        #endif
    }
}

// MARK: - 视图

struct QingzhouStatusView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QingzhouStatusEntry

    private var snapshot: VPNWidgetSnapshot { entry.snapshot }

    private var statusText: String {
        switch snapshot.phase {
        case .connected:     "已连接"
        case .transitioning: "切换中…"
        case .disconnected:  "未连接"
        }
    }

    private var statusIcon: String {
        switch snapshot.phase {
        case .connected:     "checkmark.shield.fill"
        case .transitioning: "shield.lefthalf.filled"
        case .disconnected:  "shield.slash"
        }
    }

    private var statusColor: Color {
        switch snapshot.phase {
        case .connected:     .green
        case .transitioning: .orange
        case .disconnected:  .secondary
        }
    }

    var body: some View {
        Group {
            switch family {
            #if os(iOS)
            case .accessoryCircular:
                circular
            case .accessoryRectangular:
                rectangular
            #endif
            case .systemMedium:
                medium
            case .systemLarge:
                large
            default:
                small
            }
        }
        // iOS 17 起所有 family 都必须声明容器背景；accessory 族系统会自动忽略成毛玻璃
        .containerBackground(.background, for: .widget)
    }

    /// 主屏 systemSmall / macOS 通知中心
    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: statusIcon)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                Spacer()
            }
            Spacer(minLength: 2)
            Text(statusText)
                .font(.headline)
            // 节点名从 VPN preferences 取；从没配过节点时整行不显示，只留状态
            if let name = snapshot.nodeName, !name.isEmpty {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let since = snapshot.connectedSince {
                Text(since, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            Button(intent: ToggleVPNIntent()) {
                Text(snapshot.phase == .disconnected ? "连接" : "断开")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(snapshot.phase == .disconnected ? .accentColor : .gray)
            .disabled(snapshot.phase == .transitioning)
        }
    }

    /// systemMedium：左侧状态详情，右侧大按钮
    private var medium: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // 与 small 同款风格：**只有图标带状态色，文字用主文本色** ——
                // 曾用 Label 整体染色（绿字），三种尺寸风格不一致（真机验收打回）
                HStack(spacing: 5) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                    Text(statusText)
                }
                .font(.headline)
                if let name = snapshot.nodeName, !name.isEmpty {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let since = snapshot.connectedSince {
                    Text(since, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(intent: ToggleVPNIntent()) {
                VStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.title3.weight(.semibold))
                    Text(snapshot.phase == .disconnected ? "连接" : "断开")
                        .font(.footnote.weight(.semibold))
                }
                .frame(width: 72, height: 60)
            }
            .buttonStyle(.borderedProminent)
            .tint(snapshot.phase == .disconnected ? .accentColor : .gray)
            .disabled(snapshot.phase == .transitioning)
        }
    }

    /// systemLarge：medium 的信息 + 自动化玩法提示（引导发现快捷指令 / 控制中心能力）
    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            medium
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label("更多玩法", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Group {
                    Text("• 快捷指令：搜「轻舟」，开 / 关 / 切换、状态判断")
                    Text("• 自动化：打开某 App 时自动连接，关闭时断开")
                    Text("• 控制中心：添加「轻舟 VPN」控件，一键启停")
                    Text("• Siri：对 Siri 说「开启轻舟」")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    #if os(iOS)
    /// 锁屏圆形：只有图标，一眼状态
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: statusIcon)
                .font(.title3)
        }
    }

    /// 锁屏矩形：状态 + 节点名 + 时长
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(statusText, systemImage: statusIcon)
                .font(.headline)
            if let name = snapshot.nodeName, !name.isEmpty {
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
            }
            if let since = snapshot.connectedSince {
                Text(since, style: .timer)
                    .font(.caption2.monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif
}
