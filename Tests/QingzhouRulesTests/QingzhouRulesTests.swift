import XCTest
import QingzhouCore
@testable import QingzhouRules

final class QingzhouRulesTests: XCTestCase {

    // MARK: - CIDR IPv4

    func testIPv4CIDRBasic() {
        let cidr = CIDR.parseIPv4("10.0.0.0/8")!
        XCTAssertTrue(cidr.contains(CIDR.ipv4ToUInt32("10.1.2.3")!))
        XCTAssertTrue(cidr.contains(CIDR.ipv4ToUInt32("10.255.255.255")!))
        XCTAssertFalse(cidr.contains(CIDR.ipv4ToUInt32("11.0.0.0")!))
    }

    func testIPv4CIDRFull() {
        // 0.0.0.0/0 全匹配
        let cidr = CIDR.parseIPv4("0.0.0.0/0")!
        XCTAssertTrue(cidr.contains(CIDR.ipv4ToUInt32("8.8.8.8")!))
    }

    func testIPv4CIDRSingleHost() {
        let cidr = CIDR.parseIPv4("192.168.1.1/32")!
        XCTAssertTrue(cidr.contains(CIDR.ipv4ToUInt32("192.168.1.1")!))
        XCTAssertFalse(cidr.contains(CIDR.ipv4ToUInt32("192.168.1.2")!))
    }

    func testIPv4CIDRInvalid() {
        XCTAssertNil(CIDR.parseIPv4("999.0.0.1/8"))
        XCTAssertNil(CIDR.parseIPv4("10.0.0.0/33"))
        XCTAssertNil(CIDR.parseIPv4("nope"))
    }

    // MARK: - CIDR IPv6

    func testIPv6CIDRDoubleColon() {
        let (h, l) = CIDR.ipv6Components("2001:db8::1")!
        XCTAssertEqual(h, 0x2001_0db8_0000_0000)
        XCTAssertEqual(l, 0x0000_0000_0000_0001)
    }

    func testIPv6CIDRContains() {
        let cidr = CIDR.parseIPv6("2001:db8::/32")!
        let (h, l) = CIDR.ipv6Components("2001:db8:abcd::1")!
        XCTAssertTrue(cidr.contains(high: h, low: l))
        let (h2, l2) = CIDR.ipv6Components("2001:dbf::1")!
        XCTAssertFalse(cidr.contains(high: h2, low: l2))
    }

    func testIPv6CIDRFull() {
        let cidr = CIDR.parseIPv6("::/0")!
        let (h, l) = CIDR.ipv6Components("fe80::1")!
        XCTAssertTrue(cidr.contains(high: h, low: l))
    }

    // MARK: - RuleParser

    func testParseStandardRule() throws {
        let r = try RuleParser.parseLine("DOMAIN-SUFFIX,google.com,PROXY")
        XCTAssertEqual(r.type, .domainSuffix)
        XCTAssertEqual(r.value, "google.com")
        XCTAssertEqual(r.target, .proxy)
    }

    func testParseFinal() throws {
        let r = try RuleParser.parseLine("FINAL,DIRECT")
        XCTAssertEqual(r.type, .final)
        XCTAssertEqual(r.target, .direct)
        XCTAssertEqual(r.value, "")
        XCTAssertNil(r.comment)
    }

    func testParseFinalWithCommaSeparatedInlineHashComment() throws {
        let r1 = try RuleParser.parseLine("FINAL,PROXY # a, b")
        XCTAssertEqual(r1.type, .final)
        XCTAssertEqual(r1.target, .proxy)
        XCTAssertEqual(r1.value, "")
        XCTAssertEqual(r1.comment, "a, b")
        XCTAssertEqual(r1.lineForm, "FINAL,PROXY")

        let r2 = try RuleParser.parseLine("FINAL,DIRECT # fallback, region: us")
        XCTAssertEqual(r2.target, .direct)
        XCTAssertEqual(r2.comment, "fallback, region: us")

        let r3 = try RuleParser.parseLine("FINAL,REJECT #")
        XCTAssertEqual(r3.target, .reject)
        XCTAssertNil(r3.comment)
    }

    func testParseCIDRWithFlag() throws {
        let r = try RuleParser.parseLine("IP-CIDR,10.0.0.0/8,DIRECT,no-resolve")
        XCTAssertEqual(r.type, .ipCIDR)
        XCTAssertEqual(r.value, "10.0.0.0/8")
        XCTAssertTrue(r.noResolve)
        XCTAssertNil(r.comment)
        XCTAssertEqual(r.lineForm, "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve")
    }

    func testParseNoResolveCaseInsensitiveAndWithComment() throws {
        let upper = try RuleParser.parseLine("IP-CIDR,192.168.0.0/16,DIRECT,NO-RESOLVE")
        XCTAssertTrue(upper.noResolve)
        XCTAssertNil(upper.comment)
        XCTAssertEqual(upper.lineForm, "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve")

        let mixedWithHash = try RuleParser.parseLine("GEOIP,CN,DIRECT,No-Resolve # china ip")
        XCTAssertTrue(mixedWithHash.noResolve)
        XCTAssertEqual(mixedWithHash.comment, "china ip")
        XCTAssertEqual(mixedWithHash.lineForm, "GEOIP,CN,DIRECT,no-resolve")

        let extraPart = try RuleParser.parseLine("IP-CIDR6,fc00::/7,DIRECT,lan-v6,no-resolve")
        XCTAssertTrue(extraPart.noResolve)
        XCTAssertEqual(extraPart.comment, "lan-v6")
        XCTAssertEqual(extraPart.lineForm, "IP-CIDR6,fc00::/7,DIRECT,no-resolve")
    }

