import XCTest
@testable import QingzhouCore

final class AppliedTunnelConfigurationTests: XCTestCase {
    func testIdentityTracksTransportButDoesNotPublishCredentials() throws {
        let node = Node(name: "A", protocolType: .trojan, host: "a.example", port: 443, password: "private-password-123")
        let applied = AppliedTunnelConfiguration(node: node, mode: .global, blockQUIC: true)
        var renamed = node; renamed.name = "B"; renamed.parameters["rate"] = "2"
        XCTAssertTrue(applied.matches(renamed))
        var changed = node; changed.parameters["sni"] = "b.example"
        XCTAssertFalse(applied.matches(changed))
        let encoded = String(decoding: try JSONEncoder().encode(applied), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-password-123"))
    }

    func testOldSessionAndTrafficRemainReadableWithoutClaimingConfiguration() throws {
        let session = try JSONDecoder().decode(TunnelSessionInfo.self,
            from: Data("{\"startedAt\":0,\"autoStopSeconds\":0}".utf8))
        XCTAssertNil(session.appliedConfiguration)
        let traffic = try JSONDecoder().decode(TrafficStats.self,
            from: Data("{\"uploadBytes\":0,\"downloadBytes\":0,\"uploadSpeedBps\":0,\"downloadSpeedBps\":0,\"activeConnections\":0,\"sampledAt\":0}".utf8))
        XCTAssertNil(traffic.configurationID)
    }
}
