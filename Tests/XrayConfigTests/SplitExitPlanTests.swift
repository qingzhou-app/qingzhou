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

    private func makePlan(
        lists: SplitExitPlan.Lists = .init(),
        blockQUIC: Bool = true,
        rejectOverseasUDP: Bool = true,
        policyGroups: [SplitExitPolicyGroup] = []
    ) -> SplitExitPlan {
        let exit = node("住宅", .socks5, host: "203.0.113.9", port: 1080,
                        password: "p@ss", params: ["username": "u"])
        let hop = node("HK-01", .trojan, host: "hk.example.com", port: 443, password: "pw")
        return SplitExitPlan(
            exitNode: exit,
            hopNode: hop,
            lists: lists,
            blockQUIC: blockQUIC,
            rejectOverseasUDP: rejectOverseasUDP,
            policyGroups: policyGroups
        )
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

    /// 默认配置不包含任何硬编码个人服务/品牌规则。
    func testDefaultPlanContainsNoHardcodedPersonalRules() throws {
        let json = try makePlan().composeJSON()
        for legacyToken in ["claude.ai", "anthropic", "bilibili", "mirrorakam", "weixin.qq.com", "wechat.com"] {
            XCTAssertFalse(json.contains(legacyToken), "不应再硬编码 \(legacyToken)")
        }
    }

    /// 通用策略组按声明顺序生效，且排在保留网段、geolocation-!cn 与国内名单之前。
    func testPolicyGroupsOrderBeforeGeoCategoriesAndReservedCIDRs() throws {
        let gExit = SplitExitPolicyGroup(
            name: "Group Exit",
            target: .exit,
            domains: ["service-exit.example.com"],
            keywords: ["exitkw"]
        )
        let gDirect = SplitExitPolicyGroup(
            name: "Group Direct",
            target: .direct,
            domains: ["service-direct.example.cn"],
            geoSites: ["apple"]
        )
        let gReject = SplitExitPolicyGroup(
            name: "Group Reject",
            target: .reject,
            geoSites: ["category-ads-all"],
            cidrs: ["198.51.100.0/24"]
        )
        let rules = try XCTUnwrap(makePlan(policyGroups: [gExit, gDirect, gReject]).routing()["rules"] as? [[String: Any]])

        let exitIdx = try XCTUnwrap(ruleIndex(rules) {
            ($0["domain"] as? [String])?.contains("domain:service-exit.example.com") == true
        })
        let directIdx = try XCTUnwrap(ruleIndex(rules) {
            ($0["domain"] as? [String])?.contains("domain:service-direct.example.cn") == true
        })
        let rejectDomainIdx = try XCTUnwrap(ruleIndex(rules) {
            ($0["domain"] as? [String])?.contains("geosite:category-ads-all") == true
        })
        let rejectIPIdx = try XCTUnwrap(ruleIndex(rules) {
            ($0["ip"] as? [String])?.contains("198.51.100.0/24") == true
        })
        let lanIdx = try XCTUnwrap(ruleIndex(rules) {
            ($0["ip"] as? [String])?.contains("100.64.0.0/10") == true
        })
        let overseasIdx = try XCTUnwrap(ruleIndex(rules) {
            ($0["domain"] as? [String])?.contains("geosite:geolocation-!cn") == true
        })

        XCTAssertLessThan(exitIdx, directIdx)
        XCTAssertLessThan(directIdx, rejectDomainIdx)
        XCTAssertLessThan(rejectDomainIdx, rejectIPIdx)
        XCTAssertLessThan(rejectIPIdx, lanIdx)
        XCTAssertLessThan(lanIdx, overseasIdx)
    }

    func testPolicyGroupExitTargetRespectsRejectOverseasUDP() throws {
        let group = SplitExitPolicyGroup(
            name: "Exit Group",
            target: .exit,
            domains: ["exit.example.org"],
            fullDomains: ["api.exit.example.org"],
            keywords: ["exitkw"],
            cidrs: ["203.0.113.0/24"]
        )

        let strictRules = try XCTUnwrap(makePlan(rejectOverseasUDP: true, policyGroups: [group]).routing()["rules"] as? [[String: Any]])
        XCTAssertTrue(strictRules.contains {
            ($0["domain"] as? [String]) == ["full:api.exit.example.org", "domain:exit.example.org", "exitkw"]
                && ($0["network"] as? String) == "tcp"
                && ($0["outboundTag"] as? String) == SplitExitPlan.Tag.exit
        })
        XCTAssertTrue(strictRules.contains {
            ($0["domain"] as? [String]) == ["full:api.exit.example.org", "domain:exit.example.org", "exitkw"]
                && ($0["network"] as? String) == "udp"
                && ($0["outboundTag"] as? String) == SplitExitPlan.Tag.reject
        })
        XCTAssertTrue(strictRules.contains {
            ($0["ip"] as? [String]) == ["203.0.113.0/24"]
                && ($0["network"] as? String) == "tcp"
                && ($0["outboundTag"] as? String) == SplitExitPlan.Tag.exit
        })
        XCTAssertTrue(strictRules.contains {
            ($0["ip"] as? [String]) == ["203.0.113.0/24"]
                && ($0["network"] as? String) == "udp"
                && ($0["outboundTag"] as? String) == SplitExitPlan.Tag.reject
        })

        let relaxedRules = try XCTUnwrap(makePlan(rejectOverseasUDP: false, policyGroups: [group]).routing()["rules"] as? [[String: Any]])
        XCTAssertTrue(relaxedRules.contains {
            ($0["domain"] as? [String]) == ["full:api.exit.example.org", "domain:exit.example.org", "exitkw"]
                && $0["network"] == nil
                && ($0["outboundTag"] as? String) == SplitExitPlan.Tag.exit
        })
        XCTAssertTrue(relaxedRules.contains {
            ($0["ip"] as? [String]) == ["203.0.113.0/24"]
                && $0["network"] == nil
                && ($0["outboundTag"] as? String) == SplitExitPlan.Tag.exit
        })
    }

    func testPolicyGroupDirectTargetRoutingAndDomesticDNS() throws {
        let directGroup = SplitExitPolicyGroup(
            name: "Direct Services",
            target: .direct,
            domains: ["direct.example.cn"],
            fullDomains: ["exact.direct.example.cn"],
            keywords: ["directkw"],
            geoSites: ["apple"],
            cidrs: ["198.51.100.10/32"]
        )
        let exitGroup = SplitExitPolicyGroup(
            name: "Exit Services",
            target: .exit,
            domains: ["exit-only.example.com"]
        )
        let plan = makePlan(policyGroups: [directGroup, exitGroup])
        let rules = try XCTUnwrap(plan.routing()["rules"] as? [[String: Any]])

        XCTAssertTrue(rules.contains {
            ($0["domain"] as? [String]) == ["full:exact.direct.example.cn", "domain:direct.example.cn", "directkw", "geosite:apple"]
                && ($0["outboundTag"] as? String) == SplitExitPlan.Tag.direct
        })
        XCTAssertTrue(rules.contains {
            ($0["ip"] as? [String]) == ["198.51.100.10/32"]
                && ($0["outboundTag"] as? String) == SplitExitPlan.Tag.direct
        })

        let servers = try XCTUnwrap(plan.dns()["servers"] as? [Any])
        XCTAssertEqual(servers.first as? String, "fakedns")
        let domestic = try XCTUnwrap(servers.dropFirst().first as? [String: Any])
        let domesticDomains = try XCTUnwrap(domestic["domains"] as? [String])
        XCTAssertTrue(domesticDomains.contains("full:exact.direct.example.cn"))
        XCTAssertTrue(domesticDomains.contains("domain:direct.example.cn"))
        XCTAssertTrue(domesticDomains.contains("directkw"))
        XCTAssertTrue(domesticDomains.contains("geosite:apple"))
        XCTAssertFalse(domesticDomains.contains("domain:exit-only.example.com"))
    }

    func testPolicyGroupRejectTargetBlocksDomainsAndCIDRs() throws {
        let rejectGroup = SplitExitPolicyGroup(
            name: "Blocklist",
            target: .reject,
            domains: ["tracker.example.com"],
            cidrs: ["192.0.2.0/24"]
        )
        let rules = try XCTUnwrap(makePlan(policyGroups: [rejectGroup]).routing()["rules"] as? [[String: Any]])
        XCTAssertTrue(rules.contains {
            ($0["domain"] as? [String]) == ["domain:tracker.example.com"]
                && ($0["outboundTag"] as? String) == SplitExitPlan.Tag.reject
        })
        XCTAssertTrue(rules.contains {
            ($0["ip"] as? [String]) == ["192.0.2.0/24"]
                && ($0["outboundTag"] as? String) == SplitExitPlan.Tag.reject
        })
    }

    func testDisabledAndEmptyPolicyGroupsAreOmitted() throws {
        let disabled = SplitExitPolicyGroup(
            name: "Disabled",
            target: .direct,
            domains: ["disabled.example.com"],
            isEnabled: false
        )
        let empty = SplitExitPolicyGroup(name: "Empty", target: .exit)
        let plan = makePlan(policyGroups: [disabled, empty])
        let json = try plan.composeJSON()
        XCTAssertFalse(json.contains("disabled.example.com"))

        let rules = try XCTUnwrap(plan.routing()["rules"] as? [[String: Any]])
        let directRules = rules.filter { $0["outboundTag"] as? String == SplitExitPlan.Tag.direct }
        XCTAssertEqual(directRules.count, 4)
    }

    func testPolicyGroupEmitsSeparateDomainAndIPRulesForORSemantics() throws {
        let mixed = SplitExitPolicyGroup(
            name: "Mixed",
            target: .direct,
            domains: ["mixed.example.cn"],
            cidrs: ["198.51.100.0/24"]
        )
        let rules = try XCTUnwrap(makePlan(policyGroups: [mixed]).routing()["rules"] as? [[String: Any]])
        for rule in rules {
            XCTAssertFalse(rule["domain"] != nil && rule["ip"] != nil && (rule["inboundTag"] == nil),
                           "policyGroup 规则不能把 domain 与 ip 混在同一条 dict 里（那会变成 AND 语义）")
        }
    }

    func testPolicyGroupFiltersUnsupportedGeoSiteAndInvalidCIDR() throws {
        let messy = SplitExitPolicyGroup(
            name: "Messy",
            target: .direct,
            domains: ["+.Clean.Example.CN.", "bad domain"],
            fullDomains: ["Host.Example.CN."],
            keywords: ["validkw", "has.dot", "bad kw"],
            geoSites: ["Apple", "geosite:google", "nonexistent-category-xyz", "!cn"],
            cidrs: ["198.51.100.1", "999.999.999.999/24", "not-a-cidr"]
        )
        let rules = try XCTUnwrap(makePlan(policyGroups: [messy]).routing()["rules"] as? [[String: Any]])
        let domainRule = try XCTUnwrap(rules.first {
            ($0["domain"] as? [String])?.contains("domain:clean.example.cn") == true
        })
        XCTAssertEqual(
            domainRule["domain"] as? [String],
            ["full:host.example.cn", "domain:clean.example.cn", "validkw", "geosite:apple", "geosite:google"]
        )
        let ipRule = try XCTUnwrap(rules.first {
            ($0["ip"] as? [String])?.contains("198.51.100.1/32") == true
        })
        XCTAssertEqual(ipRule["ip"] as? [String], ["198.51.100.1/32"])
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
        // 允许直连的只有：DNS 上游、局域网、国内域名、国内 IP（policyGroups 为空时共 4 条）
        XCTAssertEqual(directRules.count, 4, "多出来的直连规则意味着有流量绕过了海外出口")
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

    /// 名单里的关键字条目必须原样进 domain 数组（裸串 = 子串匹配），
    /// 加 `domain:` 前缀会变成"以 .wechat 结尾"，等于把这条规则丢掉。
    func testInjectedKeywordsAreBareStrings() throws {
        let lists = SplitExitPlan.Lists(cnDomainKeywords: ["wechat"])
        let rules = try XCTUnwrap(makePlan(lists: lists).routing()["rules"] as? [[String: Any]])
        let rule = try XCTUnwrap(rules.first { r in
            (r["domain"] as? [String])?.contains("geosite:cn") == true
        })
        let entries = try XCTUnwrap(rule["domain"] as? [String])
        XCTAssertTrue(entries.contains("wechat"))
        XCTAssertFalse(entries.contains("domain:wechat"))
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

    // MARK: - root 中继（断网开关）

    private func planWithRelay() -> SplitExitPlan {
        let exit = node("住宅", .socks5, host: "203.0.113.9", port: 1080,
                        password: "p@ss", params: ["username": "u"])
        let hop = node("HK-01", .trojan, host: "hk.example.com", port: 443, password: "pw")
        return SplitExitPlan(exitNode: exit, hopNode: hop,
                             relay: .init(port: 10808, username: "relayuser", password: "relaypass"))
    }

    /// 链路必须完整：exit → hop → relay，direct 也要经 relay。
    /// 少一环就意味着"某个出站还在用 uid 501 直连外网"，断网开关一开就被拦死。
    func testRelayChainCoversEveryEgress() throws {
        let outbounds = try planWithRelay().outbounds()
        XCTAssertEqual(outbounds.map { $0["tag"] as? String },
                       ["exit", "hop", "relay", "direct", "reject", "dns-out"])

        func dialerProxy(_ tag: String) throws -> String? {
            let ob = try XCTUnwrap(outbounds.first { $0["tag"] as? String == tag })
            let stream = ob["streamSettings"] as? [String: Any]
            let sockopt = stream?["sockopt"] as? [String: Any]
            return sockopt?["dialerProxy"] as? String
        }
        XCTAssertEqual(try dialerProxy("exit"), "hop", "住宅代理连跳板")
        XCTAssertEqual(try dialerProxy("hop"), "relay", "跳板的拨号也要经中继")
        XCTAssertEqual(try dialerProxy("direct"), "relay", "国内直连同样经中继")
        XCTAssertNil(try dialerProxy("relay"), "中继是最外层，不能再套")
    }

    func testRelayOutboundCarriesCredentialsAndLoopback() throws {
        let outbounds = try planWithRelay().outbounds()
        let relay = try XCTUnwrap(outbounds.first { $0["tag"] as? String == "relay" })
        XCTAssertEqual(relay["protocol"] as? String, "socks")
        let servers = try XCTUnwrap((relay["settings"] as? [String: Any])?["servers"] as? [[String: Any]])
        let server = try XCTUnwrap(servers.first)
        XCTAssertEqual(server["address"] as? String, "127.0.0.1")
        XCTAssertEqual(server["port"] as? Int, 10808)
        let users = try XCTUnwrap(server["users"] as? [[String: String]])
        XCTAssertEqual(users.first?["user"], "relayuser")
        XCTAssertEqual(users.first?["pass"], "relaypass")
    }

    /// 中继只做 TCP，国内 DNS 必须改成 TCP 查询，否则查询发不出去、国内域名全部解析失败。
    func testDomesticDNSSwitchesToTCPWhenRelayEnabled() throws {
        let dns = planWithRelay().dns()
        let servers = try XCTUnwrap(dns["servers"] as? [Any])
        let tcp = servers.compactMap { $0 as? [String: Any] }
            .compactMap { $0["address"] as? String }
            .filter { $0.hasPrefix("tcp://") }
        XCTAssertTrue(tcp.contains("tcp://223.5.5.5"), "实际：\(tcp)")

        // 路由规则仍要按纯 IP 匹配（不能把 tcp:// 前缀带进 ip 数组）
        let rules = try XCTUnwrap(planWithRelay().routing()["rules"] as? [[String: Any]])
        let first = try XCTUnwrap(rules.first)
        XCTAssertEqual(first["ip"] as? [String], ["223.5.5.5", "119.29.29.29"])
    }

    func testNoRelayKeepsEgressLocal() throws {
        let outbounds = try makePlan().outbounds()
        XCTAssertFalse(outbounds.contains { $0["tag"] as? String == "relay" })
        let direct = try XCTUnwrap(outbounds.first { $0["tag"] as? String == "direct" })
        let sockopt = (direct["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any]
        XCTAssertNil(sockopt?["dialerProxy"])
        XCTAssertEqual(sockopt?["domainStrategy"] as? String, "ForceIP")
    }

    /// 经中继时 direct 绝不能 ForceIP：ForceIP 会把域名解析成假 IP（fakedns），
    /// SOCKS5 CONNECT 带着假 IP → root 从物理网卡拨一个只存在于 TUN 里的地址
    /// → 包绕回 TUN 死循环。线上实测：30 个 CONNECT 全挂起、整机断网。
    func testRelayDirectMustNotForceIP() throws {
        let outbounds = try planWithRelay().outbounds()
        let direct = try XCTUnwrap(outbounds.first { $0["tag"] as? String == "direct" })
        let sockopt = try XCTUnwrap((direct["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any])
        XCTAssertEqual(sockopt["dialerProxy"] as? String, "relay")
        XCTAssertNil(sockopt["domainStrategy"], "ForceIP 会把假 IP 塞进 CONNECT，必须去掉")
        XCTAssertNil(sockopt["happyEyeballs"], "经过 SOCKS5 中继的拨号没有 Happy Eyeballs 的意义")
    }

    // MARK: - blockQUIC

    func testBlockQUICTrueEmitsUDP443RejectRule() throws {
        let exit = node("住宅", .socks5, host: "203.0.113.9", port: 1080, password: "p", params: ["username": "u"])
        let hop = node("HK-01", .trojan, host: "hk.example.com", port: 443, password: "pw")
        let plan = SplitExitPlan(exitNode: exit, hopNode: hop, blockQUIC: true)
        let rules = try XCTUnwrap(plan.routing()["rules"] as? [[String: Any]])
        XCTAssertTrue(rules.contains {
            ($0["network"] as? String) == "udp"
                && ($0["port"] as? Int) == 443
                && ($0["outboundTag"] as? String) == SplitExitPlan.Tag.reject
        })
    }

    func testBlockQUICFalseOmitsUDP443RejectRule() throws {
        let exit = node("住宅", .socks5, host: "203.0.113.9", port: 1080, password: "p", params: ["username": "u"])
        let hop = node("HK-01", .trojan, host: "hk.example.com", port: 443, password: "pw")
        let plan = SplitExitPlan(exitNode: exit, hopNode: hop, blockQUIC: false)
        let rules = try XCTUnwrap(plan.routing()["rules"] as? [[String: Any]])
        XCTAssertFalse(rules.contains {
            ($0["network"] as? String) == "udp"
                && ($0["port"] as? Int) == 443
                && ($0["outboundTag"] as? String) == SplitExitPlan.Tag.reject
        })
    }

    func testPolicyGroupRejectsLeadingOrDoubleDots() {
        let invalid = SplitExitPolicyGroup(
            name: "Bad Dots",
            target: .direct,
            domains: [".example.com", "a..b.com", "good.example.com"],
            fullDomains: [".sub.example.com", "x..y.com", "ok.example.com"]
        )
        let resolved = SplitExitPlan.resolvedEntries(for: invalid)
        XCTAssertEqual(resolved.domains, ["full:ok.example.com", "domain:good.example.com"])
    }

    func testSameHopAndExitIsRejectedCaseInsensitively() {
        let exit = node("住宅", .socks5, host: "Proxy.Example.COM", port: 1080, password: "p")
        let hop = node("跳板", .socks5, host: "proxy.example.com", port: 1080, password: "p")
        let plan = SplitExitPlan(exitNode: exit, hopNode: hop)
        XCTAssertThrowsError(try plan.compose()) { error in
            XCTAssertEqual(error as? SplitExitPlan.PlanError, .hopEqualsExit)
        }
    }

    func testFromPayloadBuildsValidAndRejectsInvalidPayloads() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let exit = node("住宅", .socks5, host: "203.0.113.9", port: 1080, password: "p", params: ["username": "u"])
        let hop = node("HK-01", .trojan, host: "hk.example.com", port: 443, password: "pw")
        let exitJSON = String(data: try encoder.encode(exit), encoding: .utf8)!
        let hopJSON = String(data: try encoder.encode(hop), encoding: .utf8)!
        let relay = GuardRelayCredentials(port: 10808, username: "fwd_u", password: "fwd_p")
        let groups = [SplitExitPolicyGroup(name: "Custom", target: .exit, domains: ["custom.example.com"])]
        let groupsJSON = String(data: try JSONEncoder().encode(groups), encoding: .utf8)!

        let plan = try SplitExitPlan.fromPayload(
            exitNodeJSON: exitJSON,
            hopNodeJSON: hopJSON,
            guardRelayJSON: relay.jsonString,
            policyGroupsJSON: groupsJSON,
            blockQUIC: false
        )
        XCTAssertFalse(plan.blockQUIC)
        XCTAssertEqual(plan.relay?.username, "fwd_u")
        XCTAssertEqual(plan.policyGroups.count, 1)
        let config = try plan.compose()
        let outbounds = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        XCTAssertTrue(outbounds.contains { $0["tag"] as? String == "relay" })

        // Case-insensitive hopEqualsExit via payload
        let hopUpper = node("Dup", .socks5, host: "EXAMPLE.COM", port: 1080, password: "p")
        let exitLower = node("Dup2", .socks5, host: "example.com", port: 1080, password: "p")
        let badPlan = try SplitExitPlan.fromPayload(
            exitNodeJSON: String(data: try encoder.encode(exitLower), encoding: .utf8)!,
            hopNodeJSON: String(data: try encoder.encode(hopUpper), encoding: .utf8)!
        )
        XCTAssertThrowsError(try badPlan.composeJSON(tunInterfaceName: "utun9")) { error in
            XCTAssertEqual(error as? SplitExitPlan.PlanError, .hopEqualsExit)
        }

        // Corrupt relay or policyGroups JSON fails explicitly
        XCTAssertThrowsError(try SplitExitPlan.fromPayload(
            exitNodeJSON: exitJSON,
            hopNodeJSON: hopJSON,
            guardRelayJSON: "{bad"
        ))
        XCTAssertThrowsError(try SplitExitPlan.fromPayload(
            exitNodeJSON: exitJSON,
            hopNodeJSON: hopJSON,
            policyGroupsJSON: "{bad"
        ))
    }
}
