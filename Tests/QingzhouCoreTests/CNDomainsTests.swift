import XCTest
@testable import QingzhouCore

/// CN 域名归属判定：内置资源表（geosite:cn 高频子集）+ 中国 TLD 规则。
final class CNDomainsTests: XCTestCase {

    // MARK: - TLD 规则

    func testCNTLDIsAlwaysCN() {
        XCTAssertTrue(CNDomains.isLikelyCN("example.cn"))
        XCTAssertTrue(CNDomains.isLikelyCN("news.sina.com.cn"))
        XCTAssertTrue(CNDomains.isLikelyCN("gov.cn"))
    }

    func testChineseIDNTLDs() {
        // .中国 / .中國 的 punycode
        XCTAssertTrue(CNDomains.isLikelyCN("example.xn--fiqs8s"))
        XCTAssertTrue(CNDomains.isLikelyCN("example.xn--fiqz9s"))
    }

    // MARK: - 资源表判定

    func testWellKnownCNDomainsMatch() {
        // 注意别拿 aliyuncs.com 当样例 —— 上游已把它移出 geosite:cn（国际区域不算 CN）
        for d in ["baidu.com", "qq.com", "taobao.com", "bilibili.com",
                  "zhihu.com", "douyin.com", "meituan.com", "aliyun.com"] {
            XCTAssertTrue(CNDomains.isLikelyCN(d), "\(d) 应判为 CN")
        }
    }

    func testSubdomainsMatchBySuffix() {
        XCTAssertTrue(CNDomains.isLikelyCN("www.baidu.com"))
        XCTAssertTrue(CNDomains.isLikelyCN("upos-sz-mirror.bilivideo.com"))
    }

    func testForeignDomainsDoNotMatch() {
        for d in ["google.com", "youtube.com", "github.com", "cloudflare.com",
                  "wikipedia.org", "netflix.com"] {
            XCTAssertFalse(CNDomains.isLikelyCN(d), "\(d) 不应判为 CN")
        }
    }

    func testIPAndJunkAreNotCN() {
        XCTAssertFalse(CNDomains.isLikelyCN("114.114.114.114"))
        XCTAssertFalse(CNDomains.isLikelyCN("[2001:db8::1]"))
        XCTAssertFalse(CNDomains.isLikelyCN(""))
        XCTAssertFalse(CNDomains.isLikelyCN("localhost"))
    }

    func testCaseAndTrailingDotInsensitive() {
        XCTAssertTrue(CNDomains.isLikelyCN("WWW.BAIDU.COM"))
        XCTAssertTrue(CNDomains.isLikelyCN("baidu.com."))
    }

    // MARK: - 资源表本身的卫生检查

    func testSuffixTableLoadedAndSane() {
        XCTAssertGreaterThanOrEqual(CNDomains.suffixes.count, 200, "精简表也应有几百条")
        XCTAssertLessThanOrEqual(CNDomains.suffixes.count, 2000, "规模要控制住（资源 <100KB）")
        for s in CNDomains.suffixes {
            XCTAssertEqual(s, s.lowercased(), "表内条目必须全小写：\(s)")
            XCTAssertTrue(s.contains("."), "表内条目应为带点域名：\(s)")
            XCTAssertFalse(s.hasPrefix("."), "不带前导点：\(s)")
            XCTAssertFalse(s.hasSuffix(".cn"), ".cn 结尾的条目冗余（TLD 规则已覆盖）：\(s)")
        }
    }

    // MARK: - 与 DomainAnalyzer 建议联动

    func testSuggestionsUseExpandedTable() {
        // zhihu.com 不在旧的 12 域名硬编码里；新表应能识别 → 走代理时建议直连
        let stat = DomainStat(
            domain: "zhihu.com", connectionCount: 3, uploadBytes: 0, downloadBytes: 0,
            route: .proxy, lastMatchedRule: "", firstSeen: .init(), lastSeen: .init()
        )
        let suggestions = DomainAnalyzer.suggestions([stat])
        XCTAssertEqual(suggestions.first?.kind, .shouldDirect)
    }
}
