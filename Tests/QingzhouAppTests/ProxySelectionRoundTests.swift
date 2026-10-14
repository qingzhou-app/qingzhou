import XCTest
import QingzhouCore
@testable import QingzhouApp

@MainActor
final class ProxySelectionRoundTests: XCTestCase {
    private let a = Node(name: "A", protocolType: .trojan, host: "a.example", port: 443, password: "pw")
    private let b = Node(name: "B", protocolType: .trojan, host: "b.example", port: 443, password: "pw")
    private let target = ConnectivityProbe.defaultProxiedTarget

    func testSuccessPoolExcludesFailedCandidateAndConfirmsFailureAgainstSecondTarget() async {
        var targets: [String] = []
        let result = await ProxySelectionRound.run(candidates: [a, b], incumbentID: a.id, initialID: b.id,
            target: target, shouldContinue: { true }) { node, url in
                if node.id == self.a.id { targets.append(url); return .failure(.probeFailed) }
                return .success(120)
            }
        XCTAssertEqual(result.measurements.map(\.node.id), [b.id])
        XCTAssertEqual(result.confirmedFailures, [a.identityFingerprint])
        XCTAssertEqual(Set(targets).count, 2, "复核使用不同主机，避免同一站点失败被当成节点证据")
    }

    func testAllFailuresDoNotCreateNodeCooldownEvidence() async {
        let result = await ProxySelectionRound.run(candidates: [a, b], incumbentID: a.id, initialID: b.id,
            target: target, shouldContinue: { true }) { _, _ in .failure(.probeFailed) }
        XCTAssertTrue(result.measurements.isEmpty)
        XCTAssertTrue(result.confirmedFailures.isEmpty, "无成功对照时不能排除公共网络或目标问题")
        XCTAssertEqual(result.evidence.attempted, 4)
    }

    func testBackupSuccessDoesNotMixLatencyWithPrimarySuccess() async {
        let result = await ProxySelectionRound.run(candidates: [a, b], incumbentID: a.id, initialID: b.id,
            target: target, shouldContinue: { true }) { node, url in
                if node.id == self.b.id { return .success(150) }
                return url == self.target ? .failure(.probeFailed) : .success(10)
            }
        XCTAssertEqual(result.measurements.map(\.node.id), [b.id], "不同目标延迟不放在同轮一起比较")
        XCTAssertTrue(result.confirmedFailures.isEmpty)
    }

    func testAllPrimaryFailuresCanUseCommonBackupSuccesses() async {
        let result = await ProxySelectionRound.run(candidates: [a, b], incumbentID: a.id, initialID: b.id,
            target: target, shouldContinue: { true }) { _, url in
                url == self.target ? .failure(.probeFailed) : .success(200)
            }
        XCTAssertEqual(Set(result.measurements.map(\.node.id)), [a.id, b.id])
        XCTAssertTrue(result.confirmedFailures.isEmpty)
    }

    func testResourceFailureStopsRoundWithoutRetryOrNodePenalty() async {
        let result = await ProxySelectionRound.run(candidates: [a, b], incumbentID: a.id, initialID: b.id,
            target: target, shouldContinue: { true }) { _, _ in .failure(.resourceLimited) }
        XCTAssertEqual(result.evidence.attempted, 1)
        XCTAssertEqual(result.evidence.state, .interrupted)
        XCTAssertTrue(result.confirmedFailures.isEmpty)
    }

    func testConfirmationBudgetIsTwoAndPrioritizesIncumbentAndInitialChoice() async {
        let others = (0..<5).map { Node(name: "N\($0)", protocolType: .trojan, host: "n\($0).example", port: 443) }
        var retries: [UUID] = []
        let result = await ProxySelectionRound.run(candidates: others + [a, b], incumbentID: a.id, initialID: b.id,
            target: target, shouldContinue: { true }) { node, url in
                if url != self.target { retries.append(node.id) }
                return .failure(.probeFailed)
            }
        XCTAssertEqual(retries, [a.id, b.id])
        XCTAssertEqual(result.evidence.attempted, 9)
    }

    func testSuccessfulAliasCannotBeCooledDownThroughItsOtherUUID() async {
        var alias = a; alias.id = UUID(); alias.name = "same connection from another subscription"
        let aliasID = alias.id
        let result = await ProxySelectionRound.run(candidates: [a, alias], incumbentID: a.id, initialID: a.id,
            target: target, shouldContinue: { true }) { node, _ in
                node.id == aliasID ? .success(80) : .failure(.probeFailed)
            }
        XCTAssertEqual(result.measurements.map(\.node.id), [aliasID])
        XCTAssertTrue(result.confirmedFailures.isEmpty)
    }

    func testInterruptedRoundDoesNotConfirmOrPublishPartialWinner() async {
        var active = true
        let result = await ProxySelectionRound.run(candidates: [a, b], incumbentID: a.id, initialID: b.id,
            target: target, shouldContinue: { active }) { _, _ in active = false; return .success(40) }
        XCTAssertTrue(result.measurements.isEmpty)
        XCTAssertTrue(result.confirmedFailures.isEmpty)
        XCTAssertEqual(result.evidence.state, .interrupted)
    }
}
