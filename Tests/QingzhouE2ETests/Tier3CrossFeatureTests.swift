import XCTest
import Foundation
import Darwin
import QingzhouCore
import QingzhouRules
import QingzhouProtocols
import QingzhouSubscription
import XrayConfig
import XrayCore
import QingzhouGuardRelayCore
@testable import QingzhouApp

final class Tier3CrossFeatureTests: XCTestCase {

    // 1. F1 + F2: Live AppState.sendControlCommand <-> RelayServer
    func test_T3_01_F1PlusF2_AppStateSendControlCommandLiveWithRelayServer() async throws {
        let dir = try TestFixtures.makeTempDirectory(prefix: "t3-01")
        defer { try? FileManager.default.removeItem(at: dir) }

        let tz = FakeTimeZoneProvider(initial: "Asia/Shanghai")
        let relayAuth = try XCTUnwrap(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_u", pass: "fwd_p"),
            control: CredentialPair(user: "ctrl_u", pass: "ctrl_p")
        ))
        let cfg = RelayConfig(
            port: 0,
            controlPort: 0,
            authFile: dir.appendingPathComponent("auth").path,
            logPath: dir.appendingPathComponent("relay.log").path,
            tzOrigPath: dir.appendingPathComponent("timezone-orig").path
        )
        let server = RelayServer(
            config: cfg,
            creds: relayAuth,
            logger: RelayLogger(logPath: cfg.logPath),
            timeZoneProvider: tz,
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        defer { server.stop() }
        let controlPort = try XCTUnwrap(ports.controlPort)

        let creds = TestFixtures.makeSeparatedCredentials(
            forwardUser: "fwd_u",
            forwardPass: "fwd_p",
            controlUser: "ctrl_u",
            controlPass: "ctrl_p",
            port: ports.forwardPort,
            controlPort: controlPort
        )

        try await AppState.sendControlCommand("SET-TZ America/New_York", creds: creds)
        XCTAssertEqual(tz.currentTimeZone(), "America/New_York")

        try await AppState.sendControlCommand("SET-TZ Asia/Shanghai", creds: creds)
        XCTAssertEqual(tz.currentTimeZone(), "Asia/Shanghai")

        try await AppState.sendControlCommand("SET-TZ Asia/Tokyo", creds: creds)
        XCTAssertEqual(tz.currentTimeZone(), "Asia/Tokyo")

        try await AppState.sendControlCommand("RESTORE", creds: creds)
        XCTAssertEqual(tz.currentTimeZone(), "Asia/Shanghai")

        // Invalid timezone -> ERR zone
        do {
            try await AppState.sendControlCommand("SET-TZ Bad/Zone", creds: creds)
            XCTFail("Expected error for invalid timezone")
        } catch let err as URLError {
            XCTAssertEqual(err.code, .badServerResponse)
        }

        // Wrong control password -> ERR auth
        let wrongCreds = TestFixtures.makeSeparatedCredentials(
            forwardUser: "fwd_u",
            forwardPass: "fwd_p",
            controlUser: "ctrl_u",
            controlPass: "wrong_pass",
            port: ports.forwardPort,
            controlPort: controlPort
        )
        do {
            try await AppState.sendControlCommand("RESTORE", creds: wrongCreds)
            XCTFail("Expected auth error")
        } catch let err as URLError {
            XCTAssertEqual(err.code, .userAuthenticationRequired)
        }
    }

