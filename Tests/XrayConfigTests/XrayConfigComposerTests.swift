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

    func testRuleModeFullGeoDataUnlocksForeignGeoIPRules() throws {
        // 完整版 geoip.dat 就位（扩展传 hasFullGeoIP=true）：GEOIP,us 之类的用户规则
        // 必须真实进入 routing —— 这正是"下载完整版"功能解锁的能力。
        let userRules = [Rule(type: .geoip, value: "us", target: .proxy)]
        let with = try parse(try XrayConfigComposer.compose(
            outboundsJSON: fakeTrojanOutbounds, mode: .rule,
            userRules: userRules, hasFullGeoIP: true))
        let rulesWith = (with["routing"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertTrue(rulesWith.contains { r in
            (r["outboundTag"] as? String) == "proxy" &&
            ((r["ip"] as? [String])?.contains("geoip:us") ?? false)
        }, "hasFullGeoIP=true 时 GEOIP,us 应进入 routing")

        // 默认（精简版）同一条规则必须被跳过 —— xray 对缺失分类直接启动失败。
        let without = try parse(try XrayConfigComposer.compose(
            outboundsJSON: fakeTrojanOutbounds, mode: .rule, userRules: userRules))
        let rulesWithout = (without["routing"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertFalse(rulesWithout.contains { r in
            ((r["ip"] as? [String])?.contains("geoip:us") ?? false)
        }, "精简版下 GEOIP,us 不得透传")
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

    // MARK: - 用户规则注入（自定义 + 远程规则真正生效的关键）

    /// rule 模式：用户规则必须插在「DNS 拦截之后、内置 geosite/geoip 规则之前」——
    /// xray 按序 first-match，这个位置 = 用户规则优先于内置规则，但不破坏 fakedns。
    func testRuleModeInsertsUserRulesBeforeBuiltins() throws {
        let userRules = [
            Rule(type: .domainSuffix, value: "example.com", target: .reject),
            Rule(type: .ipCIDR, value: "1.2.3.0/24", target: .direct)
        ]
        let json = try parse(try XrayConfigComposer.compose(
            outboundsJSON: fakeTrojanOutbounds, mode: .rule, userRules: userRules))
        let rules = (json["routing"] as! [String: Any])["rules"] as! [[String: Any]]

        // 第一条仍是 DNS 拦截（fakedns 的命脉）
        XCTAssertEqual(rules[0]["outboundTag"] as? String, "dns-out")
        // 紧随其后是用户规则，保持传入顺序
        XCTAssertEqual(rules[1]["domain"] as? [String], ["domain:example.com"])
        XCTAssertEqual(rules[1]["outboundTag"] as? String, "reject")
        XCTAssertEqual(rules[2]["ip"] as? [String], ["1.2.3.0/24"])
        XCTAssertEqual(rules[2]["outboundTag"] as? String, "direct")
        // 内置规则在用户规则之后
        let privateIdx = rules.firstIndex { ($0["ip"] as? [String])?.contains("geoip:private") ?? false }
        XCTAssertNotNil(privateIdx)
        XCTAssertGreaterThan(privateIdx!, 2, "内置规则必须排在所有用户规则之后")
    }

    /// global 模式维持现状：全局代理不吃分流规则（与主流客户端语义一致、行为可预期）。
    func testGlobalModeIgnoresUserRules() throws {
        let userRules = [Rule(type: .domainSuffix, value: "example.com", target: .reject)]
        let json = try parse(try XrayConfigComposer.compose(
            outboundsJSON: fakeTrojanOutbounds, mode: .global, userRules: userRules))
        let rules = (json["routing"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertFalse(rules.contains { ($0["domain"] as? [String])?.contains("domain:example.com") ?? false })
    }

    func testDirectModeIgnoresUserRules() throws {
        let userRules = [Rule(type: .domainSuffix, value: "example.com", target: .proxy)]
        let json = try parse(try XrayConfigComposer.compose(
            outboundsJSON: fakeTrojanOutbounds, mode: .direct, userRules: userRules))
        let rules = (json["routing"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertFalse(rules.contains { ($0["domain"] as? [String]) != nil })
    }

    /// 用户 FINAL 规则覆盖 rule 模式内置兜底出口（"其余走代理" → 用户指定的出口）。
    func testRuleModeUserFinalOverridesCatchAll() throws {
        let userRules = [Rule(type: .final, value: "", target: .direct)]
        let json = try parse(try XrayConfigComposer.compose(
            outboundsJSON: fakeTrojanOutbounds, mode: .rule, userRules: userRules))
        let rules = (json["routing"] as! [String: Any])["rules"] as! [[String: Any]]
        let last = rules.last!
        XCTAssertEqual(last["network"] as? String, "tcp,udp")
        XCTAssertEqual(last["outboundTag"] as? String, "direct",
                       "FINAL,DIRECT 应把内置 catch-all 的出口从 proxy 改成 direct")
    }

    /// 空用户规则集 = 现状不变（回归保护）。
    func testRuleModeEmptyUserRulesKeepsBuiltinLayout() throws {
        let withEmpty = try parse(try XrayConfigComposer.compose(
            outboundsJSON: fakeTrojanOutbounds, mode: .rule, userRules: []))
        let without = try parse(try XrayConfigComposer.compose(
            outboundsJSON: fakeTrojanOutbounds, mode: .rule))
        let r1 = (withEmpty["routing"] as! [String: Any])["rules"] as! [[String: Any]]
        let r2 = (without["routing"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertEqual(r1.count, r2.count)
        XCTAssertEqual(r1.last?["outboundTag"] as? String, "proxy")
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

    // MARK: - xray 内置流量统计（metricsPort）

    /// metricsPort 非 nil：stats + policy + metrics 三段齐活，metrics inbound 只听 loopback，
    /// 且 inboundTag→metrics 的路由规则插在最前（不能被 catch-all 吞掉）。
    func testComposeWithMetricsPortEnablesStats() throws {
        let json = try parse(try XrayConfigComposer.compose(
            outboundsJSON: fakeTrojanOutbounds, mode: .rule, metricsPort: 18888))

        XCTAssertNotNil(json["stats"])
        XCTAssertEqual((json["metrics"] as? [String: Any])?["tag"] as? String, "metrics")
        let policy = (json["policy"] as? [String: Any])?["system"] as? [String: Any]
        XCTAssertEqual(policy?["statsOutboundUplink"] as? Bool, true)
        XCTAssertEqual(policy?["statsOutboundDownlink"] as? Bool, true)

        let inbounds = json["inbounds"] as! [[String: Any]]
        let metricsIn = inbounds.first(where: { $0["tag"] as? String == "metrics-in" })
        XCTAssertNotNil(metricsIn, "缺 metrics inbound")
        XCTAssertEqual(metricsIn?["listen"] as? String, "127.0.0.1", "metrics 只能听 loopback")
        XCTAssertEqual(metricsIn?["port"] as? Int, 18888)
        XCTAssertEqual(metricsIn?["protocol"] as? String, "dokodemo-door")

        let rules = (json["routing"] as! [String: Any])["rules"] as! [[String: Any]]
        let first = rules.first!
        XCTAssertEqual(first["inboundTag"] as? [String], ["metrics-in"])
        XCTAssertEqual(first["outboundTag"] as? String, "metrics")
    }

    /// 默认（nil）：配置与旧版完全一致 —— 不带 stats/policy/metrics，也没有第二个 inbound。
    func testComposeWithoutMetricsPortKeepsLegacyShape() throws {
        let json = try parse(try XrayConfigComposer.compose(
            outboundsJSON: fakeTrojanOutbounds, mode: .global))
        XCTAssertNil(json["stats"])
        XCTAssertNil(json["policy"])
        XCTAssertNil(json["metrics"])
        let inbounds = json["inbounds"] as! [[String: Any]]
        XCTAssertEqual(inbounds.count, 1)
        let rules = (json["routing"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertNil(rules.first?["inboundTag"], "没开 metrics 时不该有 inboundTag 规则")
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
