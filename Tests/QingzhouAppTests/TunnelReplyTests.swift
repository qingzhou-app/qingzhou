import XCTest
@testable import QingzhouApp

final class TunnelReplyTests: XCTestCase {
    func testOnlyExplicitSuccessAcknowledgementIsAccepted() throws {
        for reply in [nil, Data(), Data("null".utf8), Data("{}".utf8), Data("{\"ok\":\"true\"}".utf8)] as [Data?] {
            XCTAssertThrowsError(try VPNTunnelManager.decodeReply(reply, failureLabel: "failed"))
        }
        let payload = try VPNTunnelManager.decodeReply(Data("{\"ok\":true,\"delayMs\":42}".utf8), failureLabel: "failed")
        XCTAssertEqual(payload["delayMs"] as? Int, 42)
    }

    func testConfigurationRejectionRetainsTypedMeaning() {
        XCTAssertThrowsError(try VPNTunnelManager.decodeReply(
            Data("{\"ok\":false,\"error\":\"invalid port\"}".utf8), failureLabel: "failed", rejectionAsConfigError: true)) { error in
            guard case VPNTunnelManager.TunnelError.configRejected(let reason) = error else {
                return XCTFail("Expected explicit configuration rejection")
            }
            XCTAssertEqual(reason, "invalid port")
        }
    }
}
