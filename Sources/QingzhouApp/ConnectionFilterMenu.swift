import SwiftUI
import QingzhouCore

/// 连接页 + 域名分析页共用的「筛选」菜单入口（toolbar 里一个按钮 → 下拉面板）。
///
/// 形态（用户拍板的「统一筛选菜单」，不是顶部 chips 行）：
/// ```
/// 路由
///  ⦿ 全部 / ○ 直连 / ○ 代理 / ○ 拒绝（广告/追踪）   ← 单选（inline Picker）
/// ────────────
///  ☑ 忽略 IP
///  ☑ 隐藏 DNS
/// ```
/// - 路由用 `Picker(.inline)` 做**单选**：全部/直连/代理/拒绝，选一类只看一类。
/// - 「忽略 IP / 隐藏 DNS」是两个独立 `Toggle`（Menu 里渲染成带勾选的行）。
/// - 三个 binding 都是**临时状态**（不持久化、离开页面复位），来自 ConnectionsView 的 @State，
///   经 binding 传到域名分析页 → 两页联动。
/// - **激活态**：任一筛选生效 → 漏斗图标换 `.fill` 变体，一眼看出「正开着过滤」。
///
/// 合并前这三项分散在两处（连接页顶部两个 button + 域名分析 toolbar 两个 toggle），
/// 收进这一个菜单后两页共用此 View，避免重复。
struct ConnectionFilterMenu: View {
    @Binding var routeFilter: ConnectionRouteFilter
    @Binding var hideBareIPs: Bool
    @Binding var hideDNS: Bool

    /// 任一筛选生效（路由非「全部」或任一开关打开）→ 图标用 `.fill` 变体表示激活。
    private var isActive: Bool {
        routeFilter != .all || hideBareIPs || hideDNS
    }

    var body: some View {
        Menu {
            Picker(L("路由"), selection: $routeFilter) {
                Text("全部").tag(ConnectionRouteFilter.all)
                Text("直连").tag(ConnectionRouteFilter.direct)
                Text("代理").tag(ConnectionRouteFilter.proxy)
                Text("拒绝（广告/追踪）").tag(ConnectionRouteFilter.reject)
            }
            .pickerStyle(.inline)

            Divider()

            Toggle(isOn: $hideBareIPs) {
                Label("忽略 IP", systemImage: "eye.slash")
            }
            Toggle(isOn: $hideDNS) {
                Label("隐藏 DNS", systemImage: "point.3.filled.connected.trianglepath.dotted")
            }
        } label: {
            Label(L("筛选"), systemImage: isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .help("按路由（全部/直连/代理/拒绝）筛选，并可隐藏纯 IP / DNS 查询；离开页面自动恢复")
    }
}

extension ConnectionRouteFilter {
    /// 本地化短名（直连/代理/拒绝），供「仅显示 X 类连接」提示用。`.all` 无短名。
    /// 提示里用短名而非菜单里的「拒绝（广告/追踪）」——提示行要简洁。
    var localizedShortName: String? {
        switch self {
        case .all:    return nil
        case .direct: return L("直连")
        case .proxy:  return L("代理")
        case .reject: return L("拒绝")
        }
    }

    /// 路由筛选生效时的轻提示文案；`.all` → nil（不显示提示）。
    /// 与「忽略 IP / 隐藏 DNS」的轻提示同款作用：避免用户忘了开着过滤、以为数据丢了。
    var filterHintText: String? {
        guard let name = localizedShortName else { return nil }
        return L("仅显示「\(name)」类连接")
    }
}
