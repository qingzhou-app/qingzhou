import XCTest
import NetworkExtension
import QingzhouCore
@testable import QingzhouApp

@MainActor
final class RemoteRuleApplicationTests: XCTestCase {
    private func state(appliedRules: [Rule]?, mode: ProxyMode = .rule) -> AppState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rule-application-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(persistence: Persistence(directory: directory))
        state.settings.iCloudSyncEnabled = false
        state.settings.proxyMode = mode
        state.isVPNRunning = true
        let node = Node(name: "A", protocolType: .trojan, host: "a.example", port: 443, password: "pw")
        let applied = AppliedTunnelConfiguration(node: node, mode: mode, blockQUIC: true,
            rulesDigest: appliedRules.map(AppliedTunnelConfiguration.digestRules))
        state.syncAppliedConfiguration(session: TunnelSessionInfo(startedAt: Date(), autoStopSeconds: 0,
            appliedConfiguration: applied), status: .connected)
        return state
    }

    func testFirstFetchAfterAppRestartDoesNotRestartIdenticalAppliedRules() {
        let rules = [Rule(type: .domainSuffix, value: "example.com", target: .proxy)]
        let state = state(appliedRules: rules)
        XCTAssertTrue(state.remoteRules.isEmpty)
        let freshlyParsed = [Rule(type: .domainSuffix, value: "example.com", target: .proxy, comment: "new parse")]
        XCTAssertFalse(state.applyFetchedRemoteRules(freshlyParsed))
        XCTAssertEqual(state.remoteRules.count, 1)
    }

    func testCustomRuleOrderAndTargetChangesStillRequireReapply() {
        let a = Rule(type: .domainSuffix, value: "a.example", target: .proxy)
        let b = Rule(type: .domainSuffix, value: "b.example", target: .direct)
        let state = state(appliedRules: [a, b])
        state.customRules = [a]
        XCTAssertFalse(state.applyFetchedRemoteRules([b]))
        state.customRules = [b]
        XCTAssertTrue(state.applyFetchedRemoteRules([a]), "First-match order is meaningful")
        state.customRules = [a]
        var changed = b
        changed.target = .reject
        XCTAssertTrue(state.applyFetchedRemoteRules([changed]))
    }

    func testFailedPreviousApplyIsRetriedEvenWhenLocalRulesDidNotChange() {
        let old = Rule(type: .domainSuffix, value: "old.example", target: .proxy)
        let new = Rule(type: .domainSuffix, value: "new.example", target: .proxy)
        let state = state(appliedRules: [old])
        state.remoteRules = [new]
        XCTAssertTrue(state.applyFetchedRemoteRules([new]), "Local cache is not proof of applied rules")
    }

    func testChangedFetchDuringInFlightReapplyQueuesCurrentRules() {
        let rules = [Rule(type: .domainSuffix, value: "example.com", target: .proxy)]
        let state = state(appliedRules: rules)
        state.isSwitchingTunnel = true
        // The in-flight full restart may already have captured this process's empty rule list.
        XCTAssertTrue(state.applyFetchedRemoteRules(rules), "Old applied metadata cannot prove the in-flight request uses these rules")
    }

    func testLegacyUnknownDigestKeepsSafeChangedRuleFallback() {
        let rules = [Rule(type: .domainSuffix, value: "example.com", target: .proxy)]
        let state = state(appliedRules: nil)
        XCTAssertTrue(state.applyFetchedRemoteRules(rules))
        XCTAssertFalse(state.applyFetchedRemoteRules(rules))
    }

    func testGlobalOrStoppedTunnelDoesNotReapplyRemoteRules() {
        let rules = [Rule(type: .domainSuffix, value: "example.com", target: .proxy)]
        let global = state(appliedRules: [], mode: .global)
        XCTAssertFalse(global.applyFetchedRemoteRules(rules))
        let stopped = state(appliedRules: [])
        stopped.isVPNRunning = false
        XCTAssertFalse(stopped.applyFetchedRemoteRules(rules))
    }
}
