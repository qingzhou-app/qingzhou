import XCTest
import QingzhouCore
@testable import XrayConfig

/// 「国内直连、其余全走海外出口、断了也不漏」的配置语义测试。
///
/// 这些断言故意写得"贴名字"（tag 字符串、规则顺序、域名条目），因为它们就是验收脚本
/// 归因的依据：spec 里说「海外出口组里没有 DIRECT」「geolocation-!cn 排在国内名单前面」，
/// 这里就必须能证明配置真的长那样，而不是只证明"能生成一段 JSON"。
final class SplitExitPlanTests: XCTestCase {

    private func node(
        _ name: String,
        _ proto: ProxyProtocol,
        host: String,
        port: Int,
        password: String? = nil,
        params: [String: String] = [:]
    ) -> Node {
        Node(name: name, protocolType: proto, host: host, port: port,
             password: password, parameters: params)
    }

    /// 住宅 SOCKS5（出口）+ 香港 trojan（跳板）
    private func makePlan(lists: SplitExitPlan.Lists = .init()) -> SplitExitPlan {
        let exit = node("住宅", .socks5, host: "203.0.113.9", port: 1080,
                        password: "p@ss", params: ["username": "u"])
        let hop = node("HK-01", .trojan, host: "hk.example.com", port: 443, password: "pw")
        return SplitExitPlan(exitNode: exit, hopNode: hop, lists: lists)
    }

    // MARK: - 出口结构

    func testExitGroupHasOnlyResidentialProxyAndNoDirect() throws {
        let outbounds = try makePlan().outbounds()
        let exit = try XCTUnwrap(outbounds.first { $0["tag"] as? String == SplitExitPlan.Tag.exit })
        XCTAssertEqual(exit["protocol"] as? String, "socks", "海外出口必须是 SOCKS5 出站，不能是 freedom")

        // 组里没有 DIRECT：既没有 freedom，也没有任何别的成员被当作 exit。
        let exitLike = outbounds.filter { $0["tag"] as? String == SplitExitPlan.Tag.exit }
        XCTAssertEqual(exitLike.count, 1)
        XCTAssertNotEqual(exit["protocol"] as? String, "freedom")
    }

    func testResidentialTrafficGoesThroughHop() throws {
        let outbounds = try makePlan().outbounds()
        let exit = try XCTUnwrap(outbounds.first { $0["tag"] as? String == SplitExitPlan.Tag.exit })
        let stream = try XCTUnwrap(exit["streamSettings"] as? [String: Any])
        let sockopt = try XCTUnwrap(stream["sockopt"] as? [String: Any])
        XCTAssertEqual(sockopt["dialerProxy"] as? String, SplitExitPlan.Tag.hop,
                       "住宅代理自己必须经跳板出去，否则国内连不上 + 暴露真实 IP")

        let hop = try XCTUnwrap(outbounds.first { $0["tag"] as? String == SplitExitPlan.Tag.hop })
        XCTAssertEqual(hop["protocol"] as? String, "trojan")
    }

    func testHopIsNeverARoutingTarget() throws {
        let plan = makePlan()
        let rules = try XCTUnwrap(plan.routing()["rules"] as? [[String: Any]])
        XCTAssertFalse(rules.contains { $0["outboundTag"] as? String == SplitExitPlan.Tag.hop },
                       "跳板只做 dialerProxy，不能成为任何规则的目标")
    }

    func testSocksOutboundCarriesCredentials() throws {
        let outbounds = try makePlan().outbounds()
        let exit = try XCTUnwrap(outbounds.first { $0["tag"] as? String == SplitExitPlan.Tag.exit })
        let settings = try XCTUnwrap(exit["settings"] as? [String: Any])
        let servers = try XCTUnwrap(settings["servers"] as? [[String: Any]])
        let server = try XCTUnwrap(servers.first)
        XCTAssertEqual(server["address"] as? String, "203.0.113.9")
        XCTAssertEqual(server["port"] as? Int, 1080)
        let users = try XCTUnwrap(server["users"] as? [[String: String]])
        XCTAssertEqual(users.first?["user"], "u")
        XCTAssertEqual(users.first?["pass"], "p@ss")
    }

    func testSameHopAndExitIsRejected() {
        let n = node("同一个", .socks5, host: "203.0.113.9", port: 1080, password: "p")
        let plan = SplitExitPlan(exitNode: n, hopNode: n)
        XCTAssertThrowsError(try plan.compose()) { error in
            XCTAssertEqual(error as? SplitExitPlan.PlanError, .hopEqualsExit)
        }
    }

    // MARK: - 规则顺序

    private func ruleIndex(_ rules: [[String: Any]], where predicate: ([String: Any]) -> Bool) -> Int? {
        rules.firstIndex(where: predicate)
    }

