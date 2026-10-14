import XCTest
import QingzhouCore
@testable import QingzhouApp

final class ProxyProbeReplyTests: XCTestCase {
    func testStructuredProbeFailureSurvivesTransportDecoding() throws {
        let data = Data(#"{"ok":false,"failureKind":"resourceLimited","error":"busy"}"#.utf8)
        XCTAssertThrowsError(try VPNTunnelManager.decodeReply(data, failureLabel: "failed", rejectionAsProbeError: true)) {
            XCTAssertEqual(($0 as? ProxyProbeError)?.kind, .resourceLimited)
        }
    }
    func testLegacyAndUnknownFailuresStayUnclassified() {
        for json in [#"{"ok":false,"error":"failure"}"#, #"{"ok":false,"failureKind":"futureCode"}"#] {
            XCTAssertThrowsError(try VPNTunnelManager.decodeReply(Data(json.utf8), failureLabel: "failed", rejectionAsProbeError: true)) {
                XCTAssertEqual(($0 as? ProxyProbeError)?.kind, .unavailable)
            }
        }
    }
    func testOrdinaryCommandsDoNotBecomeProbeErrors() {
        let data = Data(#"{"ok":false,"failureKind":"probeFailed","error":"bad"}"#.utf8)
        XCTAssertThrowsError(try VPNTunnelManager.decodeReply(data, failureLabel: "failed")) {
            XCTAssertTrue($0 is VPNTunnelManager.TunnelError)
        }
    }
}
