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

final class Tier4ApplicationScenariosTests: XCTestCase {

    // Scenario 1: End-to-End Mac Guard + Split-Exit Session
    func test_T4_01_EndToEndMacGuardAndSplitExitSession() async throws {
        let dir = try TestFixtures.makeTempDirectory(prefix: "t4-01")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Update split-exit lists from realistic CN/non-CN feed with GeoSiteCNMatcher dedup
        let store = InMemorySplitExitListsStore()
        let client = StubHTTPClient(routes: [
            "direct.txt": .success("""
            payload:
              - '+.baidu.com'
              - '+.qq.com'
              - '+.taobao.com'
              - '+.regional-bank.example.org'
            DOMAIN-KEYWORD,alipay
            """),
            "cncidr.txt": .success("""
            payload:
              - '1.0.1.0/24'
              - '223.5.5.0/24'
            """),
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
        let lists = try XCTUnwrap(outcome.lists)
        XCTAssertEqual(lists.domains, ["regional-bank.example.org"])

        // 2. Boot live RelayServer with loopback echo & UDP DNS stub
        let echoServer = try LoopbackTCPEchoServer()
        defer { echoServer.stop() }
        let udpDNS = try LoopbackUDPStubDNS { req, txid in
            [LoopbackUDPStubDNS.buildAResponse(for: req, txid: txid, ipOctets: [127, 0, 0, 1])]
        }
        defer { udpDNS.stop() }

        let tz = FakeTimeZoneProvider(initial: "Asia/Shanghai")
        let relayAuth = try XCTUnwrap(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_s1", pass: "fwd_pass_s1"),
            control: CredentialPair(user: "ctrl_s1", pass: "ctrl_pass_s1")
        ))
        let cfg = RelayConfig(
            port: 0,
            controlPort: 0,
            authFile: dir.appendingPathComponent("relay-auth").path,
            logPath: dir.appendingPathComponent("relay.log").path,
            tzOrigPath: dir.appendingPathComponent("timezone-orig").path
        )
        let server = RelayServer(
            config: cfg,
            creds: relayAuth,
            logger: RelayLogger(logPath: cfg.logPath),
            dns: RelayDNS(servers: [RelayDNS.Server(host: "127.0.0.1", port: udpDNS.port)]),
            timeZoneProvider: tz,
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        defer { server.stop() }
        let controlPort = try XCTUnwrap(ports.controlPort)

        let creds = TestFixtures.makeSeparatedCredentials(
            forwardUser: "fwd_s1",
            forwardPass: "fwd_pass_s1",
            controlUser: "ctrl_s1",
            controlPass: "ctrl_pass_s1",
            port: ports.forwardPort,
            controlPort: controlPort
        )

        // 3. Compose SplitExitPlan with policy groups & relay and validate with XrayCore.testConfig
        let (exit, hop) = TestFixtures.makeSplitExitNodes()
        let plan = SplitExitPlan(
            exitNode: exit,
            hopNode: hop,
            lists: SplitExitPlan.Lists(
                cnDomains: lists.domains,
                cnDomainKeywords: lists.domainKeywords,
                cnCIDRs: lists.cidrs
            ),
            blockQUIC: true,
            rejectOverseasUDP: true,
            relay: SplitExitPlan.RelayEndpoint(
                host: creds.host,
                port: creds.port,
                username: creds.username,
                password: creds.password
            ),
            policyGroups: [
                SplitExitPolicyGroup(name: "AI", target: .exit, geoSites: ["anthropic"]),
                SplitExitPolicyGroup(name: "Bank", target: .direct, domains: ["regional-bank.example.org"]),
                SplitExitPolicyGroup(name: "BlockAds", target: .reject, geoSites: ["category-ads-all"]),
            ]
        )
        XCTAssertNoThrow(try TestFixtures.runXrayTestConfig(try plan.composeJSON(tunInterfaceName: "utun9")))

        // 4. Switch timezone via AppState.sendControlCommand -> switch back -> restore
        try await AppState.sendControlCommand("SET-TZ America/New_York", creds: creds)
        XCTAssertEqual(tz.currentTimeZone(), "America/New_York")
        try await AppState.sendControlCommand("SET-TZ Asia/Shanghai", creds: creds)
        XCTAssertEqual(tz.currentTimeZone(), "Asia/Shanghai")
        try await AppState.sendControlCommand("SET-TZ Asia/Tokyo", creds: creds)
        try await AppState.sendControlCommand("RESTORE", creds: creds)
        XCTAssertEqual(tz.currentTimeZone(), "Asia/Shanghai")

        // 5. Route traffic through SOCKS5 forwarder using domain resolved by RelayDNS
        let fd = try LoopbackIO.connectLoopback(port: ports.forwardPort)
        defer { Darwin.close(fd) }
        let (auth, rep) = try LoopbackIO.socks5Handshake(
            fd: fd,
            user: "fwd_s1",
            pass: "fwd_pass_s1",
            targetHost: "regional-bank.example.org",
            targetPort: echoServer.port
        )
        XCTAssertEqual(auth, 0x00)
        XCTAssertEqual(rep, 0x00)
        let bytes = Array("end-to-end-mac-guard-session".utf8)
        try LoopbackIO.writeAll(fd, bytes: bytes)
        Darwin.shutdown(fd, SHUT_WR)
        XCTAssertEqual(try LoopbackIO.readAllUntilEOF(fd), bytes)
    }

    // Scenario 2: End-to-End Multi-Rule Desktop/iOS Profile
    func test_T4_02_EndToEndMultiRuleDesktopAndIOSProfile() throws {
        let profileRulesText = """
        # Corporate & Streaming Profile
        DOMAIN,api.openai.com,PROXY
        DOMAIN-SUFFIX,claude.ai,PROXY
        DOMAIN-KEYWORD,analytics,REJECT
        IP-CIDR,10.0.0.0/8,DIRECT,no-resolve # corp intranet, RFC1918
        IP-CIDR6,fe80::/10,DIRECT,NO-RESOLVE
        GEOIP,CN,DIRECT,no-resolve
        GEOSITE,anthropic,PROXY
        PROCESS-NAME,Slack,PROXY
        USER-AGENT,CorporateClient/3.0,DIRECT
        FINAL,PROXY # default proxy, fallback
        """
        let parsed = RuleParser.parseAll(profileRulesText)
        XCTAssertTrue(parsed.errors.isEmpty)
        XCTAssertEqual(parsed.rules.count, 10)

        // Local RuleEngine simulation matches PROCESS-NAME & USER-AGENT
        let engine = RuleEngine(rules: parsed.rules)
        XCTAssertEqual(engine.match(MatchContext(host: "chat.example.com", processName: "Slack")).target, .proxy)
        XCTAssertEqual(engine.match(MatchContext(host: "update.example.com", userAgent: "CorporateClient/3.0")).target, .direct)

        // Xray conversion emits explicit diagnostics for PROCESS-NAME / USER-AGENT / no-resolve
        let conversion = RoutingRuleConverter.xrayRulesWithDiagnostics(from: parsed.rules, hasFullGeoIP: false)
        XCTAssertEqual(conversion.finalOutboundTag, "proxy")
        let diagKinds = Set(conversion.diagnostics.map(\.kind))
        XCTAssertTrue(diagKinds.contains(.unsupportedProcessName))
        XCTAssertTrue(diagKinds.contains(.unsupportedUserAgent))
        XCTAssertTrue(diagKinds.contains(.noResolveGlobalDomainStrategyCaveat))

        // Parse VLESS share link and compose full .rule config -> XrayCore.testConfig
        let node = try ProxyURLParser.parse("vless://22222222-2222-2222-2222-222222222222@edge.example.com:443?security=tls&type=tcp&sni=edge.example.com#ProfileVLESS")
        let outboundsJSON = try NodeConverter.toOutboundsJSON(node)
        let configJSON = try XrayConfigComposer.compose(
            outboundsJSON: outboundsJSON,
            mode: .rule,
            userRules: parsed.rules,
            hasFullGeoIP: false,
            tunInterfaceName: "utun9",
            blockQUIC: true
        )
        XCTAssertNoThrow(try TestFixtures.runXrayTestConfig(configJSON))
    }

    // Scenario 3: End-to-End Guard Shell Lifecycle
    func test_T4_03_EndToEndGuardShellLifecycle() throws {
        #if os(macOS)
        let sandbox = try ShellSandboxHarness(repoRoot: TestFixtures.repoRoot)
        defer { sandbox.cleanup() }

        // Prepare relay-auth, port files, timezone-orig, xray-config.json from real SplitExitPlan
        let relayAuthText = "forward:fwd_life:fp_life\ncontrol:ctrl_life:cp_life\n"
        XCTAssertNotNil(RelayAuthCredentials.parse(relayAuthText))
        try relayAuthText.write(to: sandbox.baseURL.appendingPathComponent("relay-auth"), atomically: true, encoding: .utf8)
        try "10808".write(to: sandbox.baseURL.appendingPathComponent("port"), atomically: true, encoding: .utf8)
        try "10809".write(to: sandbox.baseURL.appendingPathComponent("control-port"), atomically: true, encoding: .utf8)
        try "Asia/Shanghai".write(to: sandbox.baseURL.appendingPathComponent("timezone-orig"), atomically: true, encoding: .utf8)
        try "<plist/>".write(to: sandbox.plistURL, atomically: true, encoding: .utf8)

        let (exit, hop) = TestFixtures.makeSplitExitNodes()
        let xrayJSON = try SplitExitPlan(
            exitNode: exit,
            hopNode: hop,
            relay: SplitExitPlan.RelayEndpoint(host: "127.0.0.1", port: 10808, username: "fwd_life", password: "fp_life")
        ).composeJSON(tunInterfaceName: "utun9")
        try sandbox.writeXrayConfig(xrayJSON)
        try sandbox.writeFreshRelayLog()

        // Step 1: enable.sh
        try sandbox.setUtuns("utun9")
        let enableRes = try sandbox.runScript("enable.sh")
        XCTAssertEqual(enableRes.exitCode, 0, enableRes.stderr)
        XCTAssertTrue(sandbox.readAnchorRules().contains("pass out quick on utun9 all"))

        // Step 2: guard-run.sh transitions no-utun -> utun9 -> utun10 -> clean relay exit
        try sandbox.setUtuns("")
        let guardProc = try sandbox.startScriptAsync("guard-run.sh")
        defer {
            try? sandbox.triggerStopRelay()
            if guardProc.isRunning {
                guardProc.terminate()
                guardProc.waitUntilExit()
            }
        }
        let renderedURL = sandbox.baseURL.appendingPathComponent("qingzhou-guard.rendered.conf")
        var sawNoUtun = false
        for _ in 0..<30 {
            if let txt = try? String(contentsOf: renderedURL, encoding: .utf8) {
                let active = txt.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                if active.contains("block out quick all")
                    && !active.contains(where: { $0.contains("utun") || $0.contains("__TUN_DEV__") }) {
                    sawNoUtun = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(sawNoUtun)

        try sandbox.setUtuns("utun10")
        var sawUtun10 = false
        for _ in 0..<30 {
            if let txt = try? String(contentsOf: renderedURL, encoding: .utf8),
               txt.contains("pass out quick on utun10 all") {
                sawUtun10 = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(sawUtun10)
        try sandbox.triggerStopRelay()
        guardProc.waitUntilExit()
        XCTAssertEqual(guardProc.terminationStatus, 0)

        // Step 3: off.sh (anchor-only teardown, no pfctl -d)
        let offRes = try sandbox.runScript("off.sh")
        XCTAssertEqual(offRes.exitCode, 0, offRes.stderr)
        XCTAssertFalse(sandbox.readCallsLog().contains("FORBIDDEN pfctl -d"))

        // Step 4: uninstall.sh (restores timezone-orig, removes files)
        let uninstallRes = try sandbox.runScript("uninstall.sh")
        XCTAssertEqual(uninstallRes.exitCode, 0, uninstallRes.stderr)
        let calls = sandbox.readCallsLog()
        XCTAssertTrue(calls.contains("systemsetup -settimezone Asia/Shanghai"))
        XCTAssertFalse(calls.contains("FORBIDDEN pfctl -d"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.baseURL.path))
        #else
        throw XCTSkip("Shell sandbox lifecycle requires macOS Process")
        #endif
    }

    // Scenario 4: End-to-End Security & Resilience Stress
    func test_T4_04_EndToEndSecurityAndResilienceStress() async throws {
        let dir = try TestFixtures.makeTempDirectory(prefix: "t4-04")
        defer { try? FileManager.default.removeItem(at: dir) }

        let echoServer = try LoopbackTCPEchoServer()
        defer { echoServer.stop() }
        let udpDNS = try LoopbackUDPStubDNS { req, txid in
            // Always inject a forged-TXID packet before the valid packet
            let forged = LoopbackUDPStubDNS.buildAResponse(for: req, txid: txid ^ 0x55AA, ipOctets: [10, 99, 99, 99])
            let valid = LoopbackUDPStubDNS.buildAResponse(for: req, txid: txid, ipOctets: [127, 0, 0, 1])
            return [forged, valid]
        }
        defer { udpDNS.stop() }

        let clock = FakeClock()
        let dns = RelayDNS(
            servers: [RelayDNS.Server(host: "127.0.0.1", port: udpDNS.port)],
            ttl: 60,
            maxEntries: 8,
            timeoutSeconds: 2,
            nowProvider: { clock.now() }
        )
        let logger = RelayLogger(logPath: dir.appendingPathComponent("relay.log").path, maxBytes: 2048)
        let tz = FakeTimeZoneProvider(initial: "Asia/Shanghai")
        let relayAuth = try XCTUnwrap(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_stress", pass: "fp_stress"),
            control: CredentialPair(user: "ctrl_stress", pass: "cp_stress")
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
            logger: logger,
            dns: dns,
            timeZoneProvider: tz,
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        defer { server.stop() }
        let controlPort = try XCTUnwrap(ports.controlPort)

        // 1. Concurrent SOCKS5 connections with DNS cache churn + forged TXID defense
        await withTaskGroup(of: String?.self) { group in
            for i in 0..<10 {
                group.addTask {
                    do {
                        let fd = try LoopbackIO.connectLoopback(port: ports.forwardPort, timeoutSeconds: 5)
                        defer { Darwin.close(fd) }
                        let (auth, rep) = try LoopbackIO.socks5Handshake(
                            fd: fd,
                            user: "fwd_stress",
                            pass: "fp_stress",
                            targetHost: "host-\(i).stress.example.com",
                            targetPort: echoServer.port
                        )
                        guard auth == 0x00, rep == 0x00 else {
                            return "task \(i) bad SOCKS5 status auth=\(auth) rep=\(rep)"
                        }
                        let msg = Array("stress-msg-\(i)".utf8)
                        try LoopbackIO.writeAll(fd, bytes: msg)
                        Darwin.shutdown(fd, SHUT_WR)
                        let echoed = try LoopbackIO.readAllUntilEOF(fd)
                        if echoed != msg {
                            return "task \(i) echo mismatch got \(echoed.count) bytes"
                        }
                        return nil
                    } catch {
                        return "task \(i) threw \(error)"
                    }
                }
            }
            for await errMsg in group {
                XCTAssertNil(errMsg, errMsg ?? "")
            }
        }
        XCTAssertLessThanOrEqual(dns.cacheCount, 8)

        // 2. Oversized + unauthorized control attacks against live RelayServer
        do {
            let badFD = try LoopbackIO.connectLoopback(port: controlPort)
            defer { Darwin.close(badFD) }
            try LoopbackIO.writeLine(badFD, "AUTH fwd_stress fp_stress")
            XCTAssertEqual(try LoopbackIO.readLine(badFD), "ERR auth")
        }
        do {
            let bigFD = try LoopbackIO.connectLoopback(port: controlPort)
            defer { Darwin.close(bigFD) }
            try LoopbackIO.writeAll(bigFD, bytes: Array(repeating: 0x58, count: 1500))
            XCTAssertEqual(try LoopbackIO.readLine(bigFD), "ERR too-long")
        }

        // 3. Slowloris fault assertion on AppState.sendControlCommand
        let slowServer = try LoopbackTCPFaultServer { fd in
            _ = LoopbackTCPFaultServer.readLine(fd)
            LoopbackTCPFaultServer.writeLine(fd, "OK")
            _ = LoopbackTCPFaultServer.readLine(fd)
            for b in Array("OK\n".utf8) {
                Thread.sleep(forTimeInterval: 0.35)
                var byte = b
                if Darwin.write(fd, &byte, 1) <= 0 { break }
            }
        }
        defer { slowServer.stop() }
        let slowCreds = TestFixtures.makeSeparatedCredentials(controlPort: slowServer.port)
        do {
            try await AppState.sendControlCommand("RESTORE", creds: slowCreds, timeoutSeconds: 0.6)
            XCTFail("Expected slowloris timeout")
        } catch let err as URLError {
            XCTAssertEqual(err.code, .timedOut)
        }

        // 4. RelayServer control still healthy after attacks
        let liveCreds = TestFixtures.makeSeparatedCredentials(
            forwardUser: "fwd_stress",
            forwardPass: "fp_stress",
            controlUser: "ctrl_stress",
            controlPass: "cp_stress",
            port: ports.forwardPort,
            controlPort: controlPort
        )
        try await AppState.sendControlCommand("SET-TZ Europe/London", creds: liveCreds)
        XCTAssertEqual(tz.currentTimeZone(), "Europe/London")
    }

    // Scenario 5: End-to-End Scale & Outage Recovery
    func test_T4_05_EndToEndScaleAndOutageRecovery() async throws {
        var lines = ["payload:"]
        lines.reserveCapacity(36_005)
        for i in 0..<28_000 {
            lines.append("  - '+.cdn\(i).qq.com'")
        }
        for i in 0..<8_000 {
            lines.append("  - '+.custom-tail-\(i).example.org'")
        }

        let store = InMemorySplitExitListsStore()
        let client = StubHTTPClient(routes: [
            "direct.txt": .success(lines.joined(separator: "\n")),
            "cncidr.txt": .success("1.0.1.0/24\n223.5.5.0/24\n"),
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

        let first = await updater.refresh(force: true)
        XCTAssertNil(first.error)
        let firstLists = try XCTUnwrap(first.lists)
        XCTAssertEqual(firstLists.domains.count, 8_000)
        XCTAssertEqual(first.metrics?.deduplicatedByGeoSiteCNCount, 28_000)

        // Simulate upstream HTTP 503 outage -> preserves cached lists
        client.updateHandler { _ in
            throw URLError(.badServerResponse)
        }
        let outage = await updater.refresh(force: true)
        XCTAssertNotNil(outage.error)
        XCTAssertTrue(outage.usedCache)
        XCTAssertEqual(outage.lists, firstLists)

        // Validate recovered lists in SplitExitPlan via XrayCore.testConfig
        let (exit, hop) = TestFixtures.makeSplitExitNodes()
        let plan = SplitExitPlan(
            exitNode: exit,
            hopNode: hop,
            lists: SplitExitPlan.Lists(
                cnDomains: firstLists.domains,
                cnDomainKeywords: firstLists.domainKeywords,
                cnCIDRs: firstLists.cidrs
            )
        )
        XCTAssertNoThrow(try TestFixtures.runXrayTestConfig(try plan.composeJSON(tunInterfaceName: "utun9")))
    }

    // Scenario 6: End-to-End Cross-Platform & Release Hygiene Gate
    func test_T4_06_EndToEndCrossPlatformAndReleaseHygieneGate() throws {
        // 1. All 5 xcstrings catalogs valid & complete 4-language coverage (+ xcstringstool compile on macOS)
        for rel in TestFixtures.xcstringsRelativePaths {
            let url = TestFixtures.repoRoot.appendingPathComponent(rel)
            let result = try XCStringsValidator.validate(data: Data(contentsOf: url))
            XCTAssertTrue(
                result.issues.isEmpty,
                "\(rel) failed xcstrings validation: \(result.issues.map(\.description).joined(separator: "; "))"
            )
        }

        // 2. Module isolation: QingzhouApp does not import XrayCore / LibXray / XrayConfig
        let appDir = TestFixtures.repoRoot.appendingPathComponent("Sources/QingzhouApp")
        for file in try FileManager.default.subpathsOfDirectory(atPath: appDir.path) where file.hasSuffix(".swift") {
            let src = try String(contentsOf: appDir.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(src.contains("import XrayCore"))
            XCTAssertFalse(src.contains("import XrayConfig"))
            XCTAssertFalse(src.contains("import LibXray"))
        }

        // 3. Docs hygiene: zero leaked /Users/<username> personal paths in docs/
        let docsDir = TestFixtures.repoRoot.appendingPathComponent("docs")
        let userPathRegex = try NSRegularExpression(pattern: #"/Users/(?:<[^>]+>|[A-Za-z0-9._-]+)"#)
        let allowedPlaceholders: Set<String> = ["/Users/<short-user>", "/Users/<短名>", "/Users/<home-dir>"]
        for file in try FileManager.default.subpathsOfDirectory(atPath: docsDir.path) where file.hasSuffix(".md") || file.hasSuffix(".json") {
            let txt = try String(contentsOf: docsDir.appendingPathComponent(file), encoding: .utf8)
            let fullRange = NSRange(txt.startIndex..<txt.endIndex, in: txt)
            let matches = userPathRegex.matches(in: txt, range: fullRange)
                .compactMap { Range($0.range, in: txt).map { String(txt[$0]) } }
                .filter { !allowedPlaceholders.contains($0) }
            XCTAssertTrue(matches.isEmpty, "Leaked personal path(s) \(matches) in docs/\(file)")
        }

        // 4. Shell script syntax & variable-boundary checks on macOS
        #if os(macOS)
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.currentDirectoryURL = TestFixtures.repoRoot
        check.arguments = ["-c", "sh Tools/check-scripts.sh && for f in Tools/*.sh Tools/qingzhou-guard/*.sh; do sh -n \"$f\" || exit 1; done"]
        try check.run()
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
        #endif
    }
}
