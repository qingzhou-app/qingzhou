import XCTest
import VPNCore
@testable import XrayConfig

final class XrayConfigComposerTests: XCTestCase {

    /// 手工写的 trojan outbound（compose 不关心具体协议字段，只把 outbounds 数组裹进完整配置）。
    /// 不走 libXray —— 这层逻辑就是字典操作，没必要拖 Go runtime 进单测。
    private let fakeTrojanOutbounds = #"""
    {
      "outbounds": [
        {
          "protocol": "trojan",
          "settings": {
            "servers": [
              {"address": "example.com", "port": 443, "password": "pw"}
            ]
          },
          "streamSettings": {
            "network": "tcp",
            "security": "tls",
            "tlsSettings": {"serverName": "example.com"}
          }
        }
      ]
    }
    """#

    // MARK: - 结构性测试

    func testComposeWrapsOutboundIntoFullConfigGlobal() throws {
        let composed = try XrayConfigComposer.compose(outboundsJSON: fakeTrojanOutbounds, mode: .global)

        let json = try parse(composed)
        XCTAssertNotNil(json["inbounds"])
        XCTAssertNotNil(json["outbounds"])
        XCTAssertNotNil(json["routing"])
        XCTAssertNotNil(json["dns"])
        XCTAssertNotNil(json["log"])

        let inbounds = json["inbounds"] as! [[String: Any]]
        XCTAssertEqual(inbounds.count, 1)
        XCTAssertEqual(inbounds[0]["protocol"] as? String, "tun")

        let outs = json["outbounds"] as! [[String: Any]]
        XCTAssertGreaterThanOrEqual(outs.count, 3)
        let tags = outs.compactMap { $0["tag"] as? String }
        XCTAssertTrue(tags.contains("proxy"))
        XCTAssertTrue(tags.contains("direct"))
        XCTAssertTrue(tags.contains("reject"))

        let proxy = outs.first(where: { $0["tag"] as? String == "proxy" })!
        XCTAssertEqual(proxy["protocol"] as? String, "trojan")
    }

    func testRoutingRulesGlobalSendsAllToProxy() throws {
        let json = try parse(try XrayConfigComposer.compose(outboundsJSON: fakeTrojanOutbounds, mode: .global))
        let rules = (json["routing"] as! [String: Any])["rules"] as! [[String: Any]]
        let last = rules.last!
        XCTAssertEqual(last["outboundTag"] as? String, "proxy")
        XCTAssertTrue(rules.contains { r in
            (r["outboundTag"] as? String) == "direct" &&
            ((r["ip"] as? [String])?.contains("10.0.0.0/8") ?? false)
        })
    }

    func testRoutingRulesRuleModeIncludesGeositeCn() throws {
        let json = try parse(try XrayConfigComposer.compose(outboundsJSON: fakeTrojanOutbounds, mode: .rule))
        let rules = (json["routing"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertTrue(rules.contains { r in
            (r["outboundTag"] as? String) == "direct" &&
            ((r["domain"] as? [String])?.contains("geosite:cn") ?? false)
        })
        XCTAssertTrue(rules.contains { r in
            (r["outboundTag"] as? String) == "direct" &&
            ((r["ip"] as? [String])?.contains("geoip:cn") ?? false)
        })
    }

    func testRoutingRulesDirectModeSendsAllToDirect() throws {
        let json = try parse(try XrayConfigComposer.compose(outboundsJSON: fakeTrojanOutbounds, mode: .direct))
        let rules = (json["routing"] as! [String: Any])["rules"] as! [[String: Any]]
        for r in rules {
            XCTAssertEqual(r["outboundTag"] as? String, "direct")
        }
    }

    func testDNSGlobalUsesPublicServers() throws {
        let json = try parse(try XrayConfigComposer.compose(outboundsJSON: fakeTrojanOutbounds, mode: .global))
        let dns = json["dns"] as! [String: Any]
        let servers = dns["servers"] as! [Any]
        XCTAssertEqual(servers.first as? String, "8.8.8.8")
        XCTAssertEqual(dns["queryStrategy"] as? String, "UseIP")
    }

    func testDNSRuleModeIncludesChinaDNS() throws {
        let json = try parse(try XrayConfigComposer.compose(outboundsJSON: fakeTrojanOutbounds, mode: .rule))
        let dns = json["dns"] as! [String: Any]
        let servers = dns["servers"] as! [Any]
        let alidns = servers.first { entry in
            (entry as? [String: Any])?["address"] as? String == "223.5.5.5"
        }
        XCTAssertNotNil(alidns)
    }

    // MARK: - 防御性清理 libXray 错填字段

    /// libXray 在某些 share link 上会把节点显示名塞进 outbound.sendThrough。
    /// sendThrough 本意是本地绑定 IP，xray-core 当 net.IP 解析必失败 →
    /// "unable to send through: <node 名>"。compose 必须主动剔除。
    func testComposeStripsSendThroughFromAllOutbounds() throws {
        let fakeOutboundsJSON = #"""
        {
          "outbounds": [
            {
              "tag": "whatever",
              "protocol": "trojan",
              "sendThrough": "日本-TY-2-流量倍率:1.0",
              "settings": {
                "servers": [{"address": "example.com", "port": 443, "password": "pw"}]
              }
            }
          ]
        }
        """#
        let composed = try XrayConfigComposer.compose(outboundsJSON: fakeOutboundsJSON, mode: .global)
        let json = try parse(composed)
        let outs = json["outbounds"] as! [[String: Any]]
        for out in outs {
            XCTAssertNil(out["sendThrough"],
                         "sendThrough 必须从所有 outbound 上剔除，否则 xray-core 启动会失败")
        }
    }

    // MARK: - 错误路径

    func testComposeRejectsInvalidJSON() {
        XCTAssertThrowsError(
            try XrayConfigComposer.compose(outboundsJSON: "not json", mode: .global)
        )
    }

    func testComposeRejectsEmptyOutbounds() {
        XCTAssertThrowsError(
            try XrayConfigComposer.compose(outboundsJSON: #"{"outbounds":[]}"#, mode: .global)
        )
    }

    // MARK: - helpers

    private func parse(_ s: String) throws -> [String: Any] {
        let data = s.data(using: .utf8)!
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
