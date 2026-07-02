import SwiftUI

/// 「忽略 IP」过滤开关 —— 连接页和域名分析页共用。
///
/// - 图标 + 文字并显（`.titleAndIcon`），第一眼就能看懂是干什么的。
/// - **临时状态、不持久化**：绑定 ConnectionsView 的 `@State`，经 Binding 传给
///   域名分析页（两页联动）；离开连接页视图销毁即自动复位为关闭。
/// - 开启时按钮呈选中高亮态（`.toggleStyle(.button)`），让用户看得出过滤在生效。
struct IgnoreIPToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Label("忽略 IP", systemImage: "eye.slash")
                .labelStyle(.titleAndIcon)
        }
        .toggleStyle(.button)
        .help("隐藏目标是纯 IP（没有域名）的条目；离开页面自动恢复")
    }
}
