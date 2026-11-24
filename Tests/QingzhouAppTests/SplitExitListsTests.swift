import XCTest
import QingzhouCore
import QingzhouSubscription
@testable import QingzhouApp

/// 名单解析 + 更新容错。
///
/// 这里的重点不是"能解析"，而是**失败时不能把好的名单弄坏**：
/// 名单是分流的基础数据，一次空响应或一份 HTML 错误页覆盖掉旧名单，
/// 用户就会在不知情的情况下把国内流量送进海外出口。
final class SplitExitListsTests: XCTestCase {

    // MARK: - 解析

    func testParsesClashStyleDomainList() {
        let text = """
        # comment
        DOMAIN-SUFFIX,qq.com
        DOMAIN,example.cn
        DOMAIN-KEYWORD,wechat
        DOMAIN-SUFFIX,QQ.COM
        *.wildcard.cn
        bad entry with space
        https://not-a-domain
        """
        let parsed = SplitExitListParser.parseDomains(text)
        XCTAssertEqual(parsed.domains, ["qq.com", "example.cn", "wildcard.cn"])
        // 不含点的条目按关键字保留：加 domain: 前缀会变成"以 .wechat 结尾"，等于丢掉
        XCTAssertEqual(parsed.keywords, ["wechat"])
    }

    func testParsesCIDRList() {
        let text = """
        IP-CIDR,1.0.1.0/24,no-resolve
        IP-CIDR6,2400:3200::/32
        10.0.0.0/8
        1.2.3.4
        not-an-ip
        IP-CIDR,1.0.1.0/24
        """
        let cidrs = SplitExitListParser.parseCIDRs(text)
        XCTAssertEqual(cidrs, ["1.0.1.0/24", "2400:3200::/32", "10.0.0.0/8", "1.2.3.4/32"])
    }

    func testRejectsInvalidPrefixLength() {
        XCTAssertTrue(SplitExitListParser.parseCIDRs("IP-CIDR,1.2.3.4/99").isEmpty)
        XCTAssertTrue(SplitExitListParser.parseCIDRs("IP-CIDR,1.2.3.4/abc").isEmpty)
    }

    func testIgnoresInlineComment() {
        let parsed = SplitExitListParser.parseDomains("DOMAIN-SUFFIX,qq.com # 腾讯")
        XCTAssertEqual(parsed.domains, ["qq.com"])
    }

    // MARK: - 更新容错

    private struct StubClient: HTTPClient, Sendable {
        var bodies: [String: String]      // 按 URL 最后一段匹配
        var failing: Set<String> = []
        func get(_ url: URL) async throws -> (Data, [String: String]) {
            let key = url.lastPathComponent
            if failing.contains(key) { throw URLError(.timedOut) }
            let body = bodies[key] ?? ""
            return (Data(body.utf8), [:])
        }
        func get(_ url: URL, userAgent: String) async throws -> (Data, [String: String]) {
            try await get(url)
        }
    }

    private final class MemoryStore: SplitExitListsStore, @unchecked Sendable {
        var stored: SplitExitLists?
        init(_ initial: SplitExitLists? = nil) { stored = initial }
        func load() -> SplitExitLists? { stored }
        func save(_ lists: SplitExitLists) throws { stored = lists }
    }

    private let domainBody = """
    DOMAIN-SUFFIX,qq.com
    DOMAIN-SUFFIX,baidu.com
    """
    private let cidrBody = """
    IP-CIDR,1.0.1.0/24
    IP-CIDR,223.5.5.0/24
    """

    private func sources() -> [URL] {
        [URL(string: "https://example.com/direct.txt")!,
         URL(string: "https://example.com/cncidr.txt")!]
    }

    func testSuccessfulRefreshWritesBothLists() async {
        let store = MemoryStore()
        let updater = SplitExitListsUpdater(
            client: StubClient(bodies: ["direct.txt": domainBody, "cncidr.txt": cidrBody]),
            sources: sources(), store: store)
        let outcome = await updater.refresh()
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.lists?.domains.count, 2)
        XCTAssertEqual(outcome.lists?.cidrs.count, 2)
        XCTAssertFalse(outcome.usedCache)
        XCTAssertNotNil(store.stored?.fetchedAt)
    }

    /// 一份拉失败 → 整份不更新，旧名单原样保留。
    func testPartialFailureKeepsPreviousLists() async {
        let old = SplitExitLists(domains: ["old.cn"], cidrs: ["9.9.9.0/24"], fetchedAt: Date(), sources: [])
        let store = MemoryStore(old)
        let updater = SplitExitListsUpdater(
            client: StubClient(bodies: ["direct.txt": domainBody], failing: ["cncidr.txt"]),
            sources: sources(), store: store)
        let outcome = await updater.refresh()
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(outcome.lists?.domains, ["old.cn"], "失败时必须是旧名单")
        XCTAssertEqual(store.stored?.domains, ["old.cn"], "磁盘上也不能被覆盖")
    }

    /// 拿到 200 但内容是错误页（解析出 0 条）→ 同样不覆盖。
    func testEmptyParseKeepsPreviousLists() async {
        let old = SplitExitLists(domains: ["old.cn"], cidrs: ["9.9.9.0/24"], fetchedAt: Date(), sources: [])
        let store = MemoryStore(old)
        let updater = SplitExitListsUpdater(
            client: StubClient(bodies: ["direct.txt": "<html>rate limited</html>", "cncidr.txt": cidrBody]),
            sources: sources(), store: store)
        let outcome = await updater.refresh()
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(store.stored?.domains, ["old.cn"])
    }

    /// 缓存新鲜且 force=false → 不打网络（client 里没有对应 body，若打网络会得到空并失败）。
    func testFreshCacheShortCircuits() async {
        let fresh = SplitExitLists(domains: ["a.cn"], cidrs: ["1.0.0.0/24"], fetchedAt: Date(), sources: [])
        let store = MemoryStore(fresh)
        let updater = SplitExitListsUpdater(
            client: StubClient(bodies: [:]), sources: sources(), store: store)
        let outcome = await updater.refresh(force: false)
        XCTAssertNil(outcome.error)
        XCTAssertTrue(outcome.usedCache)
        XCTAssertEqual(outcome.lists?.domains, ["a.cn"])
    }

    func testStaleThreshold() {
        let fresh = SplitExitLists(domains: ["a"], cidrs: ["b"], fetchedAt: Date(), sources: [])
        XCTAssertFalse(SplitExitListsUpdater.isStale(fresh))
        let old = SplitExitLists(domains: ["a"], cidrs: ["b"],
                                 fetchedAt: Date().addingTimeInterval(-25 * 3600), sources: [])
        XCTAssertTrue(SplitExitListsUpdater.isStale(old))
        XCTAssertTrue(SplitExitListsUpdater.isStale(nil))
    }
}