    func testRuleBackwardCompatibleJSONDecodeWithoutNoResolve() throws {
        let legacyJSON = """
        {"id":"00000000-0000-0000-0000-000000000001","type":"IP-CIDR","value":"10.0.0.0/8","target":"DIRECT","comment":"legacy"}
        """
        let decoded = try JSONDecoder().decode(Rule.self, from: Data(legacyJSON.utf8))
        XCTAssertFalse(decoded.noResolve)
        XCTAssertEqual(decoded.comment, "legacy")
        XCTAssertEqual(decoded.lineForm, "IP-CIDR,10.0.0.0/8,DIRECT")

        let roundTrip = try JSONDecoder().decode(
            Rule.self,
            from: try JSONEncoder().encode(Rule(type: .ipCIDR, value: "10.0.0.0/8", target: .direct, noResolve: true))
        )
        XCTAssertTrue(roundTrip.noResolve)
        XCTAssertEqual(roundTrip.lineForm, "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve")
    }

    func testParseRejectsUnknownType() {
        XCTAssertThrowsError(try RuleParser.parseLine("BAD-TYPE,x,PROXY")) { err in
            if case .unknownType(let t) = err as? RuleParseError {
                XCTAssertEqual(t, "BAD-TYPE")
            } else { XCTFail() }
        }
    }

    func testParseAllSkipsCommentsAndEmpty() {
        let text = """
        # comment line
        ; semicolon comment
        DOMAIN-SUFFIX,google.com,PROXY

        FINAL,DIRECT
        """
        let (rules, errors) = RuleParser.parseAll(text)
        XCTAssertEqual(rules.count, 2)
        XCTAssertTrue(errors.isEmpty)
    }

    func testParseAllCollectsErrors() {
        let text = """
        DOMAIN-SUFFIX,a.com,PROXY
        INVALID-LINE
        IP-CIDR,bad.cidr/40,DIRECT
        """
        let (rules, errors) = RuleParser.parseAll(text)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(errors.count, 2)
    }

    // MARK: - RuleEngine

    private func makeEngine() -> RuleEngine {
        let rules: [Rule] = [
            Rule(type: .domain, value: "exact.com", target: .reject),
            Rule(type: .domainSuffix, value: "google.com", target: .proxy),
            Rule(type: .domainKeyword, value: "apple", target: .direct),
            Rule(type: .ipCIDR, value: "10.0.0.0/8", target: .direct),
            Rule(type: .geoip, value: "CN", target: .direct),
            Rule(type: .final, value: "", target: .proxy)
        ]
        struct CN: GeoIPResolver {
            func countryCode(for ipAddress: String) -> String? {
                ipAddress.hasPrefix("114.") ? "CN" : "US"
            }
        }
        return RuleEngine(rules: rules, geoip: CN())
    }

    func testEngineDomainExact() {
        let r = makeEngine().match(MatchContext(host: "exact.com"))
        XCTAssertEqual(r.target, .reject)
    }

    func testEngineDomainSuffixMatchesSubdomain() {
        let r = makeEngine().match(MatchContext(host: "mail.google.com"))
        XCTAssertEqual(r.target, .proxy)
    }

    func testEngineDomainSuffixMatchesApex() {
        let r = makeEngine().match(MatchContext(host: "google.com"))
        XCTAssertEqual(r.target, .proxy)
    }

    func testEngineDomainSuffixDoesNotPartialMatch() {
        // notgoogle.com 不应该被 google.com 命中
        let r = makeEngine().match(MatchContext(host: "notgoogle.com"))
        XCTAssertEqual(r.target, .proxy, "应落到 FINAL=PROXY")
    }

    func testEngineDomainKeyword() {
        let r = makeEngine().match(MatchContext(host: "apple.com"))
        XCTAssertEqual(r.target, .direct)
    }

    func testEngineIPCIDR() {
        let r = makeEngine().match(MatchContext(host: "anything", ipAddress: "10.5.5.5"))
        XCTAssertEqual(r.target, .direct)
    }

    func testEngineGEOIP() {
        let r = makeEngine().match(MatchContext(host: "weibo.example", ipAddress: "114.114.114.114"))
        XCTAssertEqual(r.target, .direct)
    }

    func testEngineFinalFallback() {
        let r = makeEngine().match(MatchContext(host: "random.example.com"))
        XCTAssertEqual(r.target, .proxy)
    }

    func testEngineDefaultDirectWhenNoFinalAndNoMatch() {
        let engine = RuleEngine(rules: [
            Rule(type: .domain, value: "a.com", target: .proxy)
        ])
        let r = engine.match(MatchContext(host: "b.com"))
        XCTAssertEqual(r.target, .direct)
    }

    // MARK: - Search

    func testEngineSearchByKeyword() {
        let engine = makeEngine()
        let results = engine.search(keyword: "google")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].value, "google.com")
    }

    func testEngineSearchByType() {
        let engine = makeEngine()
        let results = engine.search(type: .final)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].type, .final)
    }
}
