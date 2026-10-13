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

    func testEmptyRuleSetIsKnownWhileOldMetadataDigestRemainsUnknown() throws {
        let node = Node(name: "A", protocolType: .trojan, host: "a.example", port: 443, password: "pw")
        let empty = AppliedTunnelConfiguration(node: node, mode: .rule, blockQUIC: true,
            rulesDigest: AppliedTunnelConfiguration.digestRules([]))
        XCTAssertEqual(empty.rulesDigest, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(empty)) as? [String: Any])
        legacy.removeValue(forKey: "rulesDigest")
        let decoded = try JSONDecoder().decode(AppliedTunnelConfiguration.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.rulesDigest)
    }

    func testRulesMetadataDoesNotPublishPrivateDomains() throws {
        let node = Node(name: "A", protocolType: .trojan, host: "a.example", port: 443, password: "pw")
        let rules = [Rule(type: .domainSuffix, value: "private-domain.example", target: .proxy)]
        let applied = AppliedTunnelConfiguration(node: node, mode: .rule, blockQUIC: true,
            rulesDigest: AppliedTunnelConfiguration.digestRules(rules))
        let encoded = String(decoding: try JSONEncoder().encode(applied), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-domain.example"))
    }
}
