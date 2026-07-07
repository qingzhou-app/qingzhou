import XCTest
@testable import QingzhouCore

/// ProxiedProbePlanner：把固定的经代理探测目标（Cloudflare）换成「用户真实走代理、
/// 连接数最高的 Top-N registrable domain」，每轮从 Top-3 里轮换取一个。
/// 数据不足（走代理域名 < 3）回退固定目标（返回 nil）。
final class ProxiedProbePlannerTests: XCTestCase {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func conn(_ host: String, route: String, at: Date? = nil) -> Connection {
        Connection(targetHost: host, sourceAddress: "127.0.0.1:1",
                   targetAddress: "\(host):443", type: .https, route: route,
                   matchedRule: "", openedAt: at ?? now)
    }

    /// 造一份历史：每个 (host, route) 记 count 次连接。
    private func history(_ entries: [(host: String, route: String, count: Int)]) -> DomainDailyHistory {
        var h = DomainDailyHistory()
        var conns: [Connection] = []
        for e in entries {
            for _ in 0..<e.count { conns.append(conn(e.host, route: e.route)) }
        }
        h.record(conns, calendar: cal)
        return h
    }

    // MARK: - Top 域名选取

    func testTopProxiedDomainsSortedByProxyCountDescending() {
        let h = history([
            ("www.youtube.com", "PROXY", 5),
            ("api.github.com", "PROXY", 9),
            ("www.google.com", "PROXY", 7),
        ])
        // 按主域名聚合、proxyCount 降序
        XCTAssertEqual(ProxiedProbePlanner.topProxiedDomains(from: h),
                       ["github.com", "google.com", "youtube.com"])
    }

    func testTopProxiedDomainsAggregatesSubdomainsToRegistrable() {
        let h = history([
            ("www.youtube.com", "PROXY", 3),
            ("m.youtube.com", "PROXY", 4),   // 同主域名合并 → youtube.com 共 7
            ("api.github.com", "PROXY", 5),
        ])
        XCTAssertEqual(ProxiedProbePlanner.topProxiedDomains(from: h, limit: 1), ["youtube.com"])
    }

    func testTopProxiedDomainsExcludesDirectOnlyDomains() {
        let h = history([
            ("a.com", "PROXY", 10),
            ("b.com", "DIRECT", 99),   // 只走直连 → proxyCount 0，不算探测目标
            ("c.com", "PROXY", 3),
        ])
        XCTAssertEqual(ProxiedProbePlanner.topProxiedDomains(from: h), ["a.com", "c.com"])
    }

    func testTopProxiedDomainsExcludesBareIPs() {
        let h = history([
            ("1.2.3.4", "PROXY", 50),      // 裸 IP：没有聚合价值，剔除
            ("example.com", "PROXY", 4),
            ("[2001:db8::1]", "PROXY", 30),
        ])
        XCTAssertEqual(ProxiedProbePlanner.topProxiedDomains(from: h), ["example.com"])
    }

    func testTopProxiedDomainsTieBreaksByDomainAscending() {
        let h = history([
            ("bbb.com", "PROXY", 4),
            ("aaa.com", "PROXY", 4),
            ("ccc.com", "PROXY", 4),
        ])
        // 同 proxyCount：域名字典序升序，选择确定
        XCTAssertEqual(ProxiedProbePlanner.topProxiedDomains(from: h),
                       ["aaa.com", "bbb.com", "ccc.com"])
    }

    // MARK: - 探测 URL 形态

    func testProbeURLTargetsDomainRoot() {
        XCTAssertEqual(ProxiedProbePlanner.probeURL(for: "youtube.com"), "https://youtube.com/")
    }

    // MARK: - 每轮探测目标（轮换 + 回退）

    func testProbeTargetFallsBackWhenTooFewProxyDomains() {
        // 只有 2 个走代理域名（< minProxiedDomains=3）→ nil（回退固定目标）
        let h = history([("a.com", "PROXY", 5), ("b.com", "PROXY", 3)])
        XCTAssertNil(ProxiedProbePlanner.probeTarget(from: h, roundIndex: 0))
        XCTAssertNil(ProxiedProbePlanner.probeTarget(from: h, roundIndex: 7))
    }

    func testProbeTargetRotatesThroughTopThree() {
        let h = history([
            ("first.com", "PROXY", 30),
            ("second.com", "PROXY", 20),
            ("third.com", "PROXY", 10),
        ])
        // 每轮取一个，round-robin 覆盖 Top-3（降序：first→second→third）
        XCTAssertEqual(ProxiedProbePlanner.probeTarget(from: h, roundIndex: 0), "https://first.com/")
        XCTAssertEqual(ProxiedProbePlanner.probeTarget(from: h, roundIndex: 1), "https://second.com/")
        XCTAssertEqual(ProxiedProbePlanner.probeTarget(from: h, roundIndex: 2), "https://third.com/")
        // 第 4 轮回到第一个
        XCTAssertEqual(ProxiedProbePlanner.probeTarget(from: h, roundIndex: 3), "https://first.com/")
    }

    func testProbeTargetExactlyThreeDomainsEnablesRotation() {
        // 恰好 3 个走代理域名 = 边界，启用画像探测
        let h = history([("a.com", "PROXY", 3), ("b.com", "PROXY", 2), ("c.com", "PROXY", 1)])
        XCTAssertNotNil(ProxiedProbePlanner.probeTarget(from: h, roundIndex: 0))
    }

    func testProbeTargetNegativeRoundIndexIsSafe() {
        let h = history([
            ("first.com", "PROXY", 30),
            ("second.com", "PROXY", 20),
            ("third.com", "PROXY", 10),
        ])
        // 负 roundIndex（不该发生，防御性）不越界崩溃，落在合法域名上
        let t = ProxiedProbePlanner.probeTarget(from: h, roundIndex: -1)
        XCTAssertNotNil(t)
        XCTAssertTrue(["https://first.com/", "https://second.com/", "https://third.com/"].contains(t))
    }

    func testProbeTargetEmptyHistoryFallsBack() {
        XCTAssertNil(ProxiedProbePlanner.probeTarget(from: DomainDailyHistory(), roundIndex: 0))
    }
}