    /// 需求：geolocation-!cn 必须排在国内名单之前，否则 googletagmanager 这类
    /// 混在国内名单里的海外域名会用国内 IP 出去。
    func testOverseasCategoryComesBeforeChinaLists() throws {
        let rules = try XCTUnwrap(makePlan().routing()["rules"] as? [[String: Any]])
        let overseas = try XCTUnwrap(ruleIndex(rules) { rule in
            (rule["domain"] as? [String])?.contains("geosite:geolocation-!cn") == true
        })
        let cnDomain = try XCTUnwrap(ruleIndex(rules) { rule in
            (rule["domain"] as? [String])?.contains("geosite:cn") == true
        })
        let cnIP = try XCTUnwrap(ruleIndex(rules) { rule in
            (rule["ip"] as? [String])?.contains("geoip:cn") == true
        })
        XCTAssertLessThan(overseas, cnDomain)
        XCTAssertLessThan(overseas, cnIP)
    }

    /// 需求：Claude、B 站/微信、局域网 都要排在海外分类之前。
    func testPriorityOrderMatchesSpec() throws {
        let rules = try XCTUnwrap(makePlan().routing()["rules"] as? [[String: Any]])

        let claude = try XCTUnwrap(ruleIndex(rules) { rule in
            (rule["domain"] as? [String])?.contains("domain:claude.ai") == true
        })
        let lan = try XCTUnwrap(ruleIndex(rules) { rule in
            (rule["ip"] as? [String])?.contains("100.64.0.0/10") == true
        })
        let bilibili = try XCTUnwrap(ruleIndex(rules) { rule in
            (rule["domain"] as? [String])?.contains("geosite:bilibili") == true
        })
        let overseas = try XCTUnwrap(ruleIndex(rules) { rule in
            (rule["domain"] as? [String])?.contains("geosite:geolocation-!cn") == true
        })
        XCTAssertLessThan(claude, lan)
        XCTAssertLessThan(lan, bilibili)
        XCTAssertLessThan(bilibili, overseas)
    }

    func testClaudeRuleCoversDomainsAndKeywords() throws {
        let rules = try XCTUnwrap(makePlan().routing()["rules"] as? [[String: Any]])
        let rule = try XCTUnwrap(rules.first { r in
            (r["domain"] as? [String])?.contains("domain:claude.ai") == true
        })
        let entries = try XCTUnwrap(rule["domain"] as? [String])
        XCTAssertEqual(rule["outboundTag"] as? String, SplitExitPlan.Tag.exit)
        for expected in ["full:claude.ai", "domain:claude.com", "domain:anthropic.com",
                         "domain:claudeusercontent.com", "domain:claudemcpclient.com",
                         "claude", "anthropic"] {
            XCTAssertTrue(entries.contains(expected), "缺 \(expected)")
        }
    }

    func testBilibiliMatchesMirrorAkamByKeyword() throws {
        let rules = try XCTUnwrap(makePlan().routing()["rules"] as? [[String: Any]])
        let rule = try XCTUnwrap(rules.first { r in
            (r["domain"] as? [String])?.contains("geosite:bilibili") == true
        })
        let entries = try XCTUnwrap(rule["domain"] as? [String])
        XCTAssertTrue(entries.contains("mirrorakam"), "mirrorakam 只能按关键字匹配")
        XCTAssertTrue(entries.contains("domain:bilibili.com"))
        XCTAssertEqual(rule["outboundTag"] as? String, SplitExitPlan.Tag.direct)
    }

    func testWechatUsesTencentCategoryBecauseWechatCategoryMissing() throws {
        let rules = try XCTUnwrap(makePlan().routing()["rules"] as? [[String: Any]])
        let rule = try XCTUnwrap(rules.first { r in
            (r["domain"] as? [String])?.contains("geosite:tencent") == true
        })
        let entries = try XCTUnwrap(rule["domain"] as? [String])
        XCTAssertTrue(entries.contains("domain:weixin.qq.com"))
        XCTAssertTrue(entries.contains("full:wechat.com"))
        XCTAssertEqual(rule["outboundTag"] as? String, SplitExitPlan.Tag.direct)
    }

    func testFinalRuleGoesToExitAndUDPIsRejected() throws {
        let rules = try XCTUnwrap(makePlan().routing()["rules"] as? [[String: Any]])
        let last = try XCTUnwrap(rules.last)
        let tail = try XCTUnwrap(rules.last(where: { $0["network"] as? String == "tcp" }))
        XCTAssertEqual(tail["outboundTag"] as? String, SplitExitPlan.Tag.exit)
        XCTAssertNil(last["domain"])
        XCTAssertNil(last["ip"])

        let udpTail = try XCTUnwrap(rules.last { ($0["network"] as? String) == "udp" && $0["domain"] == nil && $0["ip"] == nil })
        XCTAssertEqual(udpTail["outboundTag"] as? String, SplitExitPlan.Tag.reject,
                       "海外出口没有 UDP，必须拒绝而不是回退直连")
    }

