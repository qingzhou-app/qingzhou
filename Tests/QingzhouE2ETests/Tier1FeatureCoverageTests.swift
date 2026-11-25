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

final class Tier1FeatureCoverageTests: XCTestCase {

    // MARK: - F1: QingzhouGuardRelayCore (RelayServer, SOCKS5, Control, DNS, Logger)

    func test_T1_F1_01_LoopbackSOCKS5IPv4ConnectEchoAndHalfClose() throws {
        let dir = try TestFixtures.makeTempDirectory(prefix: "t1-f1-01")
        defer { try? FileManager.default.removeItem(at: dir) }

        let echoServer = try LoopbackTCPEchoServer()
        defer { echoServer.stop() }

        let creds = try XCTUnwrap(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_u", pass: "fwd_p:1"),
            control: CredentialPair(user: "ctrl_u", pass: "ctrl_p:1")
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
            creds: creds,
            logger: RelayLogger(logPath: cfg.logPath),
            timeZoneProvider: FakeTimeZoneProvider(),
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        defer { server.stop() }

        let fd = try LoopbackIO.connectLoopback(port: ports.forwardPort)
        defer { Darwin.close(fd) }

        let (authStatus, connectReply) = try LoopbackIO.socks5Handshake(
            fd: fd,
            user: "fwd_u",
            pass: "fwd_p:1",
            targetHost: "127.0.0.1",
            targetPort: echoServer.port
        )
        XCTAssertEqual(authStatus, 0x00)
        XCTAssertEqual(connectReply, 0x00)

        let payload = Array("qingzhou-socks5-half-close-payload-2026".utf8)
        try LoopbackIO.writeAll(fd, bytes: payload)
        Darwin.shutdown(fd, SHUT_WR)

        let echoed = try LoopbackIO.readAllUntilEOF(fd)
        XCTAssertEqual(echoed, payload)
    }

    func test_T1_F1_02_LoopbackSOCKS5DomainConnectViaRelayDNSUDPStub() throws {
        let dir = try TestFixtures.makeTempDirectory(prefix: "t1-f1-02")
        defer { try? FileManager.default.removeItem(at: dir) }

        let echoServer = try LoopbackTCPEchoServer()
        defer { echoServer.stop() }

        let udpDNS = try LoopbackUDPStubDNS { req, txid in
            [LoopbackUDPStubDNS.buildAResponse(for: req, txid: txid, ipOctets: [127, 0, 0, 1])]
        }
        defer { udpDNS.stop() }

        let dns = RelayDNS(servers: [RelayDNS.Server(host: "127.0.0.1", port: udpDNS.port)])
        let creds = try XCTUnwrap(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_u", pass: "fwd_p"),
            control: CredentialPair(user: "ctrl_u", pass: "ctrl_p")
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
            creds: creds,
            logger: RelayLogger(logPath: cfg.logPath),
            dns: dns,
            timeZoneProvider: FakeTimeZoneProvider(),
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        defer { server.stop() }

        let fd = try LoopbackIO.connectLoopback(port: ports.forwardPort)
        defer { Darwin.close(fd) }

        let (authStatus, connectReply) = try LoopbackIO.socks5Handshake(
            fd: fd,
            user: "fwd_u",
            pass: "fwd_p",
            targetHost: "loopback-e2e.example.cn",
            targetPort: echoServer.port
        )
        XCTAssertEqual(authStatus, 0x00)
        XCTAssertEqual(connectReply, 0x00)
        XCTAssertGreaterThanOrEqual(udpDNS.receivedCount, 1)
        XCTAssertEqual(dns.cachedIP(for: "loopback-e2e.example.cn"), "127.0.0.1")

        let msg = Array("domain-connect-ok".utf8)
        try LoopbackIO.writeAll(fd, bytes: msg)
        Darwin.shutdown(fd, SHUT_WR)
        XCTAssertEqual(try LoopbackIO.readAllUntilEOF(fd), msg)
    }

    func test_T1_F1_03_ControlTCPSetTZSwitchAndSwitchBackToOriginal() throws {
        let dir = try TestFixtures.makeTempDirectory(prefix: "t1-f1-03")
        defer { try? FileManager.default.removeItem(at: dir) }

        let tz = FakeTimeZoneProvider(initial: "Asia/Shanghai")
        let creds = try XCTUnwrap(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd", pass: "fp"),
            control: CredentialPair(user: "ctrl", pass: "cp")
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
            creds: creds,
            logger: RelayLogger(logPath: cfg.logPath),
            timeZoneProvider: tz,
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        defer { server.stop() }
        let controlPort = try XCTUnwrap(ports.controlPort)

        let fd = try LoopbackIO.connectLoopback(port: controlPort)
        defer { Darwin.close(fd) }

        try LoopbackIO.writeLine(fd, "AUTH ctrl cp")
        XCTAssertEqual(try LoopbackIO.readLine(fd), "OK")

        try LoopbackIO.writeLine(fd, "GET-TZ")
        XCTAssertEqual(try LoopbackIO.readLine(fd), "Asia/Shanghai")

        try LoopbackIO.writeLine(fd, "SET-TZ America/New_York")
        XCTAssertEqual(try LoopbackIO.readLine(fd), "OK")

        try LoopbackIO.writeLine(fd, "GET-TZ")
        XCTAssertEqual(try LoopbackIO.readLine(fd), "America/New_York")

        // Regression check: SET-TZ back to original TZ compares against currentTimeZone(), not tzOrigPath
        try LoopbackIO.writeLine(fd, "SET-TZ Asia/Shanghai")
        XCTAssertEqual(try LoopbackIO.readLine(fd), "OK")

        try LoopbackIO.writeLine(fd, "GET-TZ")
        XCTAssertEqual(try LoopbackIO.readLine(fd), "Asia/Shanghai")
        XCTAssertEqual(tz.setCalls, ["America/New_York", "Asia/Shanghai"])
    }

    func test_T1_F1_04_ControlTCPRestorePersistsAndRestoresOriginalTZWith0600() throws {
        let dir = try TestFixtures.makeTempDirectory(prefix: "t1-f1-04")
        defer { try? FileManager.default.removeItem(at: dir) }

        let tzOrigURL = dir.appendingPathComponent("timezone-orig")
        let tz = FakeTimeZoneProvider(initial: "Asia/Shanghai")
        let creds = try XCTUnwrap(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd", pass: "fp"),
            control: CredentialPair(user: "ctrl", pass: "cp")
        ))
        let cfg = RelayConfig(
            port: 0,
            controlPort: 0,
            authFile: dir.appendingPathComponent("relay-auth").path,
            logPath: dir.appendingPathComponent("relay.log").path,
            tzOrigPath: tzOrigURL.path
        )
        let server = RelayServer(
            config: cfg,
            creds: creds,
            logger: RelayLogger(logPath: cfg.logPath),
            timeZoneProvider: tz,
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        defer { server.stop() }
        let controlPort = try XCTUnwrap(ports.controlPort)

        let fd = try LoopbackIO.connectLoopback(port: controlPort)
        defer { Darwin.close(fd) }
        try LoopbackIO.writeLine(fd, "AUTH ctrl cp")
        XCTAssertEqual(try LoopbackIO.readLine(fd), "OK")

        try LoopbackIO.writeLine(fd, "SET-TZ Asia/Tokyo")
        XCTAssertEqual(try LoopbackIO.readLine(fd), "OK")
        XCTAssertEqual(try String(contentsOf: tzOrigURL, encoding: .utf8), "Asia/Shanghai")

        let attrs = try FileManager.default.attributesOfItem(atPath: tzOrigURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)

        try LoopbackIO.writeLine(fd, "RESTORE")
        XCTAssertEqual(try LoopbackIO.readLine(fd), "OK")
        XCTAssertEqual(tz.currentTimeZone(), "Asia/Shanghai")
    }

    func test_T1_F1_05_RelayLoggerConcurrentWritesAndSizeRotationWith0600() async throws {
        let dir = try TestFixtures.makeTempDirectory(prefix: "t1-f1-05")
        defer { try? FileManager.default.removeItem(at: dir) }

        let logURL = dir.appendingPathComponent("relay.log")
        let backupURL = dir.appendingPathComponent("relay.log.1")
        let logger = RelayLogger(logPath: logURL.path, maxBytes: 1024)

        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for i in 0..<15 {
                        logger.log("worker-\(worker)-entry-\(i)-payload-for-rotation")
                    }
                }
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        let logAttrs = try FileManager.default.attributesOfItem(atPath: logURL.path)
        let backupAttrs = try FileManager.default.attributesOfItem(atPath: backupURL.path)
        XCTAssertEqual((logAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((backupAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let activeSize = (logAttrs[.size] as? NSNumber)?.uint64Value ?? 0
        XCTAssertLessThanOrEqual(activeSize, 1024)
    }

    // MARK: - F2: GuardRelayCredentials & AppState.sendControlCommand

    func test_T1_F2_01_GuardRelayCredentialsEncodeDecodeAndForwardingOnly() throws {
        let creds = TestFixtures.makeSeparatedCredentials(port: 10808, controlPort: 10819)
        let json = creds.jsonString
        XCTAssertFalse(json.isEmpty)

        let decoded = try XCTUnwrap(GuardRelayCredentials.decode(json))
        XCTAssertEqual(decoded, creds)

        let fwdOnly = decoded.forwardingOnly
        XCTAssertEqual(fwdOnly.host, "127.0.0.1")
        XCTAssertEqual(fwdOnly.port, 10808)
        XCTAssertEqual(fwdOnly.username, creds.username)
        XCTAssertEqual(fwdOnly.password, creds.password)
        XCTAssertNil(fwdOnly.controlPort)
        XCTAssertNil(fwdOnly.controlUsername)
        XCTAssertNil(fwdOnly.controlPassword)
        XCTAssertFalse(fwdOnly.hasValidControlCredentials)
    }

    func test_T1_F2_02_GuardRelayCredentialsValidatedControlPortDefaultAndCustom() throws {
        let defaultPortCreds = TestFixtures.makeSeparatedCredentials(controlPort: nil)
        let validatedDefault = try XCTUnwrap(defaultPortCreds.validatedControlCredentials())
        XCTAssertEqual(validatedDefault.port, GuardRelayCredentials.controlPort)
        XCTAssertEqual(validatedDefault.port, 10809)
        XCTAssertEqual(validatedDefault.username, "ctrl_user")
        XCTAssertEqual(validatedDefault.password, "ctrl_pass_!@#")

        let customCreds = TestFixtures.makeSeparatedCredentials(controlPort: 12089)
        let validatedCustom = try XCTUnwrap(customCreds.validatedControlCredentials())
        XCTAssertEqual(validatedCustom.port, 12089)
    }

    func test_T1_F2_03_AppStateSendControlCommandSetTZAgainstLoopbackStub() async throws {
        let server = try LoopbackTCPFaultServer { fd in
            let auth = LoopbackTCPFaultServer.readLine(fd)
            if auth == "AUTH ctrl_u ctrl_p" {
                LoopbackTCPFaultServer.writeLine(fd, "OK")
                let cmd = LoopbackTCPFaultServer.readLine(fd)
                if cmd == "SET-TZ Europe/London" {
                    LoopbackTCPFaultServer.writeLine(fd, "OK")
                } else {
                    LoopbackTCPFaultServer.writeLine(fd, "ERR cmd")
                }
            } else {
                LoopbackTCPFaultServer.writeLine(fd, "ERR auth")
            }
        }
        defer { server.stop() }

        let creds = TestFixtures.makeSeparatedCredentials(
            forwardUser: "fwd_u",
            forwardPass: "fwd_p",
            controlUser: "ctrl_u",
            controlPass: "ctrl_p",
            controlPort: server.port
        )
        try await AppState.sendControlCommand("SET-TZ Europe/London", creds: creds)
    }

    func test_T1_F2_04_AppStateSendControlCommandRestoreAgainstLoopbackStub() async throws {
        let server = try LoopbackTCPFaultServer { fd in
            let auth = LoopbackTCPFaultServer.readLine(fd)
            XCTAssertEqual(auth, "AUTH ctrl_u ctrl_p")
            LoopbackTCPFaultServer.writeLine(fd, "OK")
            let cmd = LoopbackTCPFaultServer.readLine(fd)
            XCTAssertEqual(cmd, "RESTORE")
            LoopbackTCPFaultServer.writeLine(fd, "OK")
        }
        defer { server.stop() }

        let creds = TestFixtures.makeSeparatedCredentials(
            forwardUser: "fwd_u",
            forwardPass: "fwd_p",
            controlUser: "ctrl_u",
            controlPass: "ctrl_p",
            controlPort: 65000
        )
        // Explicit port override parameter takes precedence over creds.controlPort
        try await AppState.sendControlCommand("RESTORE", creds: creds, port: server.port)
    }

    func test_T1_F2_05_GuardRelayCredentialsHasValidControlCredentialsTruthTable() {
        XCTAssertTrue(TestFixtures.makeSeparatedCredentials().hasValidControlCredentials)
        XCTAssertFalse(GuardRelayCredentials(port: 10808, username: "u", password: "p").hasValidControlCredentials)
        XCTAssertFalse(GuardRelayCredentials(
            port: 10808, username: "u", password: "p",
            controlPort: 10809, controlUsername: "", controlPassword: "cp"
        ).hasValidControlCredentials)
        XCTAssertFalse(GuardRelayCredentials(
            port: 10808, username: "u", password: "p",
            controlPort: 10809, controlUsername: "cu", controlPassword: ""
        ).hasValidControlCredentials)
        XCTAssertFalse(GuardRelayCredentials(
            port: 10808, username: "u", password: "p",
            controlPort: 0, controlUsername: "cu", controlPassword: "cp"
        ).hasValidControlCredentials)
        XCTAssertFalse(GuardRelayCredentials(
            port: 10808, username: "same", password: "same",
            controlPort: 10809, controlUsername: "same", controlPassword: "same"
        ).hasValidControlCredentials)
    }

    // MARK: - F3: Rule Parsing, Diagnostics, XrayConfigComposer, XrayCore.testConfig

    func test_T1_F3_01_RuleParserNoResolveMixedCaseAndInlineHashCommentRoundTrip() throws {
        let r1 = try RuleParser.parseLine("IP-CIDR,10.0.0.0/8,DIRECT,No-Resolve # internal, lan")
        XCTAssertEqual(r1.type, .ipCIDR)
        XCTAssertEqual(r1.value, "10.0.0.0/8")
        XCTAssertEqual(r1.target, .direct)
        XCTAssertTrue(r1.noResolve)
        XCTAssertEqual(r1.comment, "internal, lan")
        XCTAssertEqual(r1.lineForm, "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve")

        let reparsed = try RuleParser.parseLine(r1.lineForm)
        XCTAssertTrue(reparsed.noResolve)
        XCTAssertEqual(reparsed.value, "10.0.0.0/8")
        XCTAssertEqual(reparsed.target, .direct)

        let r2 = try RuleParser.parseLine("IP-CIDR6,fc00::/7,REJECT,NO-RESOLVE")
        XCTAssertTrue(r2.noResolve)
        XCTAssertEqual(r2.lineForm, "IP-CIDR6,fc00::/7,REJECT,no-resolve")
    }

    func test_T1_F3_02_RuleParserProcessNameAndUserAgentWithRuleEngineLocalMatch() throws {
        let text = """
        PROCESS-NAME,curl,DIRECT # cli tool
        USER-AGENT,MyCustomAgent,PROXY
        DOMAIN-SUFFIX,example.com,PROXY
        FINAL,DIRECT
        """
        let parsed = RuleParser.parseAll(text)
        XCTAssertTrue(parsed.errors.isEmpty)
        XCTAssertEqual(parsed.rules.count, 4)

        let engine = RuleEngine(rules: parsed.rules)
        let procHit = engine.match(MatchContext(host: "anything.org", processName: "curl"))
        XCTAssertEqual(procHit.target, .direct)
        XCTAssertEqual(procHit.rule.type, .processName)

        let uaHit = engine.match(MatchContext(host: "anything.org", userAgent: "Mozilla/5.0 MyCustomAgent/2.0"))
        XCTAssertEqual(uaHit.target, .proxy)
        XCTAssertEqual(uaHit.rule.type, .userAgent)

        let fallbackHit = engine.match(MatchContext(host: "unmatched.org"))
        XCTAssertEqual(fallbackHit.target, .direct)
        XCTAssertEqual(fallbackHit.rule.type, .final)
    }

    func test_T1_F3_03_RoutingRuleConverterDiagnosticsForUnsupportedAndNoResolve() throws {
        let text = """
        PROCESS-NAME,Telegram,PROXY
        USER-AGENT,SlackDesktop,DIRECT
        IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
        GEOIP,US,PROXY
        GEOSITE,nonexistent-category,REJECT
        GEOSITE,anthropic,PROXY
        FINAL,DIRECT
        """
        let parsed = RuleParser.parseAll(text)
        XCTAssertTrue(parsed.errors.isEmpty)

        let result = RoutingRuleConverter.xrayRulesWithDiagnostics(from: parsed.rules, hasFullGeoIP: false)
        XCTAssertEqual(result.finalOutboundTag, "direct")
        XCTAssertEqual(result.rules.count, 2) // 172.16.0.0/12 -> direct, geosite:anthropic -> proxy

        let kinds = Set(result.diagnostics.map(\.kind))
        XCTAssertEqual(kinds, [
            .unsupportedProcessName,
            .unsupportedUserAgent,
            .noResolveGlobalDomainStrategyCaveat,
            .missingFullGeoIP,
            .unsupportedGeoSite,
        ])
        for diag in result.diagnostics {
            XCTAssertFalse(diag.message.isEmpty)
            XCTAssertFalse(diag.ruleLine.isEmpty)
        }
    }

    func test_T1_F3_04_XrayConfigComposerRuleModeBlockQUICAndFinalFallback() throws {
        let node = try ProxyURLParser.parse("vless://11111111-1111-1111-1111-111111111111@vless.example.com:443?security=tls&type=tcp#TestVLESS")
        let outboundsJSON = try NodeConverter.toOutboundsJSON(node)
        let rules = RuleParser.parseAll("""
        DOMAIN-SUFFIX,openai.com,PROXY
        FINAL,DIRECT
        """).rules

        let withQUICBlock = try XrayConfigComposer.compose(
            outboundsJSON: outboundsJSON,
            mode: .rule,
            userRules: rules,
            hasFullGeoIP: false,
            tunInterfaceName: "utun9",
            blockQUIC: true
        )
        let dictWith = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(withQUICBlock.utf8)) as? [String: Any])
        let routingWith = try XCTUnwrap(dictWith["routing"] as? [String: Any])
        XCTAssertEqual(routingWith["domainStrategy"] as? String, "IPIfNonMatch")
        let xrayRulesWith = try XCTUnwrap(routingWith["rules"] as? [[String: Any]])
        XCTAssertTrue(xrayRulesWith.contains {
            ($0["network"] as? String) == "udp" && ($0["port"] as? Int) == 443 && ($0["outboundTag"] as? String) == "reject"
        })
        XCTAssertEqual(xrayRulesWith.last?["outboundTag"] as? String, "direct")

        let withoutQUICBlock = try XrayConfigComposer.compose(
            outboundsJSON: outboundsJSON,
            mode: .rule,
            userRules: rules,
            hasFullGeoIP: false,
            tunInterfaceName: "utun9",
            blockQUIC: false
        )
        let dictWithout = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(withoutQUICBlock.utf8)) as? [String: Any])
        let routingWithout = try XCTUnwrap(dictWithout["routing"] as? [String: Any])
        let xrayRulesWithout = try XCTUnwrap(routingWithout["rules"] as? [[String: Any]])
        XCTAssertFalse(xrayRulesWithout.contains {
            ($0["network"] as? String) == "udp" && ($0["port"] as? Int) == 443 && ($0["outboundTag"] as? String) == "reject"
        })
    }

    func test_T1_F3_05_FullRulePipelineValidatedByXrayCoreTestConfig() throws {
        let node = try ProxyURLParser.parse("trojan://secret-pw@trojan.example.com:443?sni=trojan.example.com#TrojanNode")
        let outboundsJSON = try NodeConverter.toOutboundsJSON(node)
        let ruleText = """
        # Comment header
        DOMAIN,api.openai.com,PROXY
        DOMAIN-SUFFIX,claude.ai,PROXY
        DOMAIN-KEYWORD,tracker,REJECT
        IP-CIDR,192.168.0.0/16,DIRECT,no-resolve # lan
        IP-CIDR6,fe80::/10,DIRECT,NO-RESOLVE
        GEOIP,CN,DIRECT
        GEOSITE,anthropic,PROXY
        PROCESS-NAME,Finder,DIRECT
        USER-AGENT,CustomBot/1.0,REJECT
        FINAL,PROXY # fallback, default
        """
        let parsed = RuleParser.parseAll(ruleText)
        XCTAssertTrue(parsed.errors.isEmpty)

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

    // MARK: - F4: Split-Exit Pipeline (GeoSiteCNMatcher, Parser, Updater, SplitExitPlan)

    func test_T1_F4_01_GeoSiteCNMatcherBundledLoadsAndMatchesRootFullRegexp() {
        let matcher = GeoSiteCNMatcher.bundled
        XCTAssertGreaterThan(matcher.entryCount, 5000)

        // RootDomain
        XCTAssertTrue(matcher.isCovered("baidu.com"))
        XCTAssertTrue(matcher.isCovered("sub.baidu.com"))
        XCTAssertTrue(matcher.isCovered("+.qq.com"))
        XCTAssertTrue(matcher.isCovered("*.taobao.com"))
        XCTAssertTrue(matcher.isCovered("cn"))

        // Full (must match exact only)
        XCTAssertTrue(matcher.isCovered("izattime.qcomgeo2.com"))
        XCTAssertFalse(matcher.isCovered("sub.izattime.qcomgeo2.com"))

        // Regexp (^.+-mihayo\.akamaized\.net$)
        XCTAssertTrue(matcher.isCovered("upos-sz-mihayo.akamaized.net"))
        XCTAssertFalse(matcher.isCovered("google.com"))
    }

    func test_T1_F4_02_SplitExitListParserParsesClashYAMLAndRulesAndCIDRs() {
        let domainFeed = """
        payload:
          - '+.qq.com'
          - '*.example.cn'
          - '+.cn'
        DOMAIN-SUFFIX,custom-cn.example.org # inline
        DOMAIN-KEYWORD,wechat
        """
        let parsedDomains = SplitExitListParser.parseDomains(domainFeed)
        XCTAssertEqual(parsedDomains.domains, ["qq.com", "example.cn", "cn", "custom-cn.example.org"])
        XCTAssertEqual(parsedDomains.keywords, ["wechat"])

        let cidrFeed = """
        payload:
          - '1.0.1.0/24'
          - '223.5.5.5'
          - '240c::6666'
        IP-CIDR,114.114.114.114/32,no-resolve
        IP-CIDR6,2400:3200::/32,no-resolve
        """
        let cidrs = SplitExitListParser.parseCIDRs(cidrFeed)
        XCTAssertEqual(cidrs, [
            "1.0.1.0/24",
            "223.5.5.5/32",
            "240c::6666/128",
            "114.114.114.114/32",
            "2400:3200::/32",
        ])
    }

    func test_T1_F4_03_SplitExitListsUpdaterDeduplicatesBeforeSamplingAndVerifiesStore() async {
        let store = InMemorySplitExitListsStore()
        let client = StubHTTPClient(routes: [
            "direct.txt": .success("""
            payload:
              - '+.baidu.com'
              - '+.qq.com'
              - '+.custom-domestic.example.org'
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
        XCTAssertFalse(outcome.usedCache)
        XCTAssertEqual(store.saveCount, 1)

        let lists = try? XCTUnwrap(outcome.lists)
        XCTAssertEqual(lists?.domains, ["custom-domestic.example.org"])
        XCTAssertEqual(lists?.domainKeywords, ["alipay"])
        XCTAssertEqual(lists?.cidrs, ["1.0.1.0/24", "223.5.5.0/24"])
        XCTAssertEqual(outcome.metrics?.rawDomainCount, 4)
        XCTAssertEqual(outcome.metrics?.deduplicatedByGeoSiteCNCount, 2)
        XCTAssertEqual(outcome.metrics?.postDeduplicationDomainCount, 2)
        XCTAssertEqual(outcome.metrics?.finalDomainCount, 2)
    }

    func test_T1_F4_04_SplitExitPlanComposesUseIPv4FakeDNSRelayBlockQUICAndPolicyGroups() throws {
        let (exit, hop) = TestFixtures.makeSplitExitNodes()
        let groups = [
            SplitExitPolicyGroup(name: "AI", target: .exit, domains: ["claude.ai"], geoSites: ["anthropic"]),
            SplitExitPolicyGroup(name: "CN Media", target: .direct, domains: ["custom-cn.example.net"], geoSites: ["bilibili"]),
            SplitExitPolicyGroup(name: "Ads", target: .reject, geoSites: ["category-ads-all"]),
        ]
        let plan = SplitExitPlan(
            exitNode: exit,
            hopNode: hop,
            lists: SplitExitPlan.Lists(cnDomains: ["custom.cn.org"], cnDomainKeywords: ["alipay"], cnCIDRs: ["1.0.1.0/24"]),
            blockQUIC: true,
            rejectOverseasUDP: true,
            relay: SplitExitPlan.RelayEndpoint(host: "127.0.0.1", port: 10808, username: "fwd_u", password: "fwd_p"),
            policyGroups: groups
        )

        let config = try plan.compose(tunInterfaceName: "utun9")
        let dns = try XCTUnwrap(config["dns"] as? [String: Any])
        XCTAssertEqual(dns["queryStrategy"] as? String, "UseIPv4")
        let dnsServers = try XCTUnwrap(dns["servers"] as? [Any])
        let domesticServer = try XCTUnwrap(dnsServers[1] as? [String: Any])
        XCTAssertEqual(domesticServer["address"] as? String, "tcp://223.5.5.5")

        let fakedns = try XCTUnwrap(config["fakedns"] as? [[String: Any]])
        XCTAssertEqual(fakedns.count, 1)
        XCTAssertEqual(fakedns.first?["ipPool"] as? String, "198.18.0.0/15")

        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        let direct = try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == "direct" })
        let directSockopt = try XCTUnwrap((direct["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any])
        XCTAssertEqual(directSockopt["dialerProxy"] as? String, "relay")
        XCTAssertNil(directSockopt["domainStrategy"])
        XCTAssertNil(directSockopt["happyEyeballs"])

        let rules = try XCTUnwrap((config["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertTrue(rules.contains {
            ($0["network"] as? String) == "udp" && ($0["port"] as? Int) == 443 && ($0["outboundTag"] as? String) == "reject"
        })
        let aiIdx = rules.firstIndex {
            ($0["domain"] as? [String])?.contains("geosite:anthropic") == true && ($0["outboundTag"] as? String) == "exit"
        }
        let nonCNIdx = rules.firstIndex {
            ($0["domain"] as? [String]) == ["geosite:geolocation-!cn"]
        }
        let cnIdx = rules.firstIndex {
            ($0["domain"] as? [String])?.contains("geosite:cn") == true && ($0["outboundTag"] as? String) == "direct"
        }
        XCTAssertNotNil(aiIdx)
        XCTAssertNotNil(nonCNIdx)
        XCTAssertNotNil(cnIdx)
        XCTAssertLessThan(try XCTUnwrap(aiIdx), try XCTUnwrap(nonCNIdx))
        XCTAssertLessThan(try XCTUnwrap(nonCNIdx), try XCTUnwrap(cnIdx))
    }

    func test_T1_F4_05_SplitExitPlanWithAndWithoutRelayValidatedByXrayCoreTestConfig() throws {
        let (exit, hop) = TestFixtures.makeSplitExitNodes()
        let lists = SplitExitPlan.Lists(
            cnDomains: ["extra-domestic.example.org"],
            cnDomainKeywords: ["wechat"],
            cnCIDRs: ["1.0.1.0/24"]
        )
        let groups = [
            SplitExitPolicyGroup(name: "ExitGroup", target: .exit, geoSites: ["openai"]),
            SplitExitPolicyGroup(name: "DirectGroup", target: .direct, domains: ["direct.example.cn"]),
        ]

        let directPlan = SplitExitPlan(
            exitNode: exit,
            hopNode: hop,
            lists: lists,
            blockQUIC: true,
            rejectOverseasUDP: true,
            relay: nil,
            policyGroups: groups
        )
        XCTAssertNoThrow(try TestFixtures.runXrayTestConfig(try directPlan.composeJSON(tunInterfaceName: "utun9")))

        let relayPlan = SplitExitPlan(
            exitNode: exit,
            hopNode: hop,
            lists: lists,
            blockQUIC: true,
            rejectOverseasUDP: true,
            relay: SplitExitPlan.RelayEndpoint(host: "127.0.0.1", port: 10808, username: "fwd_u", password: "fwd_p"),
            policyGroups: groups
        )
        XCTAssertNoThrow(try TestFixtures.runXrayTestConfig(try relayPlan.composeJSON(tunInterfaceName: "utun9")))
    }

    // MARK: - F5: Platform Isolation, Localization, Shell Scripts, Repo Hygiene

    func test_T1_F5_01_AllFiveXCStringsDecodeWithFourLanguageCoverage() throws {
        for rel in TestFixtures.xcstringsRelativePaths {
            let url = TestFixtures.repoRoot.appendingPathComponent(rel)
            let result = try XCStringsValidator.validate(data: Data(contentsOf: url))
            XCTAssertEqual(result.catalog.sourceLanguage, "zh-Hans", rel)
            XCTAssertFalse(result.catalog.strings.isEmpty, rel)
            XCTAssertTrue(
                result.issues.isEmpty,
                "\(rel) failed xcstrings validation: \(result.issues.map(\.description).joined(separator: "; "))"
            )
        }
    }

    func test_T1_F5_02_XCStringsToolCompilesAllFiveCatalogs() throws {
        #if os(macOS)
        let outDir = try TestFixtures.makeTempDirectory(prefix: "t1-f5-xcstrings")
        defer { try? FileManager.default.removeItem(at: outDir) }

        for (index, rel) in TestFixtures.xcstringsRelativePaths.enumerated() {
            let subOut = outDir.appendingPathComponent("cat-\(index)")
            try FileManager.default.createDirectory(at: subOut, withIntermediateDirectories: true)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            proc.arguments = [
                "xcstringstool", "compile",
                TestFixtures.repoRoot.appendingPathComponent(rel).path,
                "--output-directory", subOut.path,
            ]
            let errPipe = Pipe()
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = errPipe
            try proc.run()
            proc.waitUntilExit()
            let errText = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(proc.terminationStatus, 0, "xcstringstool failed on \(rel): \(errText)")
        }
        #else
        throw XCTSkip("xcstringstool requires macOS Process")
        #endif
    }

    func test_T1_F5_03_MacOSOnlyUIAndActionsIsolatedInNonMacOSSlices() throws {
        func stripLineComment(_ line: String) -> String {
            guard let r = line.range(of: "//") else { return line }
            return String(line[..<r.lowerBound])
        }

        func nonMacOSSlice(_ source: String) -> String {
            var stack: [String] = []
            var out: [String] = []
            for line in source.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("#") {
                    let directive = stripLineComment(t).trimmingCharacters(in: .whitespaces)
                    if directive.hasPrefix("#if ") { stack.append(directive); continue }
                    if directive.hasPrefix("#elseif ") { if !stack.isEmpty { stack[stack.count - 1] = directive }; continue }
                    if directive == "#else" { if !stack.isEmpty { stack[stack.count - 1] = "#else" }; continue }
                    if directive == "#endif" { if !stack.isEmpty { stack.removeLast() }; continue }
                }
                let inMacOSOnly = stack.contains {
                    $0 == "#if os(macOS)" || $0 == "#elseif os(macOS)" || $0 == "#if !os(iOS)"
                }
                if !inMacOSOnly {
                    out.append(line)
                }
            }
            return out.joined(separator: "\n")
        }

        func nonMacOSCodeSlice(_ source: String) -> String {
            nonMacOSSlice(source)
                .components(separatedBy: .newlines)
                .map { stripLineComment($0) }
                .joined(separator: "\n")
        }

        let settingsDir = TestFixtures.repoRoot.appendingPathComponent("Sources/QingzhouApp/Settings")
        let settingsFiles = ["Sources/QingzhouApp/SettingsView.swift", "Sources/QingzhouApp/SplitExitListsView.swift"]
            + (try FileManager.default.contentsOfDirectory(atPath: settingsDir.path)
                .filter { $0.hasSuffix(".swift") }
                .sorted()
                .map { "Sources/QingzhouApp/Settings/\($0)" })

        for rel in settingsFiles {
            let src = try String(contentsOf: TestFixtures.repoRoot.appendingPathComponent(rel), encoding: .utf8)
            let nonMac = nonMacOSSlice(src)
            for forbidden in ["SettingsSplitExitSection", "SettingsGuardSection", "sudo ", "qingzhou-guard", "showListsSheet"] {
                XCTAssertFalse(nonMac.contains(forbidden), "\(rel) leaked '\(forbidden)' outside #if os(macOS)")
            }
        }

        let appStateChecks: [(String, [String])] = [
            (
                "Sources/QingzhouApp/AppState+SplitExit.swift",
                [
                    "settings.splitExitEnabled",
                    "settings.splitExitExitNodeID =",
                    "settings.splitExitHopNodeID =",
                    "settings.splitExitPolicyGroups =",
                    "loadSplitExitListsStatus()",
                    "reapplyRunningTunnel()",
                ]
            ),
            (
                "Sources/QingzhouApp/AppState+ExitRegion.swift",
                [
                    "GuardRelayCredentials.load()",
                    "\"SET-TZ",
                    "\"RESTORE\"",
                    "Self.sendControlCommand(command",
                    "settings.followExitRegion",
                ]
            ),
            (
                "Sources/QingzhouApp/SplitExitListsUpdater.swift",
                [
                    "SplitExitListsUpdater(logger:",
                    "await refreshSplitExitLists(force: false)",
                ]
            ),
            (
                "Sources/QingzhouApp/AppState+Tunnel.swift",
                [
                    "requestSystemTimeZone(",
                    "GuardRelayCredentials.load()",
                    "settings.splitExitEnabled",
                    "settings.guardRelayEnabled",
                ]
            ),
            (
                "Sources/QingzhouApp/AppState+Schedulers.swift",
                [
                    "refreshSplitExitListsIfDue(",
                    "settings.splitExitEnabled",
                ]
            ),
            (
                "Sources/QingzhouApp/NetworkInfoService.swift",
                [
                    "requestSystemTimeZone(",
                ]
            ),
        ]

        for (rel, forbiddenSymbols) in appStateChecks {
            let src = try String(contentsOf: TestFixtures.repoRoot.appendingPathComponent(rel), encoding: .utf8)
            let nonMacCode = nonMacOSCodeSlice(src)
            for forbidden in forbiddenSymbols {
                XCTAssertFalse(nonMacCode.contains(forbidden), "\(rel) leaked '\(forbidden)' outside #if os(macOS)")
            }
        }
    }

    func test_T1_F5_04_ModuleIsolationAndRepoPathHygiene() throws {
        let pkgSwift = try String(contentsOf: TestFixtures.repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let manifest = try PackageManifestParser.parse(pkgSwift)
        let appTarget = try XCTUnwrap(manifest.target(named: "QingzhouApp", kind: "target"))
        XCTAssertTrue(
            appTarget.unresolvedDependencies.isEmpty,
            "QingzhouApp dependencies must be statically inspectable; unresolved: \(appTarget.unresolvedDependencies)"
        )
        let directDeps = Set(appTarget.resolvedDependencyNames)
        XCTAssertTrue(directDeps.contains("QingzhouCore"), "QingzhouApp must retain its expected base dependencies")
        let transitiveDeps = try manifest.transitiveDependencyNames(of: "QingzhouApp")
        for forbidden in ["XrayCore", "XrayConfig", "LibXray"] {
            XCTAssertFalse(directDeps.contains(forbidden), "QingzhouApp must not directly depend on \(forbidden)")
            XCTAssertFalse(transitiveDeps.contains(forbidden), "QingzhouApp must not transitively depend on \(forbidden)")
        }

        let forbiddenImportPattern = try NSRegularExpression(
            pattern: #"\bimport\s+(?:(?:struct|class|enum|protocol|typealias|func|var|let)\s+)?(XrayCore|XrayConfig|LibXray)\b"#
        )
        let appDir = TestFixtures.repoRoot.appendingPathComponent("Sources/QingzhouApp")
        for file in try FileManager.default.subpathsOfDirectory(atPath: appDir.path) where file.hasSuffix(".swift") {
            let src = try String(contentsOf: appDir.appendingPathComponent(file), encoding: .utf8)
            let stripped = PackageManifestParser.strippingComments(src)
            let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
            XCTAssertNil(
                forbiddenImportPattern.firstMatch(in: stripped, range: range),
                "\(file) must not import XrayCore, XrayConfig, or LibXray"
            )
        }

        let manifestURL = TestFixtures.repoRoot.appendingPathComponent("docs/handoff/2026-11-12-workspace-manifest.json")
        let manifestDoc = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertFalse(manifestDoc.contains("/Users/"), "workspace manifest must not contain local /Users/ absolute paths")
    }

    func test_T1_F5_05_ShellScriptChecksAndSandboxedEnableHappyPath() throws {
        #if os(macOS)
        // 1. Run check-scripts.sh
        let checkProc = Process()
        checkProc.executableURL = URL(fileURLWithPath: "/bin/sh")
        checkProc.currentDirectoryURL = TestFixtures.repoRoot
        checkProc.arguments = ["Tools/check-scripts.sh"]
        try checkProc.run()
        checkProc.waitUntilExit()
        XCTAssertEqual(checkProc.terminationStatus, 0)

        // 2. Run enable.sh happy path inside isolated sandbox
        let sandbox = try ShellSandboxHarness(repoRoot: TestFixtures.repoRoot)
        defer { sandbox.cleanup() }

        let (exit, hop) = TestFixtures.makeSplitExitNodes()
        let plan = SplitExitPlan(
            exitNode: exit,
            hopNode: hop,
            relay: SplitExitPlan.RelayEndpoint(host: "127.0.0.1", port: 10808, username: "fwd_u", password: "fwd_p")
        )
        let xrayJSON = try plan.composeJSON(tunInterfaceName: "utun9")
        try sandbox.writeXrayConfig(xrayJSON)
        try sandbox.writeFreshRelayLog()
        try "10808".write(to: sandbox.baseURL.appendingPathComponent("port"), atomically: true, encoding: .utf8)

        let res = try sandbox.runScript("enable.sh")
        XCTAssertEqual(res.exitCode, 0, "enable.sh stderr: \(res.stderr)\nstdout: \(res.stdout)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.baseURL.appendingPathComponent("enabled").path))
        let rendered = try String(contentsOf: sandbox.baseURL.appendingPathComponent("qingzhou-guard.rendered.conf"), encoding: .utf8)
        XCTAssertTrue(rendered.contains("pass out quick on utun9 all"))
        XCTAssertFalse(rendered.contains("__TUN_DEV__"))
        #else
        throw XCTSkip("Shell sandbox tests require macOS Process")
        #endif
    }
}
