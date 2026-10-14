import XCTest
import QingzhouCore

final class NodeProbePlannerTests: XCTestCase {
    private func node(_ i: Int) -> Node {
        Node(name: "N\(i)", protocolType: i % 3 == 0 ? .hysteria2 : .trojan, host: "n\(i).example", port: 443, password: "pw")
    }
    func testIncumbentControlIsIncludedWithinBudgetAndAliasesAreDeduplicated() {
        let incumbent = node(99), a = node(0)
        var alias = a; alias.id = UUID()
        var planner = NodeProbePlanner()
        let plan = planner.plan(ranked: [a, alias] + (1..<30).map(node), incumbent: incumbent)
        XCTAssertEqual(plan.candidates.first?.id, incumbent.id)
        XCTAssertEqual(plan.candidates.count, 6)
        XCTAssertEqual(Set(plan.candidates.map(\.identityFingerprint)).count, 6)
        XCTAssertEqual(plan.explorationCount, 2)
    }
    func testFixedPoolExplorationEventuallyCoversEveryCandidateIncludingUDP() {
        let ranked = (0..<40).map(node)
        var planner = NodeProbePlanner(), seen: Set<UUID> = []
        for _ in 0..<20 {
            let plan = planner.plan(ranked: ranked, incumbent: ranked[0])
            XCTAssertLessThanOrEqual(plan.candidates.count, 6)
            seen.formUnion(plan.candidates.map(\.id))
        }
        XCTAssertEqual(seen, Set(ranked.map(\.id)))
    }
    func testCurrentAliasOwnsMeasurementAndSmallPoolsDoNotDuplicate() {
        let a = node(1)
        var alias = a; alias.id = UUID()
        var planner = NodeProbePlanner()
        let plan = planner.plan(ranked: [a], incumbent: alias)
        XCTAssertEqual(plan.candidates.map(\.id), [alias.id])
    }
}
