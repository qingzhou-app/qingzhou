import XCTest
import QingzhouCore

final class DirectProbePlannerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func node(_ i: Int) -> Node { .init(name: "N\(i)", protocolType: .trojan, host: "n\(i).example", port: 443) }

    func testRecentFailuresAreReusedButCurrentAndConfirmingNodesAreRetested() {
        var nodes = (0..<40).map(node)
        for i in nodes.indices { nodes[i].lastTestedAt = now }
        let plan = DirectProbePlanner.plan(ranked: nodes, incumbentID: nodes[30].id, now: now,
                                           confirmingIdentity: nodes[31].identityFingerprint)
        XCTAssertEqual(plan.candidates.map(\.id), [nodes[30].id, nodes[31].id])
        XCTAssertEqual(plan.reusedCount, 38)
        XCTAssertEqual(plan.deferredCount, 0)
    }

    func testCacheExpiresAtBoundaryAndRejectsFutureTimes() {
        var nodes = (0..<3).map(node)
        nodes[0].lastTestedAt = now.addingTimeInterval(-299)
        nodes[1].lastTestedAt = now.addingTimeInterval(-300)
        nodes[2].lastTestedAt = now.addingTimeInterval(1)
        let plan = DirectProbePlanner.plan(ranked: nodes, incumbentID: nil, now: now)
        XCTAssertEqual(Set(plan.candidates.map(\.id)), Set([nodes[1].id, nodes[2].id]))
        XCTAssertEqual(plan.reusedCount, 1)
    }

    func testOldestExplorationCoversPoolEvenWhenTopRankNeverChanges() {
        var nodes = (0..<72).map(node)
        var seen: Set<UUID> = []
        for round in 0..<5 {
            let at = now.addingTimeInterval(Double(round * 600))
            let plan = DirectProbePlanner.plan(ranked: nodes, incumbentID: nodes[0].id, now: at)
            XCTAssertLessThanOrEqual(plan.candidates.count, 24)
            let ids = Set(plan.candidates.map(\.id)); seen.formUnion(ids)
            for i in nodes.indices where ids.contains(nodes[i].id) { nodes[i].lastTestedAt = at }
        }
        XCTAssertEqual(seen.count, 72)
    }

    func testAliasesShareFreshnessButDifferentCredentialsRemainDistinct() {
        var a = node(0), alias = a
        alias.id = UUID(); alias.lastTestedAt = now
        var other = a; other.id = UUID(); other.password = "different"
        a.isExcluded = false
        let plan = DirectProbePlanner.plan(ranked: [a, alias, other], incumbentID: nil, now: now)
        XCTAssertEqual(plan.candidates.map(\.id), [other.id])
        XCTAssertEqual(plan.reusedCount, 1)
    }
}
