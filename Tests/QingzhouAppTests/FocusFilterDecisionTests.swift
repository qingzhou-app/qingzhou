import XCTest
@testable import QingzhouApp

@available(iOS 16.0, macOS 13.0, *)
final class FocusFilterDecisionTests: XCTestCase {
    func testConnectMapsToStart() {
        XCTAssertEqual(FocusVPNAction.connect.tunnelCommand, .start)
    }

    func testDisconnectMapsToStop() {
        XCTAssertEqual(FocusVPNAction.disconnect.tunnelCommand, .stop)
    }

    func testNoChangeMapsToNil() {
        XCTAssertNil(FocusVPNAction.noChange.tunnelCommand)
    }

    func testActionRawValuesStable() {
        // rawValue 是 AppEnum 的持久化键，改了会让用户已配好的专注过滤器失效 —— 钉死。
        XCTAssertEqual(FocusVPNAction.connect.rawValue, "connect")
        XCTAssertEqual(FocusVPNAction.disconnect.rawValue, "disconnect")
        XCTAssertEqual(FocusVPNAction.noChange.rawValue, "noChange")
    }

    func testIntentCarriesConfiguredAction() {
        let intent = QingzhouFocusFilterIntent(action: .connect)
        XCTAssertEqual(intent.action, .connect)
        XCTAssertEqual(intent.action.tunnelCommand, .start)
    }
}
