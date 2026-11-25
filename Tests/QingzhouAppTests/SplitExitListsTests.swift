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

    /// Loyalsoldier 的 release 分支是 Clash **rule-provider** 格式：
    /// ```
    /// payload:
    ///   - '2mdn-cn.net'
    /// ```
    /// 不是 `DOMAIN-SUFFIX,xxx`。按后者解析会得到 0 条 —— 线上就踩过这个坑
    /// （设置页显示"解析结果为空"）。
    func testParsesClashRuleProviderFormat() {
        let text = """
        payload:
          - '2mdn-cn.net'
          - "a1.mzstatic.com"
          - bare.example.cn
          - 'singleword'
        """
        let parsed = SplitExitListParser.parseDomains(text)
        XCTAssertEqual(parsed.domains, ["2mdn-cn.net", "a1.mzstatic.com", "bare.example.cn"])
        XCTAssertEqual(parsed.keywords, ["singleword"])
    }

    func testParsesProviderFormatCIDRs() {
        let text = """
        payload:
          - '1.0.1.0/24'
          - '2400:3200::/32'
        """
        XCTAssertEqual(SplitExitListParser.parseCIDRs(text), ["1.0.1.0/24", "2400:3200::/32"])
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
            sources: sources(), store: store, geoSiteCNMatcher: .empty)
        let outcome = await updater.refresh()
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.lists?.domains.count, 2)
        XCTAssertEqual(outcome.lists?.cidrs.count, 2)
        XCTAssertFalse(outcome.usedCache)
        XCTAssertNotNil(store.stored?.fetchedAt)
    }

    /// 真实的 direct.txt 有 11 万条：必须按上限截断后再落盘，同时把源总数记下来，
    /// 否则要么顶爆 NE 内存、要么让用户以为全量都生效了。
    func testOversizedListIsTruncatedAndSourceCounted() async {
        let many = (0..<(SplitExitListsLimits.domains + 500))
            .map { "d\($0).example.org" }
            .joined(separator: "\n")
        let store = MemoryStore()
        let updater = SplitExitListsUpdater(
            client: StubClient(bodies: ["direct.txt": many, "cncidr.txt": cidrBody]),
            sources: sources(), store: store)
        let outcome = await updater.refresh()
        XCTAssertNil(outcome.error)
        XCTAssertEqual(store.stored?.domains.count, SplitExitListsLimits.domains)
        XCTAssertEqual(store.stored?.sourceDomainCount, SplitExitListsLimits.domains + 500)
        XCTAssertEqual(store.stored?.deduplicatedDomainCount, 0)
        // 等距抽样：必须覆盖到名单尾部，而不是只留前 3 万条
        let last = store.stored?.domains.last ?? ""
        let lastIndex = Int(last.dropFirst().prefix(while: { $0.isNumber })) ?? -1
        XCTAssertGreaterThan(lastIndex, SplitExitListsLimits.domains,
                             "抽样应覆盖到源名单尾部（实际最后一条：\(last)）")
    }

    func testDeduplicatesGeoSiteCNDomainsBeforeSampling() async {
        let nonCNCount = SplitExitListsLimits.domains - 10
        var lines = [
            "DOMAIN-SUFFIX,qq.com",
            "DOMAIN-SUFFIX,sub.baidu.com",
            "DOMAIN-SUFFIX,foo.cn",
            "DOMAIN,time.izatcloud.net",
            "DOMAIN,upos-sz-mihayo.akamaized.net",
        ]
        for i in 0..<nonCNCount {
            lines.append("DOMAIN-SUFFIX,custom\(i).example.org")
        }
        let store = MemoryStore()
        let updater = SplitExitListsUpdater(
            client: StubClient(bodies: ["direct.txt": lines.joined(separator: "\n"), "cncidr.txt": cidrBody]),
            sources: sources(), store: store
        )
        let outcome = await updater.refresh()
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.metrics?.rawDomainCount, 5 + nonCNCount)
        XCTAssertEqual(outcome.metrics?.deduplicatedByGeoSiteCNCount, 5)
        XCTAssertEqual(outcome.metrics?.postDeduplicationDomainCount, nonCNCount)
        XCTAssertEqual(outcome.metrics?.finalDomainCount, nonCNCount)
        XCTAssertEqual(outcome.lists?.deduplicatedDomainCount, 5)
        XCTAssertEqual(outcome.lists?.domains.count, nonCNCount)
        XCTAssertFalse(outcome.lists?.domains.contains("qq.com") == true)
        XCTAssertTrue(outcome.lists?.domains.contains("custom0.example.org") == true)
    }

    func testAllDomainsCoveredByGeoSiteCNDoesNotFailRefresh() async {
        let store = MemoryStore()
        let updater = SplitExitListsUpdater(
            client: StubClient(bodies: ["direct.txt": domainBody, "cncidr.txt": cidrBody]),
            sources: sources(), store: store
        )
        let outcome = await updater.refresh()
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.metrics?.rawDomainCount, 2)
        XCTAssertEqual(outcome.metrics?.deduplicatedByGeoSiteCNCount, 2)
        XCTAssertEqual(outcome.metrics?.postDeduplicationDomainCount, 0)
        XCTAssertEqual(outcome.metrics?.finalDomainCount, 0)
        XCTAssertEqual(outcome.lists?.domains, [])
        XCTAssertEqual(outcome.lists?.deduplicatedDomainCount, 2)
        XCTAssertEqual(outcome.lists?.cidrs.count, 2)
    }

    func testSplitExitListsBackwardCompatDecodingWithoutDeduplicatedCount() throws {
        let legacyJSON = """
        {
          "domains": ["custom.example.org"],
          "domainKeywords": [],
          "cidrs": ["1.0.1.0/24"],
          "sourceDomainCount": 1,
          "sourceCIDRCount": 1,
          "sources": ["https://example.com/direct.txt"]
        }
        """
        let decoded = try XCTUnwrap(SplitExitListsFile.decode(Data(legacyJSON.utf8)))
        XCTAssertEqual(decoded.domains, ["custom.example.org"])
        XCTAssertEqual(decoded.deduplicatedDomainCount, 0)
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

    func testSamplerSpreadsAcrossWholeList() {
        let items = (0..<1000).map { $0 }
        let sampled = SplitExitListSampler.sample(items, limit: 100)
        XCTAssertEqual(sampled.count, 100)
        XCTAssertEqual(sampled.first, 0)
        XCTAssertEqual(sampled.last, 990)          // 覆盖到尾部，而不是前 100 个
        XCTAssertEqual(Set(sampled).count, 100)    // 无重复
        XCTAssertTrue(zip(sampled, sampled.dropFirst()).allSatisfy { $0 < $1 })
    }

    func testSamplerLeavesSmallListUntouched() {
        let items = [1, 2, 3]
        XCTAssertEqual(SplitExitListSampler.sample(items, limit: 100), items)
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

/// 用真实名单文件跑一遍解析（默认跳过，避免 CI 依赖网络）。
/// 手动验证：`QZ_REAL_LISTS=/tmp sh -c 'cd <repo> && swift test --filter RealList'`，
/// 目录里放好 d.txt（direct.txt）与 c.txt（cncidr.txt）。
final class RealListParsingTests: XCTestCase {
    func testParsesRealDirectAndCIDRFiles() throws {
        guard let dir = ProcessInfo.processInfo.environment["QZ_REAL_LISTS"] else {
            throw XCTSkip("未设置 QZ_REAL_LISTS")
        }
        let dPath = dir + "/d.txt", cPath = dir + "/c.txt"
        guard FileManager.default.fileExists(atPath: dPath),
              FileManager.default.fileExists(atPath: cPath) else {
            throw XCTSkip("样例文件不存在")
        }
        let dText = try String(contentsOfFile: dPath, encoding: .utf8)
        let cText = try String(contentsOfFile: cPath, encoding: .utf8)

        let parsed = SplitExitListParser.parseDomains(dText)
        let cidrs = SplitExitListParser.parseCIDRs(cText)
        // 量级断言（真实文件是 11 万 / 9.6 千），只要不是 0 就说明格式认对了
        XCTAssertGreaterThan(parsed.domains.count, 50_000, "direct.txt 应解析出数万条")
        XCTAssertGreaterThan(cidrs.count, 3_000, "cncidr.txt 应解析出数千条")
        XCTAssertEqual(parsed.keywords.count, 0, "真实文件里的单标签条目都带 +. 前缀，应归到域名而非关键字")
        print("real: domains=\(parsed.domains.count) keywords=\(parsed.keywords.count) cidrs=\(cidrs.count)")
    }
}