    // 2. F1 + F4: SplitExitPlan(relay:) validated by XrayCore.testConfig + live RelayServer SOCKS5 & DNS
    func test_T3_02_F1PlusF4_SplitExitPlanRelayWithLiveRelayServerSOCKS5AndDNS() throws {
        let dir = try TestFixtures.makeTempDirectory(prefix: "t3-02")
        defer { try? FileManager.default.removeItem(at: dir) }

        let echoServer = try LoopbackTCPEchoServer()
        defer { echoServer.stop() }
        let udpDNS = try LoopbackUDPStubDNS { req, txid in
            [LoopbackUDPStubDNS.buildAResponse(for: req, txid: txid, ipOctets: [127, 0, 0, 1])]
        }
        defer { udpDNS.stop() }

        let fullCreds = TestFixtures.makeSeparatedCredentials()
        let fwdCreds = try XCTUnwrap(GuardRelayCredentials.decode(fullCreds.jsonString)?.forwardingOnly)
        let relayAuth = try XCTUnwrap(RelayAuthCredentials(
            forwarding: CredentialPair(user: fwdCreds.username, pass: fwdCreds.password),
            control: CredentialPair(user: fullCreds.controlUsername!, pass: fullCreds.controlPassword!)
        ))
        let cfg = RelayConfig(
            port: 0,
            controlPort: 0,
            authFile: dir.appendingPathComponent("auth").path,
            logPath: dir.appendingPathComponent("relay.log").path,
            tzOrigPath: dir.appendingPathComponent("timezone-orig").path
        )
        let server = RelayServer(
            config: cfg,
            creds: relayAuth,
            logger: RelayLogger(logPath: cfg.logPath),
            dns: RelayDNS(servers: [RelayDNS.Server(host: "127.0.0.1", port: udpDNS.port)]),
            timeZoneProvider: FakeTimeZoneProvider(),
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        defer { server.stop() }

        let (exit, hop) = TestFixtures.makeSplitExitNodes()
        let plan = SplitExitPlan(
            exitNode: exit,
            hopNode: hop,
            lists: SplitExitPlan.Lists(cnDomains: ["custom-cn.example.org"], cnCIDRs: ["1.0.1.0/24"]),
            blockQUIC: true,
            relay: SplitExitPlan.RelayEndpoint(
                host: fwdCreds.host,
                port: ports.forwardPort,
                username: fwdCreds.username,
                password: fwdCreds.password
            )
        )
        let xrayJSON = try plan.composeJSON(tunInterfaceName: "utun9")
        XCTAssertNoThrow(try TestFixtures.runXrayTestConfig(xrayJSON))

        // Live SOCKS5 forward through the exact same forwardPort + forwardingOnly creds
        let fd = try LoopbackIO.connectLoopback(port: ports.forwardPort)
        defer { Darwin.close(fd) }
        let (auth, rep) = try LoopbackIO.socks5Handshake(
            fd: fd,
            user: fwdCreds.username,
            pass: fwdCreds.password,
            targetHost: "custom-cn.example.org",
            targetPort: echoServer.port
        )
        XCTAssertEqual(auth, 0x00)
        XCTAssertEqual(rep, 0x00)
        let payload = Array("relay-split-exit-e2e".utf8)
        try LoopbackIO.writeAll(fd, bytes: payload)
        Darwin.shutdown(fd, SHUT_WR)
        XCTAssertEqual(try LoopbackIO.readAllUntilEOF(fd), payload)
    }

    // 3. F2 + F5: GuardRelayCredentials + SplitExitPlan xray-config.json -> sandboxed enable.sh
    func test_T3_03_F2PlusF5_GuardRelayCredentialsAndSplitExitPlanEnableShSandbox() throws {
        #if os(macOS)
        let sandbox = try ShellSandboxHarness(repoRoot: TestFixtures.repoRoot)
        defer { sandbox.cleanup() }

        let creds = TestFixtures.makeSeparatedCredentials(port: 10808, controlPort: 10809)
        let decoded = try XCTUnwrap(GuardRelayCredentials.decode(creds.jsonString))
        let fwd = decoded.forwardingOnly

        let (exit, hop) = TestFixtures.makeSplitExitNodes()
        let plan = SplitExitPlan(
            exitNode: exit,
            hopNode: hop,
            relay: SplitExitPlan.RelayEndpoint(host: fwd.host, port: fwd.port, username: fwd.username, password: fwd.password)
        )
        let xrayJSON = try plan.composeJSON(tunInterfaceName: "utun9")
        try sandbox.writeXrayConfig(xrayJSON)
        try sandbox.writeFreshRelayLog()
        try "\(fwd.port)".write(to: sandbox.baseURL.appendingPathComponent("port"), atomically: true, encoding: .utf8)

        let res = try sandbox.runScript("enable.sh")
        XCTAssertEqual(res.exitCode, 0, res.stderr)
        XCTAssertTrue(sandbox.readAnchorRules().contains("pass out quick on utun9 all"))
        #else
        throw XCTSkip("Shell sandbox tests require macOS Process")
        #endif
    }

    // 4. F3 + F4: Dual-mode XrayCore.testConfig contract (UseIP vs UseIPv4 FakeDNS)
    func test_T3_04_F3PlusF4_XrayCoreTestConfigDualContractUseIPVsUseIPv4() throws {
        let node = try ProxyURLParser.parse("vless://11111111-1111-1111-1111-111111111111@vless.example.com:443?security=tls&type=tcp#V")
        let outboundsJSON = try NodeConverter.toOutboundsJSON(node)
        let rules = RuleParser.parseAll("""
        DOMAIN-SUFFIX,openai.com,PROXY
        IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
        PROCESS-NAME,Safari,PROXY
        FINAL,PROXY
        """).rules

        let normalJSON = try XrayConfigComposer.compose(
            outboundsJSON: outboundsJSON,
            mode: .rule,
            userRules: rules,
            hasFullGeoIP: false,
            tunInterfaceName: "utun9",
            blockQUIC: true
        )
        XCTAssertNoThrow(try TestFixtures.runXrayTestConfig(normalJSON))
        let normalDict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(normalJSON.utf8)) as? [String: Any])
        XCTAssertEqual((normalDict["dns"] as? [String: Any])?["queryStrategy"] as? String, "UseIP")
        XCTAssertEqual((normalDict["fakedns"] as? [[String: Any]])?.count, 2)

