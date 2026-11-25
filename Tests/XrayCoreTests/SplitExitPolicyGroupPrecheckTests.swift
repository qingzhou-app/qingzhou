import XCTest
import QingzhouCore
import XrayConfig
@testable import XrayCore

final class SplitExitPolicyGroupPrecheckTests: XCTestCase {
    func testSplitExitPlanWithPolicyGroupsPassesXrayTestConfig() throws {
        let exit = Node(
            name: "Exit",
            protocolType: .socks5,
            host: "203.0.113.9",
            port: 1080,
            password: "p@ss",
            parameters: ["username": "u"]
        )
        let hop = Node(
            name: "Hop",
            protocolType: .trojan,
            host: "hk.example.com",
            port: 443,
            password: "pw"
        )
        let groups = [
            SplitExitPolicyGroup(
                name: "Exit Custom",
                target: .exit,
                domains: ["custom-exit.example.com"],
                fullDomains: ["api.custom-exit.example.com"],
                keywords: ["exitkw"],
                geoSites: ["anthropic"],
                cidrs: ["198.51.100.0/24"]
            ),
            SplitExitPolicyGroup(
                name: "Direct Custom",
                target: .direct,
                domains: ["custom-direct.example.cn"],
                geoSites: ["bilibili"],
                cidrs: ["192.0.2.0/24"]
            ),
            SplitExitPolicyGroup(
                name: "Reject Custom",
                target: .reject,
                geoSites: ["category-ads-all"],
                cidrs: ["203.0.113.128/25"]
            )
        ]
        let plan = SplitExitPlan(
            exitNode: exit,
            hopNode: hop,
            lists: SplitExitPlan.Lists(cnDomains: ["extra.example.org"], cnCIDRs: ["1.0.1.0/24"]),
            blockQUIC: true,
            rejectOverseasUDP: true,
            policyGroups: groups
        )
        let configJSON = try plan.composeJSON(tunInterfaceName: "utun9")
        let datDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Apps/Tunnel-Shared/Resources").path
        XCTAssertNoThrow(try XrayCore.testConfig(configJSON: configJSON, datDir: datDir))
    }

    func testSplitExitPayloadPreflightValidatesRelayGroupsBlockQUICAndNormalMode() throws {
        let datDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Apps/Tunnel-Shared/Resources").path

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let exit = Node(
            name: "Exit",
            protocolType: .socks5,
            host: "203.0.113.9",
            port: 1080,
            password: "p@ss",
            parameters: ["username": "u"]
        )
        let hop = Node(
            name: "Hop",
            protocolType: .trojan,
            host: "hk.example.com",
            port: 443,
            password: "pw"
        )
        let exitJSON = String(data: try encoder.encode(exit), encoding: .utf8)!
        let hopJSON = String(data: try encoder.encode(hop), encoding: .utf8)!
        let relayJSON = GuardRelayCredentials(port: 10808, username: "fwd_u", password: "fwd_p").jsonString
        let groupsJSON = String(data: try JSONEncoder().encode([
            SplitExitPolicyGroup(name: "Test", target: .exit, domains: ["service.example.com"])
        ]), encoding: .utf8)!

        // 1. splitExit == true valid payload passes XrayCore.testConfig
        let plan = try SplitExitPlan.fromPayload(
            exitNodeJSON: exitJSON,
            hopNodeJSON: hopJSON,
            guardRelayJSON: relayJSON,
            policyGroupsJSON: groupsJSON,
            blockQUIC: true
        )
        let splitJSON = try plan.composeJSON(accessLogPath: nil, tunInterfaceName: "utun9")
        XCTAssertNoThrow(try XrayCore.testConfig(configJSON: splitJSON, datDir: datDir))

        // 2. splitExit == true with hopEqualsExit fails before XrayCore.testConfig
        let sameUpper = Node(name: "Dup", protocolType: .socks5, host: "EXIT.EXAMPLE.COM", port: 1080, password: "p")
        let sameLower = Node(name: "Dup2", protocolType: .socks5, host: "exit.example.com", port: 1080, password: "p")
        let invalidPlan = try SplitExitPlan.fromPayload(
            exitNodeJSON: String(data: try encoder.encode(sameLower), encoding: .utf8)!,
            hopNodeJSON: String(data: try encoder.encode(sameUpper), encoding: .utf8)!
        )
        XCTAssertThrowsError(try invalidPlan.composeJSON(accessLogPath: nil, tunInterfaceName: "utun9")) { error in
            XCTAssertEqual(error as? SplitExitPlan.PlanError, .hopEqualsExit)
        }

        // 3. splitExit == false normal-mode compose passes XrayCore.testConfig
        let normalOutbounds = try NodeConverter.toOutboundsJSON(hop)
        let normalJSON = try XrayConfigComposer.compose(
            outboundsJSON: normalOutbounds,
            mode: .rule,
            accessLogPath: nil,
            userRules: [],
            hasFullGeoIP: false,
            tunInterfaceName: "utun9",
            blockQUIC: true
        )
        XCTAssertNoThrow(try XrayCore.testConfig(configJSON: normalJSON, datDir: datDir))
    }
}
