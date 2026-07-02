import XCTest
@testable import QingzhouApp

/// 首页「已连接 1:23:45」时长文案。
@MainActor
final class ConnectedDurationTests: XCTestCase {
    func testFormatsHoursMinutesSeconds() {
        XCTAssertEqual(HomeView.durationText(0), "0:00:00")
        XCTAssertEqual(HomeView.durationText(59), "0:00:59")
        XCTAssertEqual(HomeView.durationText(60), "0:01:00")
        XCTAssertEqual(HomeView.durationText(3599), "0:59:59")
        XCTAssertEqual(HomeView.durationText(3600), "1:00:00")
        XCTAssertEqual(HomeView.durationText(3600 + 23 * 60 + 45), "1:23:45")
        // 超过一天不换单位，小时继续累加 —— 挂一整天的 VPN 看到 25:00:00 直观且不歧义
        XCTAssertEqual(HomeView.durationText(25 * 3600), "25:00:00")
    }

    func testNegativeClampsHandledByCaller() {
        // 调用方用 max(0, ...) 钳位；这里只保证 0 的表现
        XCTAssertEqual(HomeView.durationText(0.9), "0:00:00")
    }
}
