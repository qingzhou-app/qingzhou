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

final class Tier2BoundaryCornerTests: XCTestCase {

    // MARK: - F1: Boundary & Corner Cases

    func test_T2_F1_01_CredentialSeparationAndRelayAuthParseFailClosed() throws {
        // RelayAuthCredentials fail-closed parsing
        XCTAssertNil(RelayAuthCredentials.parse(""))
        XCTAssertNil(RelayAuthCredentials.parse("single_user:single_pass"))
        XCTAssertNil(RelayAuthCredentials.parse("forward:same:pass\ncontrol:same:pass\n"))
        XCTAssertNil(RelayAuthCredentials.parse("forward::pass\ncontrol:cu:cp\n"))
        XCTAssertNil(RelayAuthCredentials(
            forwarding: CredentialPair(user: "same", pass: "p"),
            control: CredentialPair(user: "same", pass: "p")
        ))

        let parsed = try XCTUnwrap(RelayAuthCredentials.parse("forward:fwd_u:p:1\ncontrol:ctrl_u:p:2\n"))
        XCTAssertEqual(parsed.forwarding.pass, "p:1")
        XCTAssertEqual(parsed.control.pass, "p:2")

        // Live RelayServer rejects cross-port credential misuse
        let dir = try TestFixtures.makeTempDirectory(prefix: "t2-f1-01")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cfg = RelayConfig(
            port: 0,
            controlPort: 0,
            authFile: dir.appendingPathComponent("auth").path,
            logPath: dir.appendingPathComponent("relay.log").path,
            tzOrigPath: dir.appendingPathComponent("tz-orig").path
        )
        let server = RelayServer(
            config: cfg,
            creds: parsed,
            logger: RelayLogger(logPath: cfg.logPath),
            timeZoneProvider: FakeTimeZoneProvider(),
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        defer { server.stop() }

        // Control creds on forward port -> auth failure 0x01
        let fFD = try LoopbackIO.connectLoopback(port: ports.forwardPort)
        defer { Darwin.close(fFD) }
        let (fAuth, _) = try LoopbackIO.socks5Handshake(
            fd: fFD,
            user: "ctrl_u",
            pass: "p:2",
            targetHost: "127.0.0.1",
            targetPort: 80
        )
        XCTAssertEqual(fAuth, 0x01)

        // Forward creds on control port -> ERR auth
        let cPort = try XCTUnwrap(ports.controlPort)
        let cFD = try LoopbackIO.connectLoopback(port: cPort)
        defer { Darwin.close(cFD) }
        try LoopbackIO.writeLine(cFD, "AUTH fwd_u p:1")
        XCTAssertEqual(try LoopbackIO.readLine(cFD), "ERR auth")
    }

    func test_T2_F1_02_SOCKS5RejectsNonConnectUDPAssociateAndOversizedHandshake() throws {
        let dir = try TestFixtures.makeTempDirectory(prefix: "t2-f1-02")
        defer { try? FileManager.default.removeItem(at: dir) }

        let creds = try XCTUnwrap(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_u", pass: "fwd_p"),
            control: CredentialPair(user: "ctrl_u", pass: "ctrl_p")
        ))
        let cfg = RelayConfig(
            port: 0,
            controlPort: 0,
            authFile: dir.appendingPathComponent("auth").path,
            logPath: dir.appendingPathComponent("relay.log").path,
            tzOrigPath: dir.appendingPathComponent("tz-orig").path
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

        // 1. UDP ASSOCIATE (CMD=0x03) rejected with REP=0x07 (command not supported)
        let fd1 = try LoopbackIO.connectLoopback(port: ports.forwardPort)
        defer { Darwin.close(fd1) }
        let (auth1, rep1) = try LoopbackIO.socks5Handshake(
            fd: fd1,
            user: "fwd_u",
            pass: "fwd_p",
            cmd: 0x03,
            targetHost: "127.0.0.1",
            targetPort: 443
        )
        XCTAssertEqual(auth1, 0x00)
        XCTAssertEqual(rep1, 0x07)

        // 2. Oversized handshake (>16 KiB) closes connection cleanly without crashing server
        let fd2 = try LoopbackIO.connectLoopback(port: ports.forwardPort)
        defer { Darwin.close(fd2) }
        let junk = [UInt8](repeating: 0x41, count: 17 * 1024)
        try? LoopbackIO.writeAll(fd2, bytes: junk)
        var byte: UInt8 = 0
        let n = Darwin.read(fd2, &byte, 1)
        XCTAssertLessThanOrEqual(n, 0)
    }

    func test_T2_F1_03_RelayDNSRejectsWrongTXIDQR0RCODEAndOversizedLabels() throws {
        // Build query rejects label > 63 and QNAME > 255
        let longLabel = String(repeating: "a", count: 64) + ".com"
        XCTAssertNil(RelayDNS.buildQuery(host: longLabel, id: 1))
        let longName = (0..<5).map { _ in String(repeating: "b", count: 55) }.joined(separator: ".")
        XCTAssertGreaterThan(longName.utf8.count, 255)
        XCTAssertNil(RelayDNS.buildQuery(host: longName, id: 1))

        let query = try XCTUnwrap(RelayDNS.buildQuery(host: "api.example.com", id: 0x1234))
        // Wrong TXID
        let wrongTXID = LoopbackUDPStubDNS.buildAResponse(for: query, txid: 0x9999, ipOctets: [93, 184, 216, 34])
        XCTAssertNil(RelayDNS.parseResponse(wrongTXID, expectedID: 0x1234))

        // QR=0 (query packet spoofed back as response)
        let qrZero = LoopbackUDPStubDNS.buildAResponse(for: query, txid: 0x1234, ipOctets: [93, 184, 216, 34], qr: false)
        XCTAssertNil(RelayDNS.parseResponse(qrZero, expectedID: 0x1234))

        // RCODE=3 (NXDOMAIN)
        let nxdomain = LoopbackUDPStubDNS.buildAResponse(for: query, txid: 0x1234, ipOctets: [93, 184, 216, 34], rcode: 3)
        XCTAssertNil(RelayDNS.parseResponse(nxdomain, expectedID: 0x1234))

        // Live UDP stub: sends wrong TXID first, then valid matching TXID -> RelayDNS drops bogus and accepts valid
        let udpStub = try LoopbackUDPStubDNS { req, txid in
            let bogus = LoopbackUDPStubDNS.buildAResponse(for: req, txid: txid ^ 0x00FF, ipOctets: [1, 2, 3, 4])
            let valid = LoopbackUDPStubDNS.buildAResponse(for: req, txid: txid, ipOctets: [93, 184, 216, 34])
            return [bogus, valid]
        }
        defer { udpStub.stop() }

        let dns = RelayDNS(servers: [RelayDNS.Server(host: "127.0.0.1", port: udpStub.port)], timeoutSeconds: 2)
        XCTAssertEqual(dns.resolveSync("api.example.com", interface: nil), "93.184.216.34")
    }

    func test_T2_F1_04_RelayDNSCacheTTLExpiryAndMaxEntriesOldestEviction() {
        let clock = FakeClock()
        let dns = RelayDNS(
            servers: [],
            ttl: 30,
            maxEntries: 2,
            timeoutSeconds: 1,
            nowProvider: { clock.now() }
        )

        dns.storeCachedIP("1.1.1.1", for: "a.example.com")
        clock.advance(by: 5)
        dns.storeCachedIP("2.2.2.2", for: "b.example.com")
        XCTAssertEqual(dns.cacheCount, 2)

        // Adding 3rd entry evicts oldest ("a.example.com")
        clock.advance(by: 5)
        dns.storeCachedIP("3.3.3.3", for: "c.example.com")
        XCTAssertEqual(dns.cacheCount, 2)
        XCTAssertNil(dns.cachedIP(for: "a.example.com"))
        XCTAssertEqual(dns.cachedIP(for: "b.example.com"), "2.2.2.2")
        XCTAssertEqual(dns.cachedIP(for: "c.example.com"), "3.3.3.3")

        // Advance past TTL -> b and c expire
        clock.advance(by: 35)
        XCTAssertNil(dns.cachedIP(for: "b.example.com"))
        XCTAssertNil(dns.cachedIP(for: "c.example.com"))
        XCTAssertEqual(dns.cacheCount, 0)
    }

    func test_T2_F1_05_ControlSessionRejectsOversizedLineInvalidZoneMissingOrigAndUnknownCmd() throws {
        let dir = try TestFixtures.makeTempDirectory(prefix: "t2-f1-05")
        defer { try? FileManager.default.removeItem(at: dir) }

        let creds = try XCTUnwrap(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_u", pass: "fwd_p"),
            control: CredentialPair(user: "ctrl_u", pass: "ctrl_p")
        ))
        let cfg = RelayConfig(
            port: 0,
            controlPort: 0,
            authFile: dir.appendingPathComponent("auth").path,
            logPath: dir.appendingPathComponent("relay.log").path,
            tzOrigPath: dir.appendingPathComponent("missing-tz-orig").path
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
        let controlPort = try XCTUnwrap(ports.controlPort)

        // Valid auth -> RESTORE without tzOrig -> ERR no-orig, invalid TZ -> ERR zone, unknown cmd -> ERR cmd
        do {
            let fd = try LoopbackIO.connectLoopback(port: controlPort)
            defer { Darwin.close(fd) }
            try LoopbackIO.writeLine(fd, "AUTH ctrl_u ctrl_p")
            XCTAssertEqual(try LoopbackIO.readLine(fd), "OK")

            try LoopbackIO.writeLine(fd, "RESTORE")
            XCTAssertEqual(try LoopbackIO.readLine(fd), "ERR no-orig")

            try LoopbackIO.writeLine(fd, "SET-TZ ../etc/passwd")
            XCTAssertEqual(try LoopbackIO.readLine(fd), "ERR zone")

            try LoopbackIO.writeLine(fd, "PING")
            XCTAssertEqual(try LoopbackIO.readLine(fd), "ERR cmd")
        }

        // Oversized buffer > 1024 bytes before \n -> ERR too-long
        do {
            let fd = try LoopbackIO.connectLoopback(port: controlPort)
            defer { Darwin.close(fd) }
            try LoopbackIO.writeAll(fd, bytes: Array(repeating: 0x42, count: 1200))
            XCTAssertEqual(try LoopbackIO.readLine(fd), "ERR too-long")
        }
    }

    // MARK: - F2: AppState.sendControlCommand & GuardRelayCredentials Boundary Cases

    func test_T2_F2_01_AppStateSendControlCommandThrowsOnErrorReply() async throws {
        let server = try LoopbackTCPFaultServer { fd in
            _ = LoopbackTCPFaultServer.readLine(fd)
            LoopbackTCPFaultServer.writeLine(fd, "OK")
            _ = LoopbackTCPFaultServer.readLine(fd)
            LoopbackTCPFaultServer.writeLine(fd, "ERR zone")
        }
        defer { server.stop() }

        let creds = TestFixtures.makeSeparatedCredentials(controlPort: server.port)
        do {
            try await AppState.sendControlCommand("SET-TZ Invalid/Zone", creds: creds)
            XCTFail("Expected error on ERR zone")
        } catch let err as URLError {
            XCTAssertEqual(err.code, .badServerResponse)
        }
    }

    func test_T2_F2_02_AppStateSendControlCommandThrowsOnEOFEmptyReply() async throws {
        let server = try LoopbackTCPFaultServer { fd in
            _ = LoopbackTCPFaultServer.readLine(fd)
            LoopbackTCPFaultServer.writeLine(fd, "OK")
            _ = LoopbackTCPFaultServer.readLine(fd)
            // Close immediately without writing reply
        }
        defer { server.stop() }

        let creds = TestFixtures.makeSeparatedCredentials(controlPort: server.port)
        do {
            try await AppState.sendControlCommand("RESTORE", creds: creds)
            XCTFail("Expected error on EOF empty reply")
        } catch let err as URLError {
            XCTAssertEqual(err.code, .zeroByteResource)
        }
    }

    func test_T2_F2_03_AppStateSendControlCommandThrowsTimedOutOnHungAndSlowlorisDrip() async throws {
        let slowloris = try LoopbackTCPFaultServer { fd in
            _ = LoopbackTCPFaultServer.readLine(fd)
            LoopbackTCPFaultServer.writeLine(fd, "OK")
            _ = LoopbackTCPFaultServer.readLine(fd)
            for b in Array("OK\n".utf8) {
                Thread.sleep(forTimeInterval: 0.4)
                var byte = b
                if Darwin.write(fd, &byte, 1) <= 0 { break }
            }
        }
        defer { slowloris.stop() }

        let creds = TestFixtures.makeSeparatedCredentials(controlPort: slowloris.port)
        do {
            try await AppState.sendControlCommand("RESTORE", creds: creds, timeoutSeconds: 0.7)
            XCTFail("Expected timeout on slowloris drip")
        } catch let err as URLError {
            XCTAssertEqual(err.code, .timedOut)
        }
    }

    func test_T2_F2_04_AppStateSendControlCommandRejectsInvalidAndIdenticalCredsAndNewlineInjection() async throws {
        let identical = GuardRelayCredentials(
            port: 10808,
            username: "same",
            password: "same",
            controlPort: 10809,
            controlUsername: "same",
            controlPassword: "same"
        )
        do {
            try await AppState.sendControlCommand("RESTORE", creds: identical)
            XCTFail("Expected failure for identical creds")
        } catch let err as URLError {
            XCTAssertEqual(err.code, .userAuthenticationRequired)
        }

        let newlineCmd = TestFixtures.makeSeparatedCredentials()
        do {
            try await AppState.sendControlCommand("SET-TZ Asia/Tokyo\nRESTORE", creds: newlineCmd)
            XCTFail("Expected badURL on newline injection in command")
        } catch let err as URLError {
            XCTAssertEqual(err.code, .badURL)
        }

        let spaceUser = TestFixtures.makeSeparatedCredentials(controlUser: "ctrl user")
        do {
            try await AppState.sendControlCommand("RESTORE", creds: spaceUser)
            XCTFail("Expected badURL on whitespace in control username")
        } catch let err as URLError {
            XCTAssertEqual(err.code, .badURL)
        }
    }

    func test_T2_F2_05_GuardRelayCredentialsDecodeReturnsNilOnEmptyCorruptZeroPortMissingFields() {
        XCTAssertNil(GuardRelayCredentials.decode(""))
        XCTAssertNil(GuardRelayCredentials.decode("{corrupt json"))
        XCTAssertNil(GuardRelayCredentials.decode(#"{"host":"127.0.0.1","port":0,"username":"u","password":"p"}"#))
        XCTAssertNil(GuardRelayCredentials.decode(#"{"host":"","port":10808,"username":"u","password":"p"}"#))
        XCTAssertNil(GuardRelayCredentials.decode(#"{"host":"127.0.0.1","port":10808,"username":"","password":"p"}"#))
        XCTAssertNil(GuardRelayCredentials.decode(#"{"host":"127.0.0.1","port":10808,"username":"u"}"#))
    }

    // MARK: - F3: Rule Parsing, Conversion & XrayCore Negative Checks

    func test_T2_F3_01_RuleParserRejectsBareIPInvalidCIDRUnknownTypeTargetAndEmptyLine() {
        XCTAssertThrowsError(try RuleParser.parseLine(""))
        XCTAssertThrowsError(try RuleParser.parseLine("   # only comment"))
        XCTAssertThrowsError(try RuleParser.parseLine("IP-CIDR,8.8.8.8,DIRECT"))
        XCTAssertThrowsError(try RuleParser.parseLine("IP-CIDR,192.168.1.0/33,DIRECT"))
        XCTAssertThrowsError(try RuleParser.parseLine("IP-CIDR6,fe80::/129,DIRECT"))
        XCTAssertThrowsError(try RuleParser.parseLine("UNKNOWN-TYPE,foo,DIRECT"))
        XCTAssertThrowsError(try RuleParser.parseLine("DOMAIN,example.com,NOWHERE"))
    }

    func test_T2_F3_02_RuleParserPreservesCommasInHashCommentAndFinalNoResolveFalse() throws {
        let finalRule = try RuleParser.parseLine("FINAL,REJECT,no-resolve # catch-all, with, commas")
        XCTAssertEqual(finalRule.type, .final)
        XCTAssertEqual(finalRule.target, .reject)
        XCTAssertFalse(finalRule.noResolve)
        XCTAssertEqual(finalRule.lineForm, "FINAL,REJECT")
        XCTAssertEqual(finalRule.comment, "no-resolve catch-all, with, commas")

        let domainRule = try RuleParser.parseLine("DOMAIN-SUFFIX,example.com,PROXY # first, second, third")
        XCTAssertEqual(domainRule.comment, "first, second, third")
        XCTAssertFalse(domainRule.noResolve)
    }

    func test_T2_F3_03_RoutingRuleConverterPreservesFirstMatchAcrossTargetTransitions() {
        let rules = [
            Rule(type: .domainSuffix, value: "a.com", target: .proxy),
            Rule(type: .domainSuffix, value: "b.com", target: .proxy),
            Rule(type: .domainSuffix, value: "a.com", target: .reject),
            Rule(type: .domainSuffix, value: "c.com", target: .proxy),
        ]
        let converted = RoutingRuleConverter.xrayRules(from: rules)
        XCTAssertEqual(converted.count, 3)
        XCTAssertEqual(converted[0]["outboundTag"] as? String, "proxy")
        XCTAssertEqual(converted[0]["domain"] as? [String], ["domain:a.com", "domain:b.com"])
        XCTAssertEqual(converted[1]["outboundTag"] as? String, "reject")
        XCTAssertEqual(converted[1]["domain"] as? [String], ["domain:a.com"])
        XCTAssertEqual(converted[2]["outboundTag"] as? String, "proxy")
        XCTAssertEqual(converted[2]["domain"] as? [String], ["domain:c.com"])
    }

    func test_T2_F3_04_XrayConfigComposerStripsSendThroughAndNestedAllowInsecure() throws {
        let rawOutbounds = """
        {
          "outbounds": [
            {
              "protocol": "vless",
              "sendThrough": "My Node Emoji 🚀",
              "settings": { "vnext": [{ "address": "1.2.3.4", "port": 443, "users": [{ "id": "11111111-1111-1111-1111-111111111111", "encryption": "none" }] }] },
              "streamSettings": {
                "network": "tcp",
                "security": "tls",
                "tlsSettings": {
                  "allowInsecure": true,
                  "serverName": "node.example.com"
                }
              }
            }
          ]
        }
        """
        let composed = try XrayConfigComposer.compose(
            outboundsJSON: rawOutbounds,
            mode: .rule,
            tunInterfaceName: "utun9"
        )
        XCTAssertFalse(composed.contains("sendThrough"))
        XCTAssertFalse(composed.contains("allowInsecure"))
        XCTAssertNoThrow(try TestFixtures.runXrayTestConfig(composed))
    }

    func test_T2_F3_05_XrayCoreTestConfigNegativeChecksMalformedJSONAndUnbundledGeoData() throws {
        let node = try ProxyURLParser.parse("vless://11111111-1111-1111-1111-111111111111@vless.example.com:443?security=tls&type=tcp#V")
        let outboundsJSON = try NodeConverter.toOutboundsJSON(node)

        // 1. Malformed / invalid Xray JSON is rejected by XrayCore.testConfig
        XCTAssertThrowsError(try TestFixtures.runXrayTestConfig("{invalid-xray-json"))

        // 2. hasFullGeoIP: true with GEOIP,US fails against bundled geoip-only-cn-private.dat
        let unbundledGeoIPConfig = try XrayConfigComposer.compose(
            outboundsJSON: outboundsJSON,
            mode: .rule,
            userRules: [Rule(type: .geoip, value: "US", target: .proxy)],
            hasFullGeoIP: true,
            tunInterfaceName: "utun9"
        )
        XCTAssertThrowsError(try TestFixtures.runXrayTestConfig(unbundledGeoIPConfig))

        // 3. Unbundled geosite category injected directly in routing fails testConfig
        let validConfig = try XrayConfigComposer.compose(
            outboundsJSON: outboundsJSON,
            mode: .rule,
            tunInterfaceName: "utun9"
        )
        let badGeoSiteConfig = validConfig.replacingOccurrences(of: "geosite:cn", with: "geosite:definitely-missing-category-xyz")
        XCTAssertThrowsError(try TestFixtures.runXrayTestConfig(badGeoSiteConfig))
    }

    // MARK: - F4: Split-Exit Boundary & Corner Cases

    func test_T2_F4_01_GeoSiteCNMatcherRejectsIPsTrailingDotSubstringFalsePositivesAndEmptyLabels() {
        let matcher = GeoSiteCNMatcher.bundled
        XCTAssertFalse(matcher.isCovered(""))
        XCTAssertFalse(matcher.isCovered("114.114.114.114"))
        XCTAssertFalse(matcher.isCovered("2400:3200::1"))
        XCTAssertFalse(matcher.isCovered("notbaidu.com"))
        XCTAssertFalse(matcher.isCovered("baidu..com"))
        XCTAssertFalse(matcher.isCovered("bad domain.com"))
        XCTAssertTrue(matcher.isCovered("BAIDU.COM."))
        XCTAssertTrue(matcher.isCovered("  +.QQ.COM.  "))
    }

    func test_T2_F4_02_SplitExitListsUpdaterPreservesPriorCacheOnHTTPErrorOrEmptyFeed() async {
        let prior = SplitExitLists(
            domains: ["cached.example.cn"],
            domainKeywords: ["cachedkw"],
            cidrs: ["1.0.1.0/24"],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let store = InMemorySplitExitListsStore(initial: prior)
        let client = StubHTTPClient(routes: [
            "direct.txt": .failure(URLError(.badServerResponse)),
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

        let outcomeHTTPFail = await updater.refresh(force: true)
        XCTAssertNotNil(outcomeHTTPFail.error)
        XCTAssertTrue(outcomeHTTPFail.usedCache)
        XCTAssertEqual(outcomeHTTPFail.lists, prior)
        XCTAssertEqual(store.saveCount, 0)

        // Empty domain feed while cidr succeeds -> still fails and preserves prior cache
        client.updateHandler { url in
            if url.lastPathComponent == "direct.txt" {
                return (Data("# empty only comments\n".utf8), [:])
            }
            return (Data("1.0.1.0/24\n".utf8), [:])
        }
        let outcomeEmpty = await updater.refresh(force: true)
        XCTAssertNotNil(outcomeEmpty.error)
        XCTAssertTrue(outcomeEmpty.usedCache)
        XCTAssertEqual(outcomeEmpty.lists, prior)
        XCTAssertEqual(store.saveCount, 0)
    }

    func test_T2_F4_03_PreSamplingDeduplicationPreservesNonCNTailBeyond30kLimit() async throws {
        // Construct 25,000 CN domains (covered by geosite:cn) + 6,000 non-CN domains = 31,000 (> 30,000 cap).
        // Pre-sampling deduplication drops all 25,000 CN entries BEFORE sampling, so all 6,000 non-CN survive!
        var lines = ["payload:"]
        lines.reserveCapacity(31_005)
        for i in 0..<25_000 {
            lines.append("  - '+.sub\(i).baidu.com'")
        }
        for i in 0..<6_000 {
            lines.append("  - '+.noncn-\(i).example.org'")
        }
        let directPayload = lines.joined(separator: "\n")

        let store = InMemorySplitExitListsStore()
        let client = StubHTTPClient(routes: [
            "direct.txt": .success(directPayload),
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
        let lists = try XCTUnwrap(outcome.lists)
        let metrics = try XCTUnwrap(outcome.metrics)
        XCTAssertEqual(metrics.rawDomainCount, 31_000)
        XCTAssertEqual(metrics.deduplicatedByGeoSiteCNCount, 25_000)
        XCTAssertEqual(metrics.postDeduplicationDomainCount, 6_000)
        XCTAssertEqual(metrics.finalDomainCount, 6_000)
        XCTAssertEqual(lists.domains.count, 6_000)
        XCTAssertEqual(lists.domains.last, "noncn-5999.example.org")
    }

    func test_T2_F4_04_SplitExitPlanInvalidNodesDisabledPolicyGroupAndForceIPBoundary() throws {
        let (exit, hop) = TestFixtures.makeSplitExitNodes()

        // 1. Missing exit host -> PlanError.missingExitNode
        var emptyHostExit = exit
        emptyHostExit.host = ""
        XCTAssertThrowsError(try SplitExitPlan(exitNode: emptyHostExit, hopNode: hop).compose(tunInterfaceName: "utun9")) { err in
            XCTAssertEqual(err as? SplitExitPlan.PlanError, .missingExitNode)
        }

        // 2. Hop equals exit -> PlanError.hopEqualsExit
        XCTAssertThrowsError(try SplitExitPlan(exitNode: exit, hopNode: exit).compose(tunInterfaceName: "utun9")) { err in
            XCTAssertEqual(err as? SplitExitPlan.PlanError, .hopEqualsExit)
        }

        // 3. Disabled policyGroup is excluded; relay == nil restores ForceIP & happyEyeballs on direct
        let disabled = SplitExitPolicyGroup(
            name: "Disabled",
            target: .reject,
            domains: ["should-not-appear.example.com"],
            isEnabled: false
        )
        let plan = SplitExitPlan(exitNode: exit, hopNode: hop, relay: nil, policyGroups: [disabled])
        let cfg = try plan.compose(tunInterfaceName: "utun9")
        let outbounds = try XCTUnwrap(cfg["outbounds"] as? [[String: Any]])
        let direct = try XCTUnwrap(outbounds.first { ($0["tag"] as? String) == "direct" })
        let sockopt = try XCTUnwrap((direct["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any])
        XCTAssertEqual(sockopt["domainStrategy"] as? String, "ForceIP")
        XCTAssertNotNil(sockopt["happyEyeballs"])

        let json = try plan.composeJSON(tunInterfaceName: "utun9")
        XCTAssertFalse(json.contains("should-not-appear.example.com"))
    }

    func test_T2_F4_05_SplitExitPlanBlockQUICFalseAndRejectOverseasUDPFalsePassesXrayTestConfig() throws {
        let (exit, hop) = TestFixtures.makeSplitExitNodes()
        let plan = SplitExitPlan(
            exitNode: exit,
            hopNode: hop,
            blockQUIC: false,
            rejectOverseasUDP: false
        )
        let cfg = try plan.compose(tunInterfaceName: "utun9")
        let rules = try XCTUnwrap((cfg["routing"] as? [String: Any])?["rules"] as? [[String: Any]])

        XCTAssertFalse(rules.contains {
            ($0["network"] as? String) == "udp" && ($0["port"] as? Int) == 443 && ($0["outboundTag"] as? String) == "reject"
        })
        XCTAssertEqual(rules.last?["network"] as? String, "udp")
        XCTAssertEqual(rules.last?["outboundTag"] as? String, "exit")

        let json = try plan.composeJSON(tunInterfaceName: "utun9")
        XCTAssertNoThrow(try TestFixtures.runXrayTestConfig(json))
    }

    // MARK: - F5: Shell Sandbox Boundary & Geo/Localization Negative Checks

    func test_T2_F5_01_SandboxEnableRejectsMissingUtunBadXrayJSONAndStaleRelayLog() throws {
        #if os(macOS)
        let sandbox = try ShellSandboxHarness(repoRoot: TestFixtures.repoRoot)
        defer { sandbox.cleanup() }

        let (exit, hop) = TestFixtures.makeSplitExitNodes()
        let validXray = try SplitExitPlan(
            exitNode: exit,
            hopNode: hop,
            relay: SplitExitPlan.RelayEndpoint(host: "127.0.0.1", port: 10808, username: "u", password: "p")
        ).composeJSON(tunInterfaceName: "utun9")

        // 1. Missing utun -> exit 1
        try sandbox.setUtuns("")
        try sandbox.writeXrayConfig(validXray)
        try sandbox.writeFreshRelayLog()
        XCTAssertNotEqual(try sandbox.runScript("enable.sh").exitCode, 0)

        // 2. Restore utun9, break xray-config.json (missing relay dialerProxy) -> exit 1
        try sandbox.setUtuns("utun9")
        let noRelayXray = try SplitExitPlan(exitNode: exit, hopNode: hop, relay: nil).composeJSON(tunInterfaceName: "utun9")
        try sandbox.writeXrayConfig(noRelayXray)
        XCTAssertNotEqual(try sandbox.runScript("enable.sh").exitCode, 0)

        // 3. Valid xray-config.json, stale (>120s) relay.log -> exit 1
        try sandbox.writeXrayConfig(validXray)
        try sandbox.setRelayLogAgeSeconds(300)
        XCTAssertNotEqual(try sandbox.runScript("enable.sh").exitCode, 0)
        #else
        throw XCTSkip("Shell sandbox tests require macOS Process")
        #endif
    }

    func test_T2_F5_02_SandboxGuardRunFailClosedTransitionUtun9ToUtun10AndCleanExit() throws {
        #if os(macOS)
        let sandbox = try ShellSandboxHarness(repoRoot: TestFixtures.repoRoot)
        defer { sandbox.cleanup() }

        try "10808".write(to: sandbox.baseURL.appendingPathComponent("port"), atomically: true, encoding: .utf8)
        try "10809".write(to: sandbox.baseURL.appendingPathComponent("control-port"), atomically: true, encoding: .utf8)
        try "forward:u:p\ncontrol:cu:cp\n".write(
            to: sandbox.baseURL.appendingPathComponent("relay-auth"),
            atomically: true,
            encoding: .utf8
        )
        try "".write(to: sandbox.baseURL.appendingPathComponent("enabled"), atomically: true, encoding: .utf8)
        // Start fail-closed (no utun)
        try sandbox.setUtuns("")

        let proc = try sandbox.startScriptAsync("guard-run.sh")
        defer {
            try? sandbox.triggerStopRelay()
            if proc.isRunning {
                proc.terminate()
                proc.waitUntilExit()
            }
        }

        // Wait up to 3s for fail-closed base rules (no __TUN_DEV__ pass line, block out quick all present)
        let renderedURL = sandbox.baseURL.appendingPathComponent("qingzhou-guard.rendered.conf")
        var sawFailClosed = false
        for _ in 0..<30 {
            if let text = try? String(contentsOf: renderedURL, encoding: .utf8) {
                let active = text.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                if active.contains("block out quick all")
                    && !active.contains(where: { $0.contains("utun") || $0.contains("__TUN_DEV__") }) {
                    sawFailClosed = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(sawFailClosed, "guard-run.sh must load fail-closed rules before utun appears")

        // Transition to utun9
        try sandbox.setUtuns("utun9")
        var sawUtun9 = false
        for _ in 0..<30 {
            if let text = try? String(contentsOf: renderedURL, encoding: .utf8),
               text.contains("pass out quick on utun9 all") {
                sawUtun9 = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(sawUtun9, "guard-run.sh must transition to utun9 within <= 1s polling")

        // Reconnect transition to utun10
        try sandbox.setUtuns("utun10")
        var sawUtun10 = false
        for _ in 0..<30 {
            if let text = try? String(contentsOf: renderedURL, encoding: .utf8),
               text.contains("pass out quick on utun10 all") {
                sawUtun10 = true
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(sawUtun10, "guard-run.sh must update to utun10 on reconnect")

        try sandbox.triggerStopRelay()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
        #else
        throw XCTSkip("Shell sandbox tests require macOS Process")
        #endif
    }

    func test_T2_F5_03_SandboxOffShAnchorOnlyTeardownNeverInvokesPfctlD() throws {
        #if os(macOS)
        let sandbox = try ShellSandboxHarness(repoRoot: TestFixtures.repoRoot)
        defer { sandbox.cleanup() }

        try "".write(to: sandbox.baseURL.appendingPathComponent("enabled"), atomically: true, encoding: .utf8)
        try "987654".write(to: sandbox.baseURL.appendingPathComponent("pf-token"), atomically: true, encoding: .utf8)
        try "block out quick all\n".write(to: sandbox.anchorRulesURL, atomically: true, encoding: .utf8)

        let res = try sandbox.runScript("off.sh")
        XCTAssertEqual(res.exitCode, 0, res.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.baseURL.appendingPathComponent("enabled").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.baseURL.appendingPathComponent("pf-token").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.anchorRulesURL.path))

        let calls = sandbox.readCallsLog()
        XCTAssertTrue(calls.contains("pfctl -a com.apple/qingzhou_guard -F all"))
        XCTAssertTrue(calls.contains("pfctl -X 987654"))
        XCTAssertFalse(calls.contains("pfctl -d"))
        XCTAssertFalse(calls.contains("FORBIDDEN pfctl -d"))
        #else
        throw XCTSkip("Shell sandbox tests require macOS Process")
        #endif
    }

    func test_T2_F5_04_SandboxUninstallRestoresValidTZSkipsInvalidTZAndRemovesFiles() throws {
        #if os(macOS)
        // 1. Valid timezone-orig -> systemsetup -settimezone invoked, files removed
        do {
            let sandbox = try ShellSandboxHarness(repoRoot: TestFixtures.repoRoot)
            defer { sandbox.cleanup() }
            try "Asia/Shanghai".write(
                to: sandbox.baseURL.appendingPathComponent("timezone-orig"),
                atomically: true,
                encoding: .utf8
            )
            try "<plist/>".write(to: sandbox.plistURL, atomically: true, encoding: .utf8)
            try sandbox.writeFreshRelayLog()

            let res = try sandbox.runScript("uninstall.sh")
            XCTAssertEqual(res.exitCode, 0, res.stderr)
            let calls = sandbox.readCallsLog()
            XCTAssertTrue(calls.contains("systemsetup -settimezone Asia/Shanghai"))
            XCTAssertFalse(calls.contains("FORBIDDEN pfctl -d"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.baseURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.plistURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.logsURL.appendingPathComponent("qingzhou-relay.log").path))
        }

        // 2. Traversal/invalid timezone-orig -> systemsetup NOT invoked
        do {
            let sandbox = try ShellSandboxHarness(repoRoot: TestFixtures.repoRoot)
            defer { sandbox.cleanup() }
            try "../etc/passwd".write(
                to: sandbox.baseURL.appendingPathComponent("timezone-orig"),
                atomically: true,
                encoding: .utf8
            )
            let res = try sandbox.runScript("uninstall.sh")
            XCTAssertEqual(res.exitCode, 0, res.stderr)
            XCTAssertFalse(sandbox.readCallsLog().contains("systemsetup -settimezone"))
        }
        #else
        throw XCTSkip("Shell sandbox tests require macOS Process")
        #endif
    }

    func test_T2_F5_05_GeoDataBundleRejectsNegatedGeoSiteAndXCStringsValidatorDetectsMissingLang() throws {
        XCTAssertTrue(GeoDataBundle.supportsGeoSite("anthropic"))
        XCTAssertTrue(GeoDataBundle.supportsGeoSite("geolocation-!cn"))
        XCTAssertFalse(GeoDataBundle.supportsGeoSite("!cn"))
        XCTAssertFalse(GeoDataBundle.supportsGeoSite("nonexistent-category"))
        XCTAssertTrue(GeoDataBundle.supportsGeoIP("cn"))
        XCTAssertTrue(GeoDataBundle.supportsGeoIP("!private"))
        XCTAssertFalse(GeoDataBundle.supportsGeoIP("us"))

        // Synthetic xcstrings validation catches missing/empty language translation & bad sourceLanguage
        let brokenJSON = """
        {
          "sourceLanguage": "zh-Hans",
          "strings": {
            "测试键": {
              "localizations": {
                "en": { "stringUnit": { "state": "translated", "value": "Test Key" } },
                "ja": { "stringUnit": { "state": "translated", "value": "   " } }
              }
            },
            "无需翻译键": {
              "shouldTranslate": false,
              "localizations": {}
            }
          }
        }
        """
        let result = try XCStringsValidator.validate(data: Data(brokenJSON.utf8))
        XCTAssertTrue(result.issues.contains(.emptyLocalization(key: "测试键", language: "ja")))
        XCTAssertTrue(result.issues.contains(.missingLocalization(key: "测试键", language: "zh-Hant")))
        XCTAssertFalse(result.issues.contains(.missingLocalization(key: "测试键", language: "en")))
        XCTAssertFalse(result.issues.contains(.emptyLocalization(key: "测试键", language: "en")))
        XCTAssertFalse(result.issues.contains { $0.description.contains("无需翻译键") })

        let wrongSourceJSON = """
        {
          "sourceLanguage": "en",
          "strings": {}
        }
        """
        let wrongSourceResult = try XCStringsValidator.validate(data: Data(wrongSourceJSON.utf8))
        XCTAssertTrue(wrongSourceResult.issues.contains(.unexpectedSourceLanguage(expected: "zh-Hans", actual: "en")))
        XCTAssertTrue(wrongSourceResult.issues.contains(.emptyCatalog))
    }

    func test_T2_F5_06_PackageManifestParserCatchesInjectedAndTransitiveDependencies() throws {
        // 1. Direct injection via string, .target, .target(condition:), .byName, .product
        //    even with .library(name: "QingzhouApp") & .library(name: "XrayConfig") in products:
        let directInjectedManifest = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Qingzhou",
            products: [
                .library(name: "QingzhouApp", targets: ["QingzhouApp"]),
                .library(name: "XrayConfig",  targets: ["XrayConfig"])
            ],
            targets: [
                .target(name: "QingzhouCore"),
                .target(
                    name: "QingzhouApp",
                    dependencies: [
                        "QingzhouCore",
                        "XrayCore",
                        .target(name: "XrayCore"),
                        .target(name: "XrayConfig", condition: .when(platforms: [.macOS])),
                        .byName(name: "LibXray"),
                        .product(name: "XrayCore", package: "Local")
                    ]
                ),
                .target(name: "XrayConfig", dependencies: ["QingzhouCore"]),
                .target(name: "XrayCore", dependencies: ["LibXray"])
            ]
        )
        """
        let directParsed = try PackageManifestParser.parse(directInjectedManifest)
        let directApp = try XCTUnwrap(directParsed.target(named: "QingzhouApp", kind: "target"))
        XCTAssertTrue(directApp.unresolvedDependencies.isEmpty)
        let directNames = Set(directApp.resolvedDependencyNames)
        XCTAssertTrue(directNames.contains("QingzhouCore"))
        XCTAssertTrue(directNames.contains("XrayCore"))
        XCTAssertTrue(directNames.contains("XrayConfig"))
        XCTAssertTrue(directNames.contains("LibXray"))

        // 2. Argument reordering + nested resources/swiftSettings + comment immunity
        let reorderedCommentImmuneManifest = """
        import PackageDescription
        // .target(name: "QingzhouApp", dependencies: ["XrayCore"])
        let package = Package(
            name: "Qingzhou",
            products: [
                .library(name: "QingzhouApp", targets: ["QingzhouApp"]),
                .library(name: "XrayConfig",  targets: ["XrayConfig"])
            ],
            targets: [
                .target(
                    dependencies: [
                        // "XrayCore",
                        /* targets: [ /* "XrayCore" */ ] */
                        .byNameItem(name: "QingzhouCore", condition: nil)
                    ],
                    resources: [.copy("Resources/foo.txt")],
                    swiftSettings: [.define("DEBUG", .when(configuration: .debug))],
                    name: "QingzhouApp"
                ),
                .target(name: "QingzhouCore")
            ]
        )
        """
        let cleanParsed = try PackageManifestParser.parse(reorderedCommentImmuneManifest)
        let cleanApp = try XCTUnwrap(cleanParsed.target(named: "QingzhouApp", kind: "target"))
        XCTAssertEqual(cleanApp.resolvedDependencyNames, ["QingzhouCore"])
        XCTAssertTrue(cleanApp.unresolvedDependencies.isEmpty)
        let cleanTransitive = try cleanParsed.transitiveDependencyNames(of: "QingzhouApp")
        XCTAssertEqual(cleanTransitive, ["QingzhouCore"])

        // 3. Transitive leakage: QingzhouApp -> QingzhouLogging -> XrayCore
        let transitiveLeakManifest = """
        import PackageDescription
        let package = Package(
            name: "Qingzhou",
            products: [
                .library(name: "QingzhouApp", targets: ["QingzhouApp"])
            ],
            targets: [
                .target(name: "QingzhouCore"),
                .target(name: "QingzhouLogging", dependencies: ["QingzhouCore", "XrayCore"]),
                .target(name: "QingzhouApp", dependencies: ["QingzhouCore", "QingzhouLogging"]),
                .target(name: "XrayCore", dependencies: ["QingzhouCore"])
            ]
        )
        """
        let transitiveParsed = try PackageManifestParser.parse(transitiveLeakManifest)
        let transitiveApp = try XCTUnwrap(transitiveParsed.target(named: "QingzhouApp", kind: "target"))
        XCTAssertFalse(Set(transitiveApp.resolvedDependencyNames).contains("XrayCore"))
        let transitiveDeps = try transitiveParsed.transitiveDependencyNames(of: "QingzhouApp")
        XCTAssertTrue(transitiveDeps.contains("XrayCore"))
        XCTAssertTrue(transitiveDeps.contains("QingzhouLogging"))

        // 4. Unresolved dynamic expression recorded instead of silently ignored
        let dynamicDepManifest = """
        import PackageDescription
        let injectedVar = "XrayCore"
        let package = Package(
            name: "Qingzhou",
            targets: [
                .target(name: "QingzhouApp", dependencies: ["QingzhouCore", injectedVar])
            ]
        )
        """
        let dynamicParsed = try PackageManifestParser.parse(dynamicDepManifest)
        let dynamicApp = try XCTUnwrap(dynamicParsed.target(named: "QingzhouApp", kind: "target"))
        XCTAssertEqual(dynamicApp.resolvedDependencyNames, ["QingzhouCore"])
        XCTAssertEqual(dynamicApp.unresolvedDependencies, ["injectedVar"])

        // 5. Missing target & malformed manifest errors
        let missingTargetManifest = """
        import PackageDescription
        let package = Package(
            name: "Qingzhou",
            targets: [
                .target(name: "QingzhouCore")
            ]
        )
        """
        let missingParsed = try PackageManifestParser.parse(missingTargetManifest)
        XCTAssertNil(missingParsed.target(named: "QingzhouApp", kind: "target"))
        XCTAssertThrowsError(try missingParsed.transitiveDependencyNames(of: "QingzhouApp")) { error in
            XCTAssertEqual(error as? PackageManifestParser.ParseError, .targetNotFound("QingzhouApp"))
        }

        XCTAssertThrowsError(try PackageManifestParser.parse("let x = 1")) { error in
            XCTAssertEqual(error as? PackageManifestParser.ParseError, .missingPackageCall)
        }
        XCTAssertThrowsError(try PackageManifestParser.parse("let p = Package(name: \"Empty\")")) { error in
            XCTAssertEqual(error as? PackageManifestParser.ParseError, .missingTargetsArray)
        }

        // 6. Comment stripping helper preserves import detection across inline block comments
        let sampleSource = """
        // import XrayCore
        /* import XrayConfig */
        import/*sneaky*/XrayCore
        """
        let stripped = PackageManifestParser.strippingComments(sampleSource)
        let importRegex = try NSRegularExpression(
            pattern: #"\bimport\s+(?:(?:struct|class|enum|protocol|typealias|func|var|let)\s+)?(XrayCore|XrayConfig|LibXray)\b"#
        )
        let nsRange = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
        let matches = importRegex.matches(in: stripped, range: nsRange)
        XCTAssertEqual(matches.count, 1)
    }
}
