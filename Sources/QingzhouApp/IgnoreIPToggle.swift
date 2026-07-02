import SwiftUI
import QingzhouCore

/// 「忽略 IP」过滤开关 —— 连接页和域名分析页的工具栏共用。
/// 绑定到 `Settings.hideBareIPConnections`（两页共享、自动持久化），开启时按钮
/// 呈选中高亮态（`.toggleStyle(.button)`），让用户一眼看出过滤在生效。
struct IgnoreIPToggle: View {
    @Bindable var state: AppState

    var body: some View {
        Toggle(isOn: state.setting(\.hideBareIPConnections)) {
            Label("忽略 IP", systemImage: "eye.slash")
        }
        .toggleStyle(.button)
        .help("隐藏目标是纯 IP（没有域名）的条目")
    }
}
