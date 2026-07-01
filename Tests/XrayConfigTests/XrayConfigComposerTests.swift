import XCTest
import QingzhouCore
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
        // 除了最前面的 DNS 拦截（→ dns-out，fakedns 用），其余都走 direct
        for r in rules where r["outboundTag"] as? String != "dns-out" {
            XCTAssertEqual(r["outboundTag"] as? String, "direct")
        }
    }

    func testDNSGlobalUsesPublicServers() throws {
        let json = try parse(try XrayConfigComposer.compose(outboundsJSON: fakeTrojanOutbounds, mode: .global))
        let dns = json["dns"] as! [String: Any]
        let servers = dns["servers"] as! [Any]
        XCTAssertEqual(servers.first as? String, "fakedns", "fakedns 拦在最前，才能给域名分配假 IP")
        XCTAssertTrue(servers.contains { $0 as? String == "8.8.8.8" }, "真实 DNS 仍在，用于实际连接解析")
        XCTAssertEqual(dns["queryStrategy"] as? String, "UseIP")
    }

    /// FakeDNS：让 access log/路由拿到真域名而不是 IP（SNI 常被 ECH 加密，纯 sniffing 只见 IP）。
    func testComposeEnablesFakeDNS() throws {
        let json = try parse(try XrayConfigComposer.compose(outboundsJSON: fakeTrojanOutbounds, mode: .global))
        let fakedns = json["fakedns"] as? [[String: Any]]
        XCTAssertEqual(fakedns?.first?["ipPool"] as? String, "198.18.0.0/15", "应配 fakedns 假 IP 池")
        let inbounds = json["inbounds"] as! [[String: Any]]
        let sniffing = inbounds[0]["sniffing"] as! [String: Any]
        XCTAssertTrue((sniffing["destOverride"] as! [String]).contains("fakedns"),
                      "sniffing destOverride 要含 fakedns 才能把假 IP 反查回域名")
    }

    /// fakedns 只有配了「DNS 查询 → dns-out」路由才会真正触发（否则 DNS 被当普通流量转发到真实 DNS）。
    func testDNSQueriesRoutedToDNSOut() throws {
        for mode in [ProxyMode.global, .rule, .direct] {
            let json = try parse(try XrayConfigComposer.compose(outboundsJSON: fakeTrojanOutbounds, mode: mode))
            let outs = json["outbounds"] as! [[String: Any]]
            XCTAssertTrue(outs.contains { $0["tag"] as? String == "dns-out" && $0["protocol"] as? String == "dns" },
                          "\(mode) 缺 dns-out outbound")
            let rules = (json["routing"] as! [String: Any])["rules"] as! [[String: Any]]
            XCTAssertEqual(rules.first?["port"] as? Int, 53, "\(mode) 第一条路由必须是 DNS 拦截")
            XCTAssertEqual(rules.first?["outboundTag"] as? String, "dns-out")
        }
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

    // MARK: - 只有一个 tun inbound（本地代理已移除）

    func testComposeHasOnlyTunInbound() throws {
        let json = try parse(try XrayConfigComposer.compose(outboundsJSON: fakeTrojanOutbounds, mode: .global))
        let inbounds = json["inbounds"] as! [[String: Any]]
        XCTAssertEqual(inbounds.count, 1)
        XCTAssertEqual(inbounds[0]["protocol"] as? String, "tun")
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

    /// libXray.convertShareLinks 对 hysteria2（`hy2://...insecure=1`）这类链接仍会在
    /// streamSettings 里产出 `allowInsecure`。我们打包的 xray-core 已硬移除该字段，带着它
    /// 整个 outbound TLS 解析失败、xray 起不来。compose 必须递归剔除——无论它藏多深。
    func testComposeStripsAllowInsecureRecursively() throws {
        let fakeOutboundsJSON = #"""
        {
          "outbounds": [
            {
              "tag": "whatever",
              "protocol": "hysteria2",
              "settings": {
                "servers": [{"address": "jp.example.com", "port": 443}]
              },
              "streamSettings": {
                "security": "tls",
                "tlsSettings": {"serverName": "jp.example.com", "allowInsecure": true}
              }
            }
          ]
        }
        """#
        let composed = try XrayConfigComposer.compose(outboundsJSON: fakeOutboundsJSON, mode: .global)
        XCTAssertFalse(composed.contains("allowInsecure"),
                       "allowInsecure 必须从最终配置里彻底消失，否则这版 xray-core 起不来")
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
