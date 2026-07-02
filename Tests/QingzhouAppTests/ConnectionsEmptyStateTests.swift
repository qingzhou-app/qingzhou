import XCTest
@testable import QingzhouApp

/// 连接页空态文案：按「为什么空」区分，别让开着 VPN 的用户以为开关没开。
final class ConnectionsEmptyStateTests: XCTestCase {

    func testFilteredOutBySearchSaysSo() {
        let s = ConnectionsView.emptyState(filter: .active, searching: true,
                                           hiddenIPCount: 0, vpnRunning: true)
        XCTAssertEqual(s.title, "没有匹配的连接")
        XCTAssertFalse(s.description.contains("开启 VPN"), "过滤导致的空不该提 VPN")
    }

    func testFilteredOutByIgnoreIPMentionsHiddenCount() {
        let s = ConnectionsView.emptyState(filter: .all, searching: false,
                                           hiddenIPCount: 7, vpnRunning: true)
        XCTAssertEqual(s.title, "没有匹配的连接")
        XCTAssertTrue(s.description.contains("7"), "要说明被「忽略 IP」藏了多少条")
    }

    func testClosedGroupExplainsAgeOut() {
        let s = ConnectionsView.emptyState(filter: .closed, searching: false,
                                           hiddenIPCount: 0, vpnRunning: true)
        XCTAssertEqual(s.title, "还没有已关闭的连接")
        XCTAssertTrue(s.description.contains("100"), "要说明约 100 秒无活动才归入")
    }

    func testVPNRunningButNoDataSaysBrowseNotTurnOn() {
        let s = ConnectionsView.emptyState(filter: .active, searching: false,
                                           hiddenIPCount: 0, vpnRunning: true)
        XCTAssertEqual(s.title, "暂无连接记录")
        XCTAssertTrue(s.description.contains("浏览"))
        XCTAssertFalse(s.description.contains("开启 VPN"), "VPN 明明开着，不能让用户以为没开")
    }

    func testVPNOffKeepsOriginalGuidance() {
        let s = ConnectionsView.emptyState(filter: .active, searching: false,
                                           hiddenIPCount: 0, vpnRunning: false)
        XCTAssertEqual(s.title, "暂无连接")
        XCTAssertTrue(s.description.contains("开启 VPN"))
    }

    func testSearchFilterBeatsClosedGroupWording() {
        // 「已关闭」分组里带搜索词 → 空因是过滤，不是「还没有已关闭的连接」
        let s = ConnectionsView.emptyState(filter: .closed, searching: true,
                                           hiddenIPCount: 0, vpnRunning: true)
        XCTAssertEqual(s.title, "没有匹配的连接")
    }
}
