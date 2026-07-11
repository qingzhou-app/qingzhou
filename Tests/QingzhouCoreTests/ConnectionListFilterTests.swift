import XCTest
@testable import QingzhouCore

/// 连接列表「路由 / 隐藏 DNS / 忽略 IP」三层筛选的纯逻辑测试。
/// 锁定：层序（路由→DNS→IP）、路由单选语义、以及叠加路由后各隐藏计数的口径。
final class ConnectionListFilterTests: XCTestCase {

    /// targetAddress 用 `host:port` 拼，让 `isDNSQuery`（port==53）能正确判定。
    private func conn(_ host: String, route: String, port: Int = 443,
                      at: Date = Date()) -> Connection {
        Connection(targetHost: host, sourceAddress: "127.0.0.1:1",
                   targetAddress: "\(host):\(port)", type: port == 53 ? .udp : .https,
                   route: route, matchedRule: "", openedAt: at)
    }

    // MARK: - ConnectionRouteFilter 基础映射

    func testRouteFilterMapsToDomainRoute() {
        XCTAssertNil(ConnectionRouteFilter.all.route)
        XCTAssertEqual(ConnectionRouteFilter.direct.route, .direct)
        XCTAssertEqual(ConnectionRouteFilter.proxy.route, .proxy)
        XCTAssertEqual(ConnectionRouteFilter.reject.route, .reject)
    }

    /// 菜单里 Picker 的选项顺序依赖 allCases —— 锁成 全部/直连/代理/拒绝。
    func testRouteFilterCaseOrder() {
        XCTAssertEqual(ConnectionRouteFilter.allCases, [.all, .direct, .proxy, .reject])
    }

    // MARK: - ① routeFilter = .all 不因路由过滤任何条

    func testAllRouteFilterNeverHidesByRoute() {
        for route in ["DIRECT", "REJECT", "香港 IEPL 01"] {
            let o = ConnectionListFilter.outcome(
                route: route, isDNSQuery: false, isBareIP: false,
                routeFilter: .all, hideDNS: false, hideBareIPs: false)
            XCTAssertEqual(o, .visible, "route=\(route) 在 .all 下应可见")
        }
    }

    // MARK: - ②③ 具体档只保留对应路由

    func testRejectFilterKeepsOnlyReject() {
        XCTAssertEqual(ConnectionListFilter.outcome(
            route: "REJECT", isDNSQuery: false, isBareIP: false,
            routeFilter: .reject, hideDNS: false, hideBareIPs: false), .visible)
        for route in ["DIRECT", "香港 IEPL 01"] {
            XCTAssertEqual(ConnectionListFilter.outcome(
                route: route, isDNSQuery: false, isBareIP: false,
                routeFilter: .reject, hideDNS: false, hideBareIPs: false), .hiddenByRoute)
        }
    }

    func testDirectAndProxyFiltersKeepOnlyTheirCategory() {
        // 节点名一律归 proxy
        XCTAssertEqual(ConnectionListFilter.outcome(
            route: "DIRECT", isDNSQuery: false, isBareIP: false,
            routeFilter: .direct, hideDNS: false, hideBareIPs: false), .visible)
        XCTAssertEqual(ConnectionListFilter.outcome(
            route: "东京 IIJ", isDNSQuery: false, isBareIP: false,
            routeFilter: .direct, hideDNS: false, hideBareIPs: false), .hiddenByRoute)
        XCTAssertEqual(ConnectionListFilter.outcome(
            route: "东京 IIJ", isDNSQuery: false, isBareIP: false,
            routeFilter: .proxy, hideDNS: false, hideBareIPs: false), .visible)
        XCTAssertEqual(ConnectionListFilter.outcome(
            route: "DIRECT", isDNSQuery: false, isBareIP: false,
            routeFilter: .proxy, hideDNS: false, hideBareIPs: false), .hiddenByRoute)
    }

    // MARK: - ④ 叠加优先级：路由 → DNS → IP

    /// DNS 判定在忽略 IP 之前：一条既是 DNS 查询又是裸 IP 的连接，两开关都开时归 DNS。
    func testDNSTakesPrecedenceOverBareIP() {
        let o = ConnectionListFilter.outcome(
            route: "DIRECT", isDNSQuery: true, isBareIP: true,
            routeFilter: .all, hideDNS: true, hideBareIPs: true)
        XCTAssertEqual(o, .hiddenByDNS)
    }

    /// 路由在最外层：被路由排除的连接即便本会命中 DNS / IP 隐藏，也只归 hiddenByRoute
    /// （不污染 DNS / IP 计数）。
    func testRouteExclusionPreemptsDNSAndBareIP() {
        // 一条 DIRECT + DNS + 裸 IP 的连接，在只看 proxy 时先被路由排除
        let o = ConnectionListFilter.outcome(
            route: "DIRECT", isDNSQuery: true, isBareIP: true,
            routeFilter: .proxy, hideDNS: true, hideBareIPs: true)
        XCTAssertEqual(o, .hiddenByRoute)
    }

