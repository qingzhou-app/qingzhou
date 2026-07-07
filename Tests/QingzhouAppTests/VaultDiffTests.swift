import XCTest
import QingzhouCore
import QingzhouProtocols
@testable import QingzhouApp

/// iCloud 恢复确认弹窗的「与本机配置的差异摘要」—— 纯 diff 逻辑。
/// 弹窗只有云端计数时用户没法判断「恢复会改掉什么」，差异摘要补上这个决策依据。
final class VaultDiffTests: XCTestCase {
    private func node(_ url: String) throws -> Node {
        try ProxyURLParser.parse(url)
    }

    private func makeSnapshot(
        nodes: [Node] = [],
        subscriptions: [Subscription] = [],
        rules: [Rule] = [],
        settings: Settings = Settings()
    ) -> Persistence.Snapshot {
        Persistence.Snapshot(
            subscriptions: subscriptions, nodes: nodes, customRules: rules, settings: settings)
    }

    // MARK: - 完全一致

    func testIdenticalSnapshotsIsEmpty() throws {
        let snapshot = makeSnapshot(
            nodes: [try node("trojan://pw@a.com:443#n1")],
            subscriptions: [Subscription(name: "s", url: URL(string: "https://example.com/sub")!)],
            rules: [Rule(type: .domainSuffix, value: "example.com", target: .proxy)]
        )
        let diff = VaultDiff.between(local: snapshot, cloud: snapshot)
        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.summaryText, "与本机配置一致")
    }

    /// 瞬态字段（延迟 / 当前节点 / 订阅用量与拉取时刻 / 观测带宽）是设备本地量 ——
    /// 不算配置差异，否则每次自动测速后弹窗都显示一堆假「修改」。
    func testTransientOnlyDifferencesAreEmpty() throws {
        var local = makeSnapshot(
            nodes: [try node("trojan://pw@a.com:443#n1")],
            subscriptions: [Subscription(name: "s", url: URL(string: "https://example.com/sub")!)]
        )
        local.nodes[0].lastLatencyMs = 42
        local.nodes[0].lastTestedAt = Date()
        local.nodes[0].lastProxiedLatencyMs = 99
        local.nodes[0].observedPeakDownBps = 1_000_000
        local.currentNodeId = local.nodes[0].id
        local.subscriptions[0].lastUpdatedAt = Date()
        local.subscriptions[0].usedBytes = 4096

        var cloud = local
        cloud.nodes[0].lastLatencyMs = nil
        cloud.nodes[0].lastTestedAt = nil
        cloud.nodes[0].lastProxiedLatencyMs = 12
        cloud.nodes[0].observedPeakDownBps = nil
        cloud.currentNodeId = nil
        cloud.subscriptions[0].lastUpdatedAt = nil
        cloud.subscriptions[0].usedBytes = 8192

        let diff = VaultDiff.between(local: local, cloud: cloud)
        XCTAssertTrue(diff.isEmpty, "只有瞬态字段不同 → 不算差异，实际 \(diff)")
    }

    // MARK: - 节点（按 identityFingerprint 配对）

    func testNodeAddedRemovedModified() throws {
        let shared = try node("trojan://pw@shared.com:443#old-name")
        let localOnly = try node("trojan://pw@local.com:443#local")
        var renamed = shared
        renamed.name = "new-name"   // 指纹同（协议/host/port/凭据没变）、名字变 → 修改
        let cloudOnly1 = try node("trojan://pw@cloud1.com:443#c1")
        let cloudOnly2 = try node("trojan://pw@cloud2.com:443#c2")

        let diff = VaultDiff.between(
            local: makeSnapshot(nodes: [shared, localOnly]),
            cloud: makeSnapshot(nodes: [renamed, cloudOnly1, cloudOnly2])
        )
        XCTAssertEqual(diff.nodesAdded, 2)
        XCTAssertEqual(diff.nodesRemoved, 1)
        XCTAssertEqual(diff.nodesModified, 1)
    }

    func testNodeParameterChangeCountsAsModified() throws {
        let base = try node("trojan://pw@a.com:443#n1")
        var changed = base
        changed.parameters["sni"] = "other.example.com"
        let diff = VaultDiff.between(
            local: makeSnapshot(nodes: [base]),
            cloud: makeSnapshot(nodes: [changed])
        )
        XCTAssertEqual(diff.nodesModified, 1)
        XCTAssertEqual(diff.nodesAdded, 0)
        XCTAssertEqual(diff.nodesRemoved, 0)
    }

    /// 两台设备各自导入同一订阅：节点内容一致但本地 id / subscriptionId 各不相同 ——
    /// 这不是配置差异（id 是设备本地生成的），不能算「修改」。
    func testNodeLocalIdDifferenceIsNotModification() throws {
        let base = try node("trojan://pw@a.com:443#n1")
        var sameButDifferentId = base
        sameButDifferentId.id = UUID()
        sameButDifferentId.subscriptionId = UUID()
        let diff = VaultDiff.between(
            local: makeSnapshot(nodes: [base]),
            cloud: makeSnapshot(nodes: [sameButDifferentId])
        )
        XCTAssertTrue(diff.isEmpty, "只有本地 id 不同 → 不算差异，实际 \(diff)")
    }

    // MARK: - 订阅（按 url 配对）

    func testSubscriptionAddedAndRemovedByURL() {
        let shared = Subscription(name: "shared", url: URL(string: "https://a.example.com/sub")!)
        // 同 url、不同 id / 名字：仍是同一条订阅（url 即身份），不算差异
        var sharedRenamed = Subscription(name: "renamed", url: shared.url)
        sharedRenamed.nodeCount = 30
        let localOnly = Subscription(name: "local", url: URL(string: "https://b.example.com/sub")!)
        let cloudOnly = Subscription(name: "cloud", url: URL(string: "https://c.example.com/sub")!)

        let diff = VaultDiff.between(
            local: makeSnapshot(subscriptions: [shared, localOnly]),
            cloud: makeSnapshot(subscriptions: [sharedRenamed, cloudOnly])
        )
        XCTAssertEqual(diff.subscriptionsAdded, 1)
        XCTAssertEqual(diff.subscriptionsRemoved, 1)
    }

    // MARK: - 规则（按 id 配对，lineForm 兜底）

    func testRuleModifiedById() {
        let rule = Rule(type: .domainSuffix, value: "example.com", target: .proxy)
        var changed = rule
        changed.target = .direct
        let diff = VaultDiff.between(
            local: makeSnapshot(rules: [rule]),
            cloud: makeSnapshot(rules: [changed])
        )
        XCTAssertEqual(diff.rulesModified, 1)
        XCTAssertEqual(diff.rulesAdded, 0)
        XCTAssertEqual(diff.rulesRemoved, 0)
    }

    /// 规则被删了重建（新 id、内容一模一样，比如重新导入规则集）→ 不算差异。
    func testRecreatedRuleWithSameLineFormIsNotADifference() {
        let local = Rule(type: .domainSuffix, value: "example.com", target: .proxy)
        let recreated = Rule(type: .domainSuffix, value: "example.com", target: .proxy)  // 新 id
        XCTAssertNotEqual(local.id, recreated.id)
        let diff = VaultDiff.between(
            local: makeSnapshot(rules: [local]),
            cloud: makeSnapshot(rules: [recreated])
        )
        XCTAssertTrue(diff.isEmpty, "id 变了但 lineForm 相同 → 只是重建，实际 \(diff)")
    }

    func testRuleAddedAndRemoved() {
        let localOnly = Rule(type: .domainSuffix, value: "only-local.com", target: .proxy)
        let cloudOnly1 = Rule(type: .domainSuffix, value: "only-cloud.com", target: .proxy)
        let cloudOnly2 = Rule(type: .domainKeyword, value: "tracker", target: .reject)
        let diff = VaultDiff.between(
            local: makeSnapshot(rules: [localOnly]),
            cloud: makeSnapshot(rules: [cloudOnly1, cloudOnly2])
        )
        XCTAssertEqual(diff.rulesAdded, 2)
        XCTAssertEqual(diff.rulesRemoved, 1)
        XCTAssertEqual(diff.rulesModified, 0)
    }

    // MARK: - 设置

    func testSettingsChangedFieldCount() {
        var cloudSettings = Settings()
        cloudSettings.proxyMode = .global
        cloudSettings.autoStopSeconds = 3600
        let diff = VaultDiff.between(
            local: makeSnapshot(settings: Settings()),
            cloud: makeSnapshot(settings: cloudSettings)
        )
        XCTAssertEqual(diff.settingsChanged, 2)
    }

    func testIdenticalSettingsCountZero() {
        let diff = VaultDiff.between(
            local: makeSnapshot(settings: Settings()),
            cloud: makeSnapshot(settings: Settings())
        )
        XCTAssertEqual(diff.settingsChanged, 0)
    }

    // MARK: - 摘要文案

    func testSummaryTextMixed() {
        let diff = VaultDiff(
            nodesAdded: 3, nodesRemoved: 1, nodesModified: 2,
            subscriptionsAdded: 1, subscriptionsRemoved: 0,
            rulesAdded: 2, rulesRemoved: 0, rulesModified: 0,
            settingsChanged: 1
        )
        XCTAssertEqual(
            diff.summaryText,
            "与本机相比：节点 +3 −1 ~2 · 订阅 +1 · 规则 +2 · 设置 1 项变更"
        )
    }

    func testSummaryOmitsUnchangedCategories() {
        let diff = VaultDiff(
            nodesAdded: 1, nodesRemoved: 0, nodesModified: 0,
            subscriptionsAdded: 0, subscriptionsRemoved: 0,
            rulesAdded: 0, rulesRemoved: 0, rulesModified: 0,
            settingsChanged: 0
        )
        XCTAssertEqual(diff.summaryText, "与本机相比：节点 +1")
    }

    func testSummaryRemovalOnly() {
        let diff = VaultDiff(
            nodesAdded: 0, nodesRemoved: 5, nodesModified: 0,
            subscriptionsAdded: 0, subscriptionsRemoved: 1,
            rulesAdded: 0, rulesRemoved: 0, rulesModified: 3,
            settingsChanged: 0
        )
        XCTAssertEqual(diff.summaryText, "与本机相比：节点 −5 · 订阅 −1 · 规则 ~3")
    }

    func testEmptyDiffSummary() {
        let diff = VaultDiff(
            nodesAdded: 0, nodesRemoved: 0, nodesModified: 0,
            subscriptionsAdded: 0, subscriptionsRemoved: 0,
            rulesAdded: 0, rulesRemoved: 0, rulesModified: 0,
            settingsChanged: 0
        )
        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.summaryText, "与本机配置一致")
    }
}
