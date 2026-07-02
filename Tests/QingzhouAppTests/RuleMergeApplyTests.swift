import XCTest
import QingzhouCore
import QingzhouLogging
@testable import QingzhouApp

/// AppState.applyRuleMerge：「可合并规则」建议的一键替换（删掉同域名散规则、
/// 插入一条 DOMAIN-SUFFIX，走 addCustomRule 同款持久化 + 热切换路径）。
@MainActor
final class RuleMergeApplyTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rule-merge-test-\(UUID().uuidString)", isDirectory: true)
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

    func testApplyReplacesScatteredRulesWithOneSuffixRuleInPlace() {
        let state = makeState()
        let unrelatedBefore = Rule(type: .geoip, value: "cn", target: .direct)
        let m1 = Rule(type: .domain, value: "www.youtube.com", target: .proxy)
        let unrelatedMid = Rule(type: .domainSuffix, value: "example.com", target: .direct)
        let m2 = Rule(type: .domain, value: "m.youtube.com", target: .proxy)
        state.customRules = [unrelatedBefore, m1, unrelatedMid, m2]

        let suggestion = RuleConsolidator.mergeSuggestions(customRules: state.customRules)
            .first { $0.domain == "youtube.com" }!
        XCTAssertTrue(state.applyRuleMerge(suggestion))

        XCTAssertEqual(state.customRules.count, 3)
        // 合并规则落在第一条被替换规则的位置（保住 first-match 优先级），无关规则原样保留
        XCTAssertEqual(state.customRules[0].id, unrelatedBefore.id)
        XCTAssertEqual(state.customRules[1].type, .domainSuffix)
        XCTAssertEqual(state.customRules[1].value, "youtube.com")
        XCTAssertEqual(state.customRules[1].target, .proxy)
        XCTAssertEqual(state.customRules[2].id, unrelatedMid.id)
        XCTAssertNotNil(state.toast, "合并后应有 toast 反馈")
    }

    func testApplyPersists() {
        let state = makeState()
        state.customRules = [
            Rule(type: .domain, value: "a.example.com", target: .reject),
            Rule(type: .domain, value: "b.example.com", target: .reject),
        ]
        let suggestion = RuleConsolidator.mergeSuggestions(customRules: state.customRules)[0]
        XCTAssertTrue(state.applyRuleMerge(suggestion))
        state.persistence.waitForPendingWritesForTesting()

        let reloaded = makeState()
        XCTAssertEqual(reloaded.customRules.count, 1)
        XCTAssertEqual(reloaded.customRules[0].lineForm, "DOMAIN-SUFFIX,example.com,REJECT")
    }

    func testStaleSuggestionIsRejected() {
        let state = makeState()
        let m1 = Rule(type: .domain, value: "www.youtube.com", target: .proxy)
        let m2 = Rule(type: .domain, value: "m.youtube.com", target: .proxy)
        state.customRules = [m1, m2]
        let suggestion = RuleConsolidator.mergeSuggestions(customRules: state.customRules)[0]

        // 建议生成后规则集变了（被删光）→ 不应用、不新增
        state.customRules = []
        XCTAssertFalse(state.applyRuleMerge(suggestion))
        XCTAssertTrue(state.customRules.isEmpty)
    }
}