    func testNoRuleTargetsDirectByAccident() throws {
        let rules = try XCTUnwrap(makePlan().routing()["rules"] as? [[String: Any]])
        let directRules = rules.filter { $0["outboundTag"] as? String == SplitExitPlan.Tag.direct }
        // 允许直连的只有：DNS 上游（2 条）、局域网、B 站、微信、国内域名、国内 IP
        XCTAssertEqual(directRules.count, 6, "多出来的直连规则意味着有流量绕过了海外出口")
    }

    // MARK: - 注入名单

    func testInjectedChinaListsLandInChinaRules() throws {
        let lists = SplitExitPlan.Lists(cnDomains: ["example.cn"], cnCIDRs: ["1.0.1.0/24"])
        let rules = try XCTUnwrap(makePlan(lists: lists).routing()["rules"] as? [[String: Any]])

        let domainRule = try XCTUnwrap(rules.first { r in
            (r["domain"] as? [String])?.contains("geosite:cn") == true
        })
        XCTAssertTrue((domainRule["domain"] as? [String])?.contains("domain:example.cn") == true)

        let ipRule = try XCTUnwrap(rules.first { r in
            (r["ip"] as? [String])?.contains("geoip:cn") == true
        })
        XCTAssertTrue((ipRule["ip"] as? [String])?.contains("1.0.1.0/24") == true)
    }

    // MARK: - DNS

    func testDNSDoesNotReturnIPv6() throws {
        let plan = makePlan()
        let dns = plan.dns()
        XCTAssertEqual(dns["queryStrategy"] as? String, "UseIPv4")
        // 只有 IPv4 假 IP 池 —— 没有 fc00::/18
        let pools = plan.fakeDNS()
        XCTAssertEqual(pools.count, 1)
        XCTAssertEqual(pools[0]["ipPool"] as? String, "198.18.0.0/15")
    }

    func testDNSRoutesNodeHostnamesToDomesticResolver() throws {
        let dns = makePlan().dns()
        let servers = try XCTUnwrap(dns["servers"] as? [Any])
        // 第一个是 fakedns，随后是国内解析器
        XCTAssertEqual(servers.first as? String, "fakedns")
        let domestic = try XCTUnwrap(servers.dropFirst().first as? [String: Any])
        XCTAssertEqual(domestic["address"] as? String, "223.5.5.5")
        let domains = try XCTUnwrap(domestic["domains"] as? [String])
        XCTAssertTrue(domains.contains("geosite:cn"))
        XCTAssertTrue(domains.contains("full:hk.example.com"), "跳板域名必须用国内 DNS 解析，否则自指成环")
    }

    func testDNSUpstreamQueriesSplitByResolver() throws {
        let plan = makePlan()
        let rules = try XCTUnwrap(plan.routing()["rules"] as? [[String: Any]])
        // dns-module → 国内解析器直连；其余 dns-module 查询走出口
        let first = try XCTUnwrap(rules.first)
        XCTAssertEqual((first["inboundTag"] as? [String])?.first, "dns-module")
        XCTAssertEqual(first["outboundTag"] as? String, SplitExitPlan.Tag.direct)
        XCTAssertTrue((first["ip"] as? [String])?.contains("223.5.5.5") == true)

        let second = rules[1]
        XCTAssertEqual((second["inboundTag"] as? [String])?.first, "dns-module")
        XCTAssertEqual(second["outboundTag"] as? String, SplitExitPlan.Tag.exit,
                       "海外 DNS 查询必须经海外出口，且失败时不能回退国内 DNS")
    }

    // MARK: - 完整配置

    func testComposedConfigIsSerializableAndComplete() throws {
        let json = try makePlan().composeJSON(accessLogPath: "/tmp/access.log", publicIPPort: 18080)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let config = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.map { $0["tag"] as? String },
                       ["exit", "hop", "direct", "reject", "dns-out"])

        let rules = try XCTUnwrap((config["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertEqual((rules.first?["inboundTag"] as? [String])?.first, "public-ip-in",
                       "出口 IP 探针必须最先匹配，不能被分流改道")
        XCTAssertEqual(rules.first?["outboundTag"] as? String, SplitExitPlan.Tag.exit)

        let inbounds = try XCTUnwrap(config["inbounds"] as? [[String: Any]])
        XCTAssertEqual(inbounds.count, 2)
        let sniffing = try XCTUnwrap(inbounds[0]["sniffing"] as? [String: Any])
        XCTAssertEqual(sniffing["enabled"] as? Bool, true)
    }

    /// 出口 IP 探针入口只允许连固定目标，不能变成开放代理。
    func testPublicIPInletIsFixedTarget() throws {
        let config = try makePlan().compose(publicIPPort: 18080)
        let inbounds = try XCTUnwrap(config["inbounds"] as? [[String: Any]])
        let probe = try XCTUnwrap(inbounds.first { $0["tag"] as? String == "public-ip-in" })
        let settings = try XCTUnwrap(probe["settings"] as? [String: Any])
        XCTAssertEqual(settings["address"] as? String, PublicIPProbe.host)
    }
}
