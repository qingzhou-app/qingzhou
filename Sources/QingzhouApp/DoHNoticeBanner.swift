import SwiftUI
import QingzhouCore

/// 「大量连接仅显示 IP」的可关闭说明条（连接页 / 域名分析页共用）。
///
/// 触发：`DoHDetector.isLikelyDoH(connections:)` —— 裸 IP 占比 >50% 且 >20 条。
/// 关闭：写 `state.dohNoticeDismissed`（会话级，两页联动，不持久化）。
/// 这不是错误提示：DoH 下轻舟的 FakeDNS 看不到解析，属于机制边界，说明白即可。
struct DoHNoticeBanner: View {
    @Bindable var state: AppState

    /// 是否应显示（触发条件 + 未被点掉）。
    static func shouldShow(state: AppState) -> Bool {
        !state.dohNoticeDismissed && DoHDetector.isLikelyDoH(connections: state.connections)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("大量连接仅显示 IP")
                    .font(.caption).fontWeight(.medium)
                Text("浏览器可能在用加密 DNS（DoH），域名解析不经过隧道，轻舟无法看到这些域名。想按域名统计/分流，可在浏览器设置里关闭「安全 DNS」。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                state.dohNoticeDismissed = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("本次运行期间不再提示")
        }
        .padding(10)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