        let (exit, hop) = TestFixtures.makeSplitExitNodes()
        let splitJSON = try SplitExitPlan(
            exitNode: exit,
            hopNode: hop,
            blockQUIC: true,
            policyGroups: [SplitExitPolicyGroup(name: "AI", target: .exit, geoSites: ["anthropic"])]
        ).composeJSON(tunInterfaceName: "utun9")
        XCTAssertNoThrow(try TestFixtures.runXrayTestConfig(splitJSON))
        let splitDict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(splitJSON.utf8)) as? [String: Any])
        XCTAssertEqual((splitDict["dns"] as? [String: Any])?["queryStrategy"] as? String, "UseIPv4")
        XCTAssertEqual((splitDict["fakedns"] as? [[String: Any]])?.count, 1)
    }

    // 5. F3 + F5: RoutingRuleConverter diagnostics mapped to 4-language Localizable.xcstrings keys
    func test_T3_05_F3PlusF5_RoutingRuleConverterDiagnosticsMappedToLocalizedXCStrings() throws {
        let rules = RuleParser.parseAll("""
        PROCESS-NAME,Telegram,PROXY
        USER-AGENT,Slack,DIRECT
        IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
        GEOIP,US,PROXY
        GEOSITE,unknown-site,PROXY
        """).rules
        let conv = RoutingRuleConverter.xrayRulesWithDiagnostics(from: rules, hasFullGeoIP: false)
        XCTAssertEqual(conv.diagnostics.count, 5)

        struct Catalog: Decodable {
            struct Entry: Decodable {
                struct Loc: Decodable {
                    struct Unit: Decodable { let value: String? }
                    let stringUnit: Unit?
                }
                let localizations: [String: Loc]?
            }
            let strings: [String: Entry]
        }
        let catalogURL = TestFixtures.repoRoot.appendingPathComponent("Apps/App-Shared/Localizable.xcstrings")
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))

        let uiDiagnosticKeys = [
            "PROCESS-NAME 仅用于本机规则模拟与命中归因，xray TUN 隧道不匹配进程名。",
            "USER-AGENT 仅用于本机规则模拟，xray TUN 隧道无法匹配 HTTP User-Agent。",
            "xray 隧道无单条 no-resolve 开关，规则模式全局使用 IPIfNonMatch。",
            "「%@」需下载完整版 geo 数据后才会生效（内置精简版仅含 cn / private）",
            "「%@」不在内置 geosite 分类白名单里，这条规则会被跳过。",
        ]
        for key in uiDiagnosticKeys {
            let entry = try XCTUnwrap(catalog.strings[key], "Missing key: \(key)")
            for lang in ["en", "ja", "zh-Hant"] {
                let val = entry.localizations?[lang]?.stringUnit?.value ?? ""
                XCTAssertFalse(val.isEmpty, "Missing \(lang) for diagnostic key: \(key)")
            }
        }
    }

    // 6. F4 + F5: SplitExitListsUpdater + GeoSiteCNMatcher parity & SplitExitListsView isolation
    func test_T3_06_F4PlusF5_SplitExitListsUpdaterGeoSiteCNParityAndMacOSIsolation() async throws {
        #if os(macOS)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.currentDirectoryURL = TestFixtures.repoRoot
        proc.arguments = ["scripts/extract-geosite-cn.py", "--check"]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "geosite-cn.txt must stay in sync with geosite.dat")
        #endif

        let store = InMemorySplitExitListsStore()
        let client = StubHTTPClient(routes: [
            "direct.txt": .success("+.jd.com\n+.custom-unique.example.org\n"),
            "cncidr.txt": .success("1.0.1.0/24\n"),
        ])
        let updater = SplitExitListsUpdater(
            client: client,
            sources: [
                URL(string: "https://stub.local/direct.txt")!,
                URL(string: "https://stub.local/cncidr.txt")!,
            ],
            store: store,
            geoSiteCNMatcher: .bundled
        )
        let outcome = await updater.refresh(force: true)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.metrics?.deduplicatedByGeoSiteCNCount, 1)
        XCTAssertEqual(outcome.lists?.domains, ["custom-unique.example.org"])

        let viewPath = TestFixtures.repoRoot.appendingPathComponent("Sources/QingzhouApp/SplitExitListsView.swift")
        let viewSource = try String(contentsOf: viewPath, encoding: .utf8)
        XCTAssertTrue(viewSource.hasPrefix("#if os(macOS)") || viewSource.contains("#if os(macOS)"))
    }

    // 7. F1 + F5: RelayServer persists timezone-orig -> consumed by sandboxed uninstall.sh
    func test_T3_07_F1PlusF5_RelayServerTimezoneOrigConsumedBySandboxUninstallSh() throws {
        #if os(macOS)
        let sandbox = try ShellSandboxHarness(repoRoot: TestFixtures.repoRoot)
        defer { sandbox.cleanup() }

        let tzOrigURL = sandbox.baseURL.appendingPathComponent("timezone-orig")
        let tz = FakeTimeZoneProvider(initial: "Asia/Shanghai")
        let relayAuth = try XCTUnwrap(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_u", pass: "fwd_p"),
            control: CredentialPair(user: "ctrl_u", pass: "ctrl_p")
        ))
        let cfg = RelayConfig(
            port: 0,
            controlPort: 0,
            authFile: sandbox.baseURL.appendingPathComponent("relay-auth").path,
            logPath: sandbox.logsURL.appendingPathComponent("qingzhou-relay.log").path,
            tzOrigPath: tzOrigURL.path
        )
        let server = RelayServer(
            config: cfg,
            creds: relayAuth,
            logger: RelayLogger(logPath: cfg.logPath),
            timeZoneProvider: tz,
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        let controlPort = try XCTUnwrap(ports.controlPort)

        let fd = try LoopbackIO.connectLoopback(port: controlPort)
        try LoopbackIO.writeLine(fd, "AUTH ctrl_u ctrl_p")
        XCTAssertEqual(try LoopbackIO.readLine(fd), "OK")
        try LoopbackIO.writeLine(fd, "SET-TZ America/New_York")
        XCTAssertEqual(try LoopbackIO.readLine(fd), "OK")
        Darwin.close(fd)
        server.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: tzOrigURL.path))

        let res = try sandbox.runScript("uninstall.sh")
        XCTAssertEqual(res.exitCode, 0, res.stderr)
        let calls = sandbox.readCallsLog()
        XCTAssertTrue(calls.contains("systemsetup -settimezone Asia/Shanghai"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.baseURL.path))
        #else
        throw XCTSkip("Shell sandbox tests require macOS Process")
        #endif
    }

    // 8. F2 + F3: Share link -> NodeConverter -> XrayConfigComposer + GuardRelayCredentials separation
    func test_T3_08_F2PlusF3_ShareLinkToXrayConfigWithSeparatedGuardRelayCredentialsInvariant() throws {
        let shareLinks = [
            "trojan://pw1@t1.example.com:443?sni=t1.example.com#Trojan",
            "vless://11111111-1111-1111-1111-111111111111@v1.example.com:443?security=tls&type=tcp#VLESS",
            "socks5://user:pass@s1.example.com:1080#SOCKS5",
        ]
        for link in shareLinks {
            let node = try ProxyURLParser.parse(link)
            let outboundsJSON = try NodeConverter.toOutboundsJSON(node)
            let configJSON = try XrayConfigComposer.compose(
                outboundsJSON: outboundsJSON,
                mode: .rule,
                userRules: [Rule(type: .domainSuffix, value: "example.org", target: .proxy)],
                tunInterfaceName: "utun9"
            )
            XCTAssertNoThrow(try TestFixtures.runXrayTestConfig(configJSON))
        }

        let creds = TestFixtures.makeSeparatedCredentials()
        let decoded = try XCTUnwrap(GuardRelayCredentials.decode(creds.jsonString))
        XCTAssertTrue(decoded.hasValidControlCredentials)
        XCTAssertFalse(decoded.forwardingOnly.hasValidControlCredentials)
    }
}
