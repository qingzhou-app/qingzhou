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
            // iOS 的 ToolbarItem 会把 Label 渲染成 icon-only（.titleAndIcon 常不生效）。
            // 这个开关在域名分析页放在 toolbar 里，iOS 用 HStack 强制图标+文字横排；
            // macOS 用 Label 即可（用户已验收 macOS 现状，别动）。
            #if os(iOS)
            HStack(spacing: 4) {
                Image(systemName: "eye.slash")
                Text("忽略 IP")
            }
            #else
            Label("忽略 IP", systemImage: "eye.slash")
                .labelStyle(.titleAndIcon)
            #endif
        }
        .toggleStyle(.button)
        .help("隐藏目标是纯 IP（没有域名）的条目；离开页面自动恢复")
    }
}
