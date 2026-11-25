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
}
