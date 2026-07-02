import XCTest
import QingzhouCore
@testable import QingzhouApp

/// DomainStatsCSV：域名分析导出的 CSV 渲染（域名/路由/次数/规则/首见/末见）。
final class DomainStatsCSVTests: XCTestCase {

    private func stat(_ domain: String, count: Int = 1, route: DomainRoute = .proxy,
                      rule: String = "") -> DomainStat {
        DomainStat(domain: domain, connectionCount: count, uploadBytes: 0, downloadBytes: 0,
                   route: route, lastMatchedRule: rule,
                   firstSeen: Date(timeIntervalSince1970: 1_750_000_000),
                   lastSeen: Date(timeIntervalSince1970: 1_750_003_600))
    }

    func testHeaderAndRowCount() {
        let csv = DomainStatsCSV.render([stat("a.com"), stat("b.com")])
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("域名,路由,连接次数,命中规则,首次出现,最近出现"),
                      "首行是表头（前缀可能带 BOM）")
    }

    func testStartsWithBOMForExcel() {
        // Excel 打开无 BOM 的 UTF-8 CSV 中文会乱码
        XCTAssertTrue(DomainStatsCSV.render([]).hasPrefix("\u{FEFF}"))
    }

    func testRouteLocalizedAndFieldsInOrder() {
        let csv = DomainStatsCSV.render([stat("a.com", count: 5, route: .direct,
                                              rule: "DOMAIN-SUFFIX,a.com,DIRECT")])
        let row = csv.split(separator: "\n").map(String.init)[1]
        let fields = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(fields[0], "a.com")
        XCTAssertEqual(fields[1], "直连")
        XCTAssertEqual(fields[2], "5")
        // 规则含逗号 → 整字段加引号（在 fields[3] 起始）
        XCTAssertTrue(row.contains("\"DOMAIN-SUFFIX,a.com,DIRECT\""))
    }

    func testEscapingQuotesAndCommas() {
        let csv = DomainStatsCSV.render([stat("a.com", rule: #"say "hi", ok"#)])
        XCTAssertTrue(csv.contains(#""say ""hi"", ok""#), "内嵌引号翻倍、含逗号字段整体加引号")
    }

    func testUnmatchedRuleExportedAsSentinelText() {
        let csv = DomainStatsCSV.render([stat("a.com", rule: "")])
        XCTAssertTrue(csv.contains("未命中（默认策略）"), "空规则导出成可读哨兵文本，不导出空串")
    }

    func testSuggestedFileName() {
        let name = DomainStatsCSV.suggestedFileName(now: Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertTrue(name.hasPrefix("Qingzhou-domains-"))
        XCTAssertTrue(name.hasSuffix(".csv"))
    }
}
