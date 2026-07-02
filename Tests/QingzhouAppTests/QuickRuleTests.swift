import XCTest
import QingzhouCore
import QingzhouLogging
@testable import QingzhouApp

/// 「一键规则」（域名分析 / 连接页的 加入直连/代理/拒绝）的生成与去重逻辑。
@MainActor
final class QuickRuleTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quick-rule-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    private func makeState() -> AppState {
        AppState(
            logger: Logger(capacity: 100, minimumLevel: .debug),
            persistence: Persistence(directory: tmpDir)
        )
    }

    func testAddCreatesDomainSuffixRuleWithRegistrableDomain() {
        let state = makeState()
        // 子域名要归并成主域名再生成规则
        let outcome = state.quickAddDomainRule(forHost: "www.youtube.com", target: .proxy)
        XCTAssertEqual(outcome, .added(domain: "youtube.com"))
        XCTAssertEqual(state.customRules.count, 1)
        let rule = state.customRules[0]
        XCTAssertEqual(rule.type, .domainSuffix)
        XCTAssertEqual(rule.value, "youtube.com")
        XCTAssertEqual(rule.target, .proxy)
        XCTAssertNotNil(state.toast, "添加后应有 toast 反馈")
    }

    func testTwoLevelPublicSuffixKeepsThreeLabels() {
        let state = makeState()
        let outcome = state.quickAddDomainRule(forHost: "news.sina.com.cn", target: .direct)
        XCTAssertEqual(outcome, .added(domain: "sina.com.cn"))
        XCTAssertEqual(state.customRules.first?.value, "sina.com.cn")
    }

    func testSameDomainSameTargetIsUnchangedNotDuplicated() {
        let state = makeState()
        state.quickAddDomainRule(forHost: "youtube.com", target: .proxy)
        // 换个子域名再来一次，registrable domain 相同 + target 相同 → 不重复添加
        let outcome = state.quickAddDomainRule(forHost: "m.youtube.com", target: .proxy)
        XCTAssertEqual(outcome, .unchanged(domain: "youtube.com"))
        XCTAssertEqual(state.customRules.count, 1)
    }

    func testSameDomainDifferentTargetRetargetsInPlace() {
        let state = makeState()
        state.quickAddDomainRule(forHost: "example.com", target: .direct)
        let ruleID = state.customRules[0].id
        let outcome = state.quickAddDomainRule(forHost: "example.com", target: .reject)
        XCTAssertEqual(outcome, .retargeted(domain: "example.com", from: .direct, to: .reject))
        XCTAssertEqual(state.customRules.count, 1, "改目标应替换原规则，不新增")
        XCTAssertEqual(state.customRules[0].id, ruleID, "原地改目标，保持规则身份")
        XCTAssertEqual(state.customRules[0].target, .reject)
    }

    func testExistingPlainDomainRuleAlsoCountsAsSameDomain() {
        let state = makeState()
        // 用户手工加过 DOMAIN,example.com,DIRECT —— 一键改目标时不重复加一条 SUFFIX
        state.addCustomRule(Rule(type: .domain, value: "example.com", target: .direct))
        let outcome = state.quickAddDomainRule(forHost: "example.com", target: .proxy)
        XCTAssertEqual(outcome, .retargeted(domain: "example.com", from: .direct, to: .proxy))
        XCTAssertEqual(state.customRules.count, 1)
        XCTAssertEqual(state.customRules[0].type, .domainSuffix, "改目标时顺手升级成 SUFFIX 覆盖子域名")
    }

    func testBareIPAndNonDomainHostRejected() {
        let state = makeState()
        XCTAssertEqual(state.quickAddDomainRule(forHost: "142.250.66.14", target: .proxy),
                       .notADomain(host: "142.250.66.14"))
        XCTAssertEqual(state.quickAddDomainRule(forHost: "[2606:4700::1]", target: .proxy),
                       .notADomain(host: "[2606:4700::1]"))
        XCTAssertEqual(state.quickAddDomainRule(forHost: "localhost", target: .proxy),
                       .notADomain(host: "localhost"))
        XCTAssertTrue(state.customRules.isEmpty)
        XCTAssertNotNil(state.toast, "拒绝时也要给 toast 说明原因")
    }

    func testAddPersists() {
        let state = makeState()
        state.quickAddDomainRule(forHost: "youtube.com", target: .proxy)
        state.persistence.waitForPendingWritesForTesting()
        let reloaded = makeState()
        XCTAssertEqual(reloaded.customRules.count, 1)
        XCTAssertEqual(reloaded.customRules.first?.value, "youtube.com")
    }
}
