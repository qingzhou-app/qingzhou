import XCTest
@testable import QingzhouCore

/// DomainAnalyzer.aggregateByApp：按来源 App 聚合（macOS 域名分析「应用」视角的数据层）。
final class DomainAnalyzerAppTests: XCTestCase {

    private func conn(_ host: String, app: String?, route: String = "DIRECT") -> Connection {
        Connection(
            sourceApp: app,
            targetHost: host,
            sourceAddress: "192.168.1.2:50000",
            targetAddress: "\(host):443",
            type: .https,
            route: route,
            matchedRule: ""
        )
    }

    func testGroupsByAppAndCountsConnections() {
        let stats = DomainAnalyzer.aggregateByApp([
            conn("a.com", app: "com.apple.Safari"),
            conn("b.com", app: "com.apple.Safari"),
            conn("a.com", app: "com.google.Chrome"),
        ])
        XCTAssertEqual(stats.count, 2)
        let safari = stats.first { $0.bundleID == "com.apple.Safari" }
        XCTAssertEqual(safari?.connectionCount, 2)
        XCTAssertEqual(stats.first { $0.bundleID == "com.google.Chrome" }?.connectionCount, 1)
    }

    func testSortedByCountDescKnownAppsFirstUnknownLast() {
        // 未知来源（sourceApp=nil）哪怕连接最多也排最后 —— 它是「启用过滤前 / 系统流量」
        // 的杂项桶，不该压过真实 App
        let stats = DomainAnalyzer.aggregateByApp([
            conn("x.com", app: nil), conn("y.com", app: nil), conn("z.com", app: nil),
            conn("a.com", app: "com.apple.Safari"),
            conn("b.com", app: "com.google.Chrome"),
            conn("c.com", app: "com.google.Chrome"),
        ])
        XCTAssertEqual(stats.map(\.bundleID), ["com.google.Chrome", "com.apple.Safari", nil])
        XCTAssertEqual(stats.last?.connectionCount, 3)
    }

    func testTopDomainsAggregatedByRegistrableDomainAndLimited() {
        var conns: [Connection] = []
        // Safari：youtube.com 3 次（含子域名归并）、a.com 2 次、b.com / c.com 各 1 次
        conns.append(conn("www.youtube.com", app: "com.apple.Safari"))
        conns.append(conn("m.youtube.com", app: "com.apple.Safari"))
        conns.append(conn("youtube.com", app: "com.apple.Safari"))
        conns.append(conn("a.com", app: "com.apple.Safari"))
        conns.append(conn("a.com", app: "com.apple.Safari"))
        conns.append(conn("b.com", app: "com.apple.Safari"))
        conns.append(conn("c.com", app: "com.apple.Safari"))

        let stats = DomainAnalyzer.aggregateByApp(conns, topDomains: 3)
        XCTAssertEqual(stats.count, 1)
        let safari = stats[0]
        XCTAssertEqual(safari.connectionCount, 7)
        XCTAssertEqual(safari.domains.count, 3, "只保留 top N 域名")
        XCTAssertEqual(safari.domains[0].domain, "youtube.com")
        XCTAssertEqual(safari.domains[0].connectionCount, 3)
        XCTAssertEqual(safari.domains[1].domain, "a.com")
        XCTAssertEqual(safari.totalDomainCount, 4, "被截断的域名总数要另行给出，UI 好说明")
    }

    func testEmptyInputGivesEmptyOutput() {
        XCTAssertTrue(DomainAnalyzer.aggregateByApp([]).isEmpty)
    }
}
