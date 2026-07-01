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

    /// 节点导出：分享链接 → xray JSON → 再转回分享链接，应还是个 trojan 链接。
    func testConvertJSONToShareLinksRoundtrip() throws {
        let json = try XrayCore.convertShareLinks("trojan://password@example.com:443?sni=example.com#test")
        let links = try XrayCore.convertJSONToShareLinks(json)
        XCTAssertTrue(links.contains("trojan://"), "导出的分享链接应包含 trojan://，实际: \(links)")
    }

    /// 配置校验：一坨非法内容应当被 TestXray 拒绝并抛错。
    func testValidateRejectsGarbage() {
        XCTAssertThrowsError(try XrayCore.validate(configJSON: "{ not a valid xray config }")) { err in
            XCTAssertTrue(err is XrayError)
        }
    }

    /// 流量统计：metrics 端点不可达时应优雅抛错（而不是崩）。
    func testQueryStatsUnreachableThrows() {
        XCTAssertThrowsError(try XrayCore.queryStats(metricsURL: "http://127.0.0.1:1/debug/vars"))
    }
}
