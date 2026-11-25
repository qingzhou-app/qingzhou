import Foundation
import QingzhouCore
import QingzhouProtocols
import XrayConfig
import XrayCore

enum TestFixtures {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // QingzhouE2ETests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    static var bundledDatDir: String {
        repoRoot.appendingPathComponent("Apps/Tunnel-Shared/Resources").path
    }

    private static let xrayTestLock = NSLock()

    /// Serializes `XrayCore.testConfig` invocations so process-global `xray.location.asset`
    /// always points to `bundledDatDir` and never races across tests.
    static func runXrayTestConfig(_ configJSON: String) throws {
        xrayTestLock.lock()
        defer { xrayTestLock.unlock() }
        try XrayCore.testConfig(configJSON: configJSON, datDir: bundledDatDir)
    }

    static func makeTempDirectory(prefix: String = "qingzhou-e2e") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func makeSplitExitNodes() -> (exit: Node, hop: Node) {
        let exit = Node(
            name: "Residential-Exit",
            protocolType: .socks5,
            host: "203.0.113.42",
            port: 1080,
            password: "exit-pass-123",
            parameters: ["username": "exit-user"]
        )
        let hop = Node(
            name: "HK-Hop",
            protocolType: .trojan,
            host: "hk-hop.example.net",
            port: 443,
            password: "hop-secret-password"
        )
        return (exit, hop)
    }

    static func makeSeparatedCredentials(
        forwardUser: String = "fwd_user",
        forwardPass: String = "fwd_pass_!@#",
        controlUser: String = "ctrl_user",
        controlPass: String = "ctrl_pass_!@#",
        port: UInt16 = 10808,
        controlPort: UInt16? = 10809
    ) -> GuardRelayCredentials {
        GuardRelayCredentials(
            host: "127.0.0.1",
            port: port,
            username: forwardUser,
            password: forwardPass,
            controlPort: controlPort,
            controlUsername: controlUser,
            controlPassword: controlPass
        )
    }

    static let xcstringsRelativePaths: [String] = [
        "Apps/App-Shared/Localizable.xcstrings",
        "Apps/App-Shared/AppShortcuts.xcstrings",
        "Apps/App-Shared/InfoPlist.xcstrings",
        "Apps/Tunnel-Shared/Localizable.xcstrings",
        "Apps/Widget-Shared/Localizable.xcstrings",
    ]
}
