import XCTest
import QingzhouCore
@testable import XrayConfig

final class PublicIPRoutingTests: XCTestCase {
    func testIPProbeAlwaysUsesProxyBeforeUserAndModeRules() throws {
        for mode in [ProxyMode.rule, .global, .direct] {
            let json = try XrayConfigComposer.compose(outboundsJSON: #"{"outbounds":[{"protocol":"freedom"}]}"#, mode: mode, publicIPPort: 32123)
            let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            let inbound = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "public-ip-in" })
            XCTAssertEqual(inbound["listen"] as? String, "127.0.0.1")
            XCTAssertEqual(inbound["port"] as? Int, 32123)
            let settings = inbound["settings"] as! [String: Any]
            XCTAssertEqual(settings["address"] as? String, "ipwho.is")
            XCTAssertEqual(settings["port"] as? Int, 443)
            XCTAssertNil(settings["followRedirect"])
            let rules = (root["routing"] as! [String: Any])["rules"] as! [[String: Any]]
            XCTAssertEqual(rules.first?["inboundTag"] as? [String], ["public-ip-in"])
            XCTAssertEqual(rules.first?["outboundTag"] as? String, "proxy")
        }
    }
}
