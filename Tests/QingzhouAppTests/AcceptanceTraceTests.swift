#if DEBUG
import XCTest
@testable import QingzhouApp

@MainActor
final class AcceptanceTraceTests: XCTestCase {
    override func tearDown() async throws {
        AcceptanceTrace.end()
        try await super.tearDown()
    }

    func testInactiveTraceDoesNotCollectAndNewRecordingClearsPreviousRun() {
        AcceptanceTrace.begin()
        AcceptanceTrace.record(.remoteRulesChanged)
        AcceptanceTrace.end()
        AcceptanceTrace.record(.reapplyFullStarted)
        XCTAssertEqual(AcceptanceTrace.events.map(\.kind), [.remoteRulesChanged])
        AcceptanceTrace.begin()
        AcceptanceTrace.record(.adopted)
        XCTAssertEqual(AcceptanceTrace.events.map(\.kind), [.adopted])
    }

    func testRecordingRetainsRecentEventsWithinBoundedWindow() {
        AcceptanceTrace.begin()
        for _ in 0..<200 { AcceptanceTrace.record(.remoteRulesChanged) }
        AcceptanceTrace.record(.cleanRestart)
        XCTAssertLessThan(AcceptanceTrace.events.count, 200)
        XCTAssertEqual(AcceptanceTrace.events.last?.kind, .cleanRestart)
    }
}
#endif
