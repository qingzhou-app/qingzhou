import XCTest
@testable import QingzhouCore

final class RulesTransportTests: XCTestCase {

    func testRoundTripPreservesRulesAndOrder() throws {
        let rules = [
            Rule(type: .domainSuffix, value: "example.com", target: .reject, comment: "test"),
            Rule(type: .ipCIDR, value: "10.0.0.0/8", target: .direct),
            Rule(type: .final, value: "", target: .proxy)
        ]
        let decoded = try RulesTransport.decode(try RulesTransport.encode(rules))
        XCTAssertEqual(decoded, rules, "编解码往返必须无损（含顺序、id、comment）")
    }

    func testEmptyRulesRoundTrip() throws {
        let decoded = try RulesTransport.decode(try RulesTransport.encode([]))
        XCTAssertTrue(decoded.isEmpty)
    }

    func testLargeRuleSetCompressesWell() throws {
        // 模拟几千条远程规则：压缩后必须显著小于原始 JSON，
        // 否则 providerConfiguration / sendProviderMessage 的大小限制扛不住
        let rules = (0..<5000).map { i in
            Rule(type: .domainSuffix, value: "domain-\(i).example.com", target: .proxy)
        }
        let payload = try RulesTransport.encode(rules)
        let rawJSON = try JSONEncoder().encode(rules)
        XCTAssertLessThan(payload.count, rawJSON.count / 3, "zlib 对规则 JSON 至少压到 1/3")
        XCTAssertEqual(try RulesTransport.decode(payload).count, 5000)
    }

    func testGarbageDataThrows() {
        XCTAssertThrowsError(try RulesTransport.decode(Data([0x00, 0x01, 0x02, 0xFF])))
        XCTAssertThrowsError(try RulesTransport.decode(Data()))
    }
}