    func testBareIPHiddenWhenOnlyIPToggleOn() {
        XCTAssertEqual(ConnectionListFilter.outcome(
            route: "DIRECT", isDNSQuery: false, isBareIP: true,
            routeFilter: .all, hideDNS: false, hideBareIPs: true), .hiddenByBareIP)
        // 开关关 → 可见
        XCTAssertEqual(ConnectionListFilter.outcome(
            route: "DIRECT", isDNSQuery: false, isBareIP: true,
            routeFilter: .all, hideDNS: false, hideBareIPs: false), .visible)
    }

    // MARK: - ⑤ apply：叠加路由筛选后计数口径

    func testApplyCountsUnderAllRoute() {
        // 两条裸 IP（一直连一代理）+ 两条域名（直连/拒绝），仅开忽略 IP
        let conns = [
            conn("1.1.1.1", route: "DIRECT"),
            conn("2.2.2.2", route: "hk-node"),
            conn("baidu.com", route: "DIRECT"),
            conn("ads.com", route: "REJECT"),
        ]
        let r = ConnectionListFilter.apply(conns, routeFilter: .all,
                                           hideDNS: false, hideBareIPs: true)
        XCTAssertEqual(r.visible.map(\.targetHost), ["baidu.com", "ads.com"])
        XCTAssertEqual(r.hiddenBareIPCount, 2, ".all 下两条裸 IP 都算隐藏")
        XCTAssertEqual(r.hiddenRouteCount, 0)
        XCTAssertEqual(r.hiddenDNSCount, 0)
    }

    /// 叠加路由筛选：hiddenBareIPCount 只统计「命中当前路由、仅因裸 IP 被隐藏」的条数，
    /// 路由作用域外的裸 IP 归 hiddenRouteCount，不进 IP 计数。
    func testApplyBareIPCountScopedToSelectedRoute() {
        let conns = [
            conn("1.1.1.1", route: "DIRECT"),   // 直连裸 IP → 被 IP 隐藏
            conn("2.2.2.2", route: "hk-node"),  // 代理裸 IP → 路由排除（不算 IP）
            conn("baidu.com", route: "DIRECT"), // 直连域名 → 可见
            conn("ads.com", route: "REJECT"),   // 拒绝域名 → 路由排除
        ]
        let r = ConnectionListFilter.apply(conns, routeFilter: .direct,
                                           hideDNS: false, hideBareIPs: true)
        XCTAssertEqual(r.visible.map(\.targetHost), ["baidu.com"])
        XCTAssertEqual(r.hiddenBareIPCount, 1, "只有直连那条裸 IP 计入")
        XCTAssertEqual(r.hiddenRouteCount, 2, "代理裸 IP + 拒绝域名")
        XCTAssertEqual(r.hiddenDNSCount, 0)
    }

    /// DNS 与 IP 计数分离：DNS 查询（哪怕目标是裸 IP）计入 DNS，不重复计入 IP。
    func testApplySeparatesDNSAndBareIPCounts() {
        let conns = [
            conn("8.8.8.8", route: "DIRECT", port: 53),   // DNS 且裸 IP → DNS
            conn("9.9.9.9", route: "DIRECT"),             // 纯裸 IP → IP
            conn("baidu.com", route: "DIRECT"),           // 可见
        ]
        let r = ConnectionListFilter.apply(conns, routeFilter: .all,
                                           hideDNS: true, hideBareIPs: true)
        XCTAssertEqual(r.visible.map(\.targetHost), ["baidu.com"])
        XCTAssertEqual(r.hiddenDNSCount, 1)
        XCTAssertEqual(r.hiddenBareIPCount, 1)
        XCTAssertEqual(r.hiddenRouteCount, 0)
    }

    func testApplyRejectOnlyLeavesRejectConnections() {
        let conns = [
            conn("ads.com", route: "REJECT"),
            conn("track.com", route: "REJECT"),
            conn("baidu.com", route: "DIRECT"),
            conn("google.com", route: "jp-node"),
        ]
        let r = ConnectionListFilter.apply(conns, routeFilter: .reject,
                                           hideDNS: false, hideBareIPs: false)
        XCTAssertEqual(Set(r.visible.map(\.targetHost)), ["ads.com", "track.com"])
        XCTAssertEqual(r.hiddenRouteCount, 2)
    }

    // MARK: - accepts()：域名分析聚合后过滤口径（.mixed 只在「全部」出现）

    func testAcceptsExactMatchExceptAll() {
        XCTAssertTrue(ConnectionRouteFilter.all.accepts(.mixed))
        XCTAssertTrue(ConnectionRouteFilter.all.accepts(.proxy))
        XCTAssertTrue(ConnectionRouteFilter.proxy.accepts(.proxy))
        XCTAssertFalse(ConnectionRouteFilter.proxy.accepts(.mixed))
        XCTAssertFalse(ConnectionRouteFilter.proxy.accepts(.direct))
        XCTAssertTrue(ConnectionRouteFilter.direct.accepts(.direct))
        XCTAssertTrue(ConnectionRouteFilter.reject.accepts(.reject))
        XCTAssertFalse(ConnectionRouteFilter.reject.accepts(.mixed))
    }
}
