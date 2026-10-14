import XCTest
@testable import QingzhouCore

final class NodeProbeCooldownTests: XCTestCase {
    func testConfirmedFailureExpiresAndDoesNotAffectDifferentIdentity() {
        var state = NodeProbeCooldown()
        let at = Date(timeIntervalSince1970: 1000)
        state.confirm(["identity-a"], now: at)
        XCTAssertTrue(state.contains("identity-a", now: at.addingTimeInterval(299)))
        XCTAssertFalse(state.contains("identity-a", now: at.addingTimeInterval(300)))
        XCTAssertFalse(state.contains("identity-new-credentials", now: at))
    }
    func testSuccessfulRetestAndSessionResetRestoreEligibility() {
        var state = NodeProbeCooldown()
        let at = Date(timeIntervalSince1970: 1000)
        state.confirm(["a", "b"], now: at)
        state.recover("a")
        XCTAssertFalse(state.contains("a", now: at))
        XCTAssertTrue(state.contains("b", now: at))
        state.reset()
        XCTAssertFalse(state.contains("b", now: at))
    }
}
