import XCTest
@testable import XrayCore

final class XrayCoreTests: XCTestCase {

    /// 最重要的一个测试：xcframework 能加载、xray-core 能 dlopen 成功。
    /// 这测试就是「我们的链接正确性」的烟雾测试。
    func testXrayVersionIsNonEmpty() {
        let v = XrayCore.version
        XCTAssertFalse(v.isEmpty)
        XCTAssertNotEqual(v, "stub-no-libxray", "LibXray.xcframework 未被 link，请重新跑 scripts/build-libxray.sh")
    }

    /// xray-core 未启动时应当返回 false。
    func testIsRunningInitiallyFalse() {
        XCTAssertFalse(XrayCore.isRunning)
    }

    /// libXray 内置链接转 JSON：测一个简单的 trojan 链接。
    func testConvertShareLinkProducesValidJSON() throws {
        let trojanLink = "trojan://password@example.com:443?sni=example.com#test"
        let json = try XrayCore.convertShareLinks(trojanLink)
        XCTAssertFalse(json.isEmpty)

        // 解析 JSON 验证它含 outbounds
        guard let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("returned JSON is not parseable")
            return
        }
        // xray JSON 顶层应该有 outbounds 字段
        XCTAssertNotNil(obj["outbounds"])
    }
}
