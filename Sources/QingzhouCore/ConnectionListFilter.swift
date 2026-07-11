import Foundation

/// 连接页 + 域名分析页共用的「路由筛选」维度：按连接走向做**单选**过滤。
///
/// `.all` = 不按路由过滤；其余三档对应 `DomainRoute` 的 direct/proxy/reject
/// （单条连接经 `DomainAnalyzer.routeCategory` 归类，永远是这三者之一，不会是 `.mixed`）。
///
/// String rawValue + CaseIterable：菜单里用 `Picker` 做单选、rawValue 便于（将来若需要）
/// 持久化。当前和「忽略 IP / 隐藏 DNS」一样是**临时状态、不持久化、离开页面复位**。
public enum ConnectionRouteFilter: String, Sendable, Equatable, CaseIterable, Identifiable {
    case all, direct, proxy, reject

    public var id: String { rawValue }

    /// 映射到 `DomainRoute`（`.all` 无对应 → nil）。用于和单条连接的 route 类别精确比较。
    public var route: DomainRoute? {
        switch self {
        case .all:    return nil
        case .direct: return .direct
        case .proxy:  return .proxy
        case .reject: return .reject
        }
    }

    /// 该筛选是否接纳给定的路由类别 —— 供**域名分析页聚合后**过滤用。
    ///
    /// 域名是多连接聚合的产物，`DomainStat.route` 只有一个「代表 route」，同一域名当天走过
    /// 多条不同 route 时是 `.mixed`。这里按**代表 route 精确匹配**：`.all` 全接纳；具体档只
    /// 接纳精确相等的类别 —— 于是 `.mixed` 域名只在「全部」下出现。持久化的「每日」历史没有
    /// 逐连接粒度可还原，只能按代表 route 匹配，这是这一视图刻意的取舍（见 DomainAnalysisView）。
    ///
    /// 注意与**连接级**过滤（`outcome`）的差别：连接页 / 域名分析的实时聚合是在**聚合前**按
    /// 逐连接 route 过滤的（精确、与连接页一致），只有持久化「每日」历史才退化到这个聚合后口径。
    public func accepts(_ route: DomainRoute) -> Bool {
        switch self {
        case .all:    return true
        case .direct: return route == .direct
        case .proxy:  return route == .proxy
        case .reject: return route == .reject
        }
    }
}

/// 一条连接经「路由 → 隐藏 DNS → 忽略 IP」三层筛选后的去向。
///
/// **层序（口径锁定，勿随意调换）**：
/// 1. 路由（作用域，单选）：不在所选路由内 → `.hiddenByRoute`，**不计入** DNS / IP 计数
///    （它压根不属于当前查看的这一类，像「活跃/已关闭」分段一样是作用域，不是"被隐藏了 N 条"）。
/// 2. 隐藏 DNS：`.hiddenByDNS`，计数。
/// 3. 忽略 IP：`.hiddenByBareIP`，计数。
///
/// DNS 判定在忽略 IP **之前**：DNS 查询目标本身也是 IP，两个开关都会命中它，先归给 DNS 计数
/// 更贴合用户心智（这条被隐藏是因为它是 DNS 查询，而不是因为它是裸 IP）。
public enum ConnectionFilterOutcome: Sendable, Equatable {
    case visible
    case hiddenByRoute
    case hiddenByDNS
    case hiddenByBareIP
}

/// 连接列表筛选的纯逻辑（无 UI、无 IO），连接页和域名分析页共用同一套口径。
public enum ConnectionListFilter {

    /// 判定单条连接经三层筛选后的去向。输入是连接的三项事实 + 三个筛选值，输出见
    /// `ConnectionFilterOutcome`。层序与计数口径见该枚举注释。
    ///
    /// - Parameters:
    ///   - route: `Connection.route` 原始字符串（DIRECT / REJECT / 节点名）。
    ///   - isDNSQuery: 是否 DNS 查询（`Connection.isDNSQuery`）。
    ///   - isBareIP: 目标是否裸 IP（`HostClassifier.isBareIP(targetHost)`）。
    public static func outcome(
        route: String,
        isDNSQuery: Bool,
        isBareIP: Bool,
        routeFilter: ConnectionRouteFilter,
        hideDNS: Bool,
        hideBareIPs: Bool
    ) -> ConnectionFilterOutcome {
        if let want = routeFilter.route, DomainAnalyzer.routeCategory(route) != want {
            return .hiddenByRoute
        }
        if hideDNS && isDNSQuery { return .hiddenByDNS }
        if hideBareIPs && isBareIP { return .hiddenByBareIP }
        return .visible
    }

    /// 一批连接经三层筛选后的结果：保留下来的连接 + 各隐藏层的计数。
    ///
    /// `hiddenDNSCount` / `hiddenBareIPCount` 只统计**前面层已通过、仅因该项被隐藏**的条数
    /// （用于轻提示），因此叠加路由筛选时它们只覆盖「命中当前路由的连接里」被 DNS / IP 隐藏的部分
    /// —— 路由作用域外的连接归 `hiddenRouteCount`，不污染这两个计数。
    public static func apply(
        _ connections: [Connection],
        routeFilter: ConnectionRouteFilter,
        hideDNS: Bool,
        hideBareIPs: Bool
    ) -> ConnectionFilterResult {
        var visible: [Connection] = []
        var hiddenDNS = 0
        var hiddenBareIP = 0
        var hiddenRoute = 0
        for c in connections {
            switch outcome(route: c.route, isDNSQuery: c.isDNSQuery,
                           isBareIP: HostClassifier.isBareIP(c.targetHost),
                           routeFilter: routeFilter, hideDNS: hideDNS, hideBareIPs: hideBareIPs) {
            case .visible:        visible.append(c)
            case .hiddenByDNS:    hiddenDNS += 1
            case .hiddenByBareIP: hiddenBareIP += 1
            case .hiddenByRoute:  hiddenRoute += 1
            }
        }
        return ConnectionFilterResult(
            visible: visible, hiddenDNSCount: hiddenDNS,
            hiddenBareIPCount: hiddenBareIP, hiddenRouteCount: hiddenRoute
        )
    }
}

/// `ConnectionListFilter.apply` 的结果：可见连接 + 三个隐藏层计数。
public struct ConnectionFilterResult: Equatable, Sendable {
    public var visible: [Connection]
    public var hiddenDNSCount: Int
    public var hiddenBareIPCount: Int
    public var hiddenRouteCount: Int

    public init(visible: [Connection], hiddenDNSCount: Int,
                hiddenBareIPCount: Int, hiddenRouteCount: Int) {
        self.visible = visible
        self.hiddenDNSCount = hiddenDNSCount
        self.hiddenBareIPCount = hiddenBareIPCount
        self.hiddenRouteCount = hiddenRouteCount
    }
}
