import XCTest
@testable import QingzhouCore

final class GeoSiteCNMatcherTests: XCTestCase {

    func testBundledMatcherLoadsAllEntries() {
        let matcher = GeoSiteCNMatcher.bundled
        XCTAssertGreaterThanOrEqual(matcher.rootDomains.count, 5000)
        XCTAssertGreaterThanOrEqual(matcher.fullDomains.count, 30)
        XCTAssertGreaterThanOrEqual(matcher.regexPatterns.count, 3)
        XCTAssertEqual(
            matcher.entryCount,
            matcher.rootDomains.count + matcher.fullDomains.count + matcher.regexPatterns.count
        )
    }

    func testRootDomainMatchesExactAndSubdomainsOnly() {
        let matcher = GeoSiteCNMatcher.bundled
        XCTAssertTrue(matcher.isCovered("baidu.com"))
        XCTAssertTrue(matcher.isCovered("www.baidu.com"))
        XCTAssertTrue(matcher.isCovered("a.b.baidu.com"))
        XCTAssertFalse(matcher.isCovered("notbaidu.com"))
        XCTAssertFalse(matcher.isCovered("baidu.org"))
    }

    func testSingleLabelRootDomainTLDsMatch() {
        let matcher = GeoSiteCNMatcher.bundled
        XCTAssertTrue(matcher.isCovered("cn"))
        XCTAssertTrue(matcher.isCovered("example.cn"))
        XCTAssertTrue(matcher.isCovered("a.b.com.cn"))
        XCTAssertTrue(matcher.isCovered("foo.alibaba"))
        XCTAssertTrue(matcher.isCovered("shop.taobao"))
        XCTAssertTrue(matcher.isCovered("test.xn--fiqs8s"))
        XCTAssertFalse(matcher.isCovered("fakecn"))
        XCTAssertFalse(matcher.isCovered("example.com"))
    }

    func testFullDomainMatchesExactOnly() {
        let matcher = GeoSiteCNMatcher.bundled
        // time.izatcloud.net is in Full (and NOT under any RootDomain)
        XCTAssertTrue(matcher.isCovered("time.izatcloud.net"))
        XCTAssertFalse(matcher.isCovered("sub.time.izatcloud.net"))
        XCTAssertFalse(matcher.isCovered("izatcloud.net"))
    }

    func testRegexRulesMatchAndRejectNonMatches() {
        let matcher = GeoSiteCNMatcher.bundled
        XCTAssertTrue(matcher.isCovered("ns-01.awsdns-cn-12.com"))
        XCTAssertTrue(matcher.isCovered("x.awsdns-cn-0a.cn"))
        XCTAssertTrue(matcher.isCovered("upos-sz-mihayo.akamaized.net"))
        XCTAssertFalse(matcher.isCovered("awsdns-cn-12.com"))
        XCTAssertFalse(matcher.isCovered("upos-sz-mirrorakam.akamaized.net"))
    }

    func testNormalizationAndInvalidInputs() {
        let matcher = GeoSiteCNMatcher.bundled
        XCTAssertTrue(matcher.isCovered("  WWW.BAIDU.COM.  "))
        XCTAssertTrue(matcher.isCovered("+.baidu.com"))
        XCTAssertTrue(matcher.isCovered("*.qq.com"))
        XCTAssertTrue(matcher.isCovered("+.cn"))
        XCTAssertFalse(matcher.isCovered(""))
        XCTAssertFalse(matcher.isCovered("   "))
        XCTAssertFalse(matcher.isCovered("1.2.3.4"))
        XCTAssertFalse(matcher.isCovered("127.0.0.1"))
        XCTAssertFalse(matcher.isCovered("2400:3200::1"))
        XCTAssertFalse(matcher.isCovered("baidu.com:443"))
        XCTAssertFalse(matcher.isCovered("bad domain.cn"))
        XCTAssertFalse(matcher.isCovered("a..baidu.com"))
    }

    func test110kDomainBatchPerformanceAndThreadSafety() async {
        let matcher = GeoSiteCNMatcher.bundled
        let inputs = (0..<110_000).map { i in
            switch i % 4 {
            case 0: return "host\(i).baidu.com"
            case 1: return "sub\(i).example.cn"
            case 2: return "item\(i).custom-overseas.example.org"
            default: return "node\(i).taobao.com"
            }
        }
        let chunkCount = 4
        let chunkSize = inputs.count / chunkCount
        let coveredTotal = await withTaskGroup(of: Int.self) { group in
            for c in 0..<chunkCount {
                let slice = Array(inputs[(c * chunkSize)..<((c + 1) * chunkSize)])
                group.addTask {
                    var count = 0
                    for host in slice where matcher.isCovered(host) {
                        count += 1
                    }
                    return count
                }
            }
            var total = 0
            for await partial in group { total += partial }
            return total
        }
        // 3 out of every 4 are covered (baidu.com, .cn, taobao.com)
        XCTAssertEqual(coveredTotal, (110_000 / 4) * 3)
    }
}
