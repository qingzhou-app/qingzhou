import XCTest
@testable import VPNCore

final class RegionDetectorTests: XCTestCase {

    func testChineseNames() {
        XCTAssertEqual(RegionDetector.detect(from: "香港-HK-1"), "香港")
        XCTAssertEqual(RegionDetector.detect(from: "日本-TY-1-流量倍率:1.0"), "日本")
        XCTAssertEqual(RegionDetector.detect(from: "荷兰-NL-1-流量倍率:0.4"), "荷兰")
        XCTAssertEqual(RegionDetector.detect(from: "新加坡 03"), "新加坡")
    }

    func testCountryCodesAsTokens() {
        XCTAssertEqual(RegionDetector.detect(from: "Premium-HK-02"), "香港")
        XCTAssertEqual(RegionDetector.detect(from: "JP-Tokyo-1"), "日本")
        XCTAssertEqual(RegionDetector.detect(from: "node-US-west"), "美国")
    }

    /// 关键回归：短码不能子串误命中。
    func testShortCodeDoesNotSubstringMatch() {
        // "US" 不应命中 "RUSSIA" / "AUSTRALIA"
        XCTAssertEqual(RegionDetector.detect(from: "Russia-Moscow"), "俄罗斯")
        XCTAssertEqual(RegionDetector.detect(from: "Australia-Sydney"), "澳大利亚")
        // 纯英文国家名（长名子串匹配）
        XCTAssertEqual(RegionDetector.detect(from: "Singapore-Premium"), "新加坡")
    }

    func testEmojiFlags() {
        XCTAssertEqual(RegionDetector.detect(from: "🇭🇰 香港 IEPL"), "香港")
        XCTAssertEqual(RegionDetector.detect(from: "🇯🇵 Osaka"), "日本")
    }

    func testUnknownReturnsNilAndOther() {
        XCTAssertNil(RegionDetector.detect(from: "Premium-Node-001"))
        XCTAssertEqual(RegionDetector.regionOrOther(for: "Premium-Node-001"), "其它")
    }
}
