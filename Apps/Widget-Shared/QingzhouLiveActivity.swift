// 轻舟 Live Activity —— 灵动岛（compact / minimal / expanded 三态）+ 锁屏实时活动（E.19）。
//
// 只在 iOS 存在（macOS 无 Live Activity），整文件用 `#if os(iOS)` 隔离；Widget-Shared 双平台
// 共用源码，macOS widget target 编到这里会整体略过。
//
// 数据契约 QingzhouActivityAttributes / ContentState 在 QingzhouCore（主 App 与 widget 都 link）。
// 主 App 侧起 / 每秒更新 / 结束见 QingzhouApp.LiveActivityController + AppState.syncLiveActivity。
// 已连时长用 Text(_:style:.timer) 自走字，主 App 进后台被挂起也照走；速率则冻结在最后一次
// 更新值（主 App 前台每秒推进）。

#if os(iOS)
import ActivityKit
import QingzhouCore
import SwiftUI
import WidgetKit

struct QingzhouLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QingzhouActivityAttributes.self) { context in
            // 锁屏 / 横幅（灵动岛不可用时也用这个）
            LiveActivityLockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.nodeName).lineLimit(1)
                    } icon: {
                        Image(systemName: LAStatus.icon(state.phase))
                            .foregroundStyle(LAStatus.color(state.phase))
                    }
                    .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let since = state.connectedSince, state.phase == .connected {
                        Text(since, style: .timer)
                            .monospacedDigit()
                            .font(.headline)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 68)
                    } else {
                        Text(LAStatus.text(state.phase))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        LASpeed(systemImage: "arrow.down", bps: state.downloadSpeedBps)
                        Spacer()
                        LASpeed(systemImage: "arrow.up", bps: state.uploadSpeedBps)
                    }
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: LAStatus.icon(state.phase))
                    .foregroundStyle(LAStatus.color(state.phase))
            } compactTrailing: {
                if let since = state.connectedSince, state.phase == .connected {
                    Text(since, style: .timer)
                        .monospacedDigit()
                        .frame(maxWidth: 46)
                } else {
                    Text(LAStatus.text(state.phase))
                        .font(.caption2)
                }
            } minimal: {
                Image(systemName: LAStatus.icon(state.phase))
                    .foregroundStyle(LAStatus.color(state.phase))
            }
            .keylineTint(LAStatus.color(state.phase))
        }
    }
}

// MARK: - 锁屏视图

struct LiveActivityLockScreenView: View {
    let attributes: QingzhouActivityAttributes
    let state: QingzhouActivityContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: LAStatus.icon(state.phase))
                .font(.title)
                .foregroundStyle(LAStatus.color(state.phase))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(LAStatus.text(state.phase))
                        .font(.headline)
                    if !attributes.nodeName.isEmpty {
                        Text(attributes.nodeName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 10) {
                    LASpeed(systemImage: "arrow.down", bps: state.downloadSpeedBps)
                    LASpeed(systemImage: "arrow.up", bps: state.uploadSpeedBps)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let since = state.connectedSince, state.phase == .connected {
                Text(since, style: .timer)
                    .font(.title3.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 88)
            }
        }
        .padding()
    }
}

// MARK: - 复用小件

/// 速率标签：一个方向箭头 + 格式化速率（`1.2 MB/s`）。方向用图标表达，无需额外文案本地化。
struct LASpeed: View {
    let systemImage: String
    let bps: Int64
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
            Text(ByteFormatter.speed(bps))
        }
    }
}

/// phase → 图标 / 颜色 / 文案。文案查 widget 自己的 Localizable.xcstrings（跟随系统语言）。
enum LAStatus {
    static func icon(_ phase: QingzhouActivityContentState.Phase) -> String {
        switch phase {
        case .connected:     "checkmark.shield.fill"
        case .connecting:    "shield.lefthalf.filled"
        case .disconnecting: "shield.slash"
        }
    }

    static func color(_ phase: QingzhouActivityContentState.Phase) -> Color {
        switch phase {
        case .connected:     .green
        case .connecting:    .orange
        case .disconnecting: .secondary
        }
    }

    static func text(_ phase: QingzhouActivityContentState.Phase) -> String {
        switch phase {
        case .connected:     String(localized: "已连接")
        case .connecting:    String(localized: "连接中…")
        case .disconnecting: String(localized: "断开中…")
        }
    }
}
#endif
