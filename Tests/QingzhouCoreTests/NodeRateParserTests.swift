import XCTest
@testable import QingzhouCore

final class NodeRateParserTests: XCTestCase {
    func testCommonAirportNamingConventions() {
        // 各机场常见写法都要认出来
        let cases: [(String, Double?)] = [
            ("香港 01 | 2x", 2.0),
            ("🇭🇰 HK 2X 专线", 2.0),
            ("美国 0.5倍", 0.5),
            ("[3x] 台湾", 3.0),
            ("日本 IEPL x1.5", 1.5),
            ("新加坡 倍率:2.0", 2.0),
            ("香港-高倍-5x-", 5.0),
            ("HKG 2.0x", 2.0),
            ("狮城 倍率：0.8", 0.8),
            ("台湾 x2 Netflix", 2.0),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(NodeRateParser.fromName(name), expected, "「\(name)」应识别为 \(String(describing: expected))")
        }
    }

    func testNoRateInName() {
        XCTAssertNil(NodeRateParser.fromName("香港 01"))
        XCTAssertNil(NodeRateParser.fromName("美国 IEPL 专线"))
        XCTAssertNil(NodeRateParser.fromName("Tokyo Premium"))
    }

    func testAvoidsFalsePositives() {
        // 数字紧贴字母、非倍率语境不应误判
        XCTAssertNil(NodeRateParser.fromName("V2Ray 香港"), "V2 不是倍率")
        XCTAssertNil(NodeRateParser.fromName("美国 4K 流媒体"), "4K 不是倍率")
        XCTAssertNil(NodeRateParser.fromName("IPv6 日本"), "IPv6 不是倍率")
    }

    func testParseMetadataRawValue() {
        XCTAssertEqual(NodeRateParser.parse("2"), 2.0)
        XCTAssertEqual(NodeRateParser.parse("0.5"), 0.5)
        XCTAssertEqual(NodeRateParser.parse("1.5x"), 1.5)
        XCTAssertNil(NodeRateParser.parse(""))
        XCTAssertNil(NodeRateParser.parse(nil))
        XCTAssertNil(NodeRateParser.parse("999999"), "超出合理区间")
    }

    func testEffectiveRateMetadataWinsOverName() {
        var node = Node(name: "香港 2x", protocolType: .trojan, host: "a.com", port: 443)
        // 只有名字：从名字识别 2x
        XCTAssertEqual(node.effectiveRate, 2.0)
        // 元数据存在：元数据优先
        node.parameters["rate"] = "0.5"
        XCTAssertEqual(node.effectiveRate, 0.5)
        XCTAssertEqual(node.rateForComparison, 0.5)
    }

    func testRateForComparisonDefaultsToOne() {
        let node = Node(name: "香港 01", protocolType: .trojan, host: "a.com", port: 443)
        XCTAssertNil(node.effectiveRate)
        XCTAssertEqual(node.rateForComparison, 1.0, "识别不出倍率按 1.0 比较")
    }
}
