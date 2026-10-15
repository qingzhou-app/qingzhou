import XCTest
import QingzhouCore
@testable import QingzhouApp

@MainActor
final class SelectionScenarioReplayTests: XCTestCase {
    typealias Replay = SelectionScenarioReplay
    typealias Scenario = Replay.Scenario
    typealias Frame = Replay.Frame
    typealias Probe = Replay.Probe

    private static let pair: [Replay.Spec] = [.init(id: "A"), .init(id: "B")]
    private static var recovery: Scenario {
        .init(name: "outage-cooldown-recovery", nodes: pair, initialChoice: "A", frames: [
            .init(at: 30, primary: ["A": .failed, "B": .success(600)], backupDefault: .failed,
                  available: ["B"], acceptable: ["B"], outageStartedAt: 10),
            .init(at: 90, primaryDefault: .success(600), available: ["A", "B"], acceptable: ["B"]),
            .init(at: 330, primary: ["A": .success(20), "B": .success(600)], available: ["A", "B"], acceptable: ["A", "B"]),
            .init(at: 630, primary: ["A": .success(20), "B": .success(600)], available: ["A", "B"], acceptable: ["A"])
        ])
    }
    private static var targetFailure: Scenario {
        .init(name: "target-outage", nodes: pair, initialChoice: "A", frames: [
            .init(at: 0, backup: ["A": .failed, "B": .success(80)], primaryDefault: .failed,
                  available: ["B"], acceptable: ["B"])
        ])
    }
    private static var globalFailure: Scenario {
        .init(name: "global-failure-resource", nodes: pair, initialChoice: "A", frames: [
            .init(at: 0, primaryDefault: .failed, backupDefault: .failed, acceptable: ["A"]),
            .init(at: 300, primaryDefault: .init(failure: "resourceLimited"), acceptable: ["A"])
        ])
    }
    private static var pathReset: Scenario {
        .init(name: "network-streak-reset", nodes: pair, initialChoice: "A", frames: [
            .init(at: 0, primary: ["A": .success(600), "B": .success(20)], acceptable: ["A", "B"]),
            .init(at: 60, primary: ["A": .success(600), "B": .success(20)], networkChanged: true, acceptable: ["A", "B"]),
            .init(at: 120, primary: ["A": .success(600), "B": .success(20)], acceptable: ["B"])
        ])
    }
    private static var boundedPool: Scenario {
        .init(name: "large-pool-budget", nodes: (0..<80).map { .init(id: "N\($0)") }, initialChoice: "N79",
              frames: [0.0, 60, 120, 180].map { .init(at: $0, primaryDefault: .success(80), acceptable: ["N79"]) })
    }
    private static var jitter: Scenario {
        let frames: [Frame] = (0..<6).map { index in
            let a = index % 2 == 0 ? 80 : 78
            let b = index % 2 == 0 ? 78 : 80
            return Frame(at: Double(index * 300), primary: ["A": .success(a), "B": .success(b)], acceptable: ["A"])
        }
        return Scenario(name: "small-jitter", nodes: pair, initialChoice: "A", frames: frames)
    }
    private static var suite: [Scenario] { [recovery, targetFailure, globalFailure, pathReset, boundedPool, jitter] }

    func testOutageRecoveryCooldownExpiryAndNormalTwoRoundLeadUseVirtualTime() async throws {
        let report = try await Replay.run(Self.recovery)
        XCTAssertEqual(report.rounds.map(\.selected), ["B", "B", "B", "A"])
        XCTAssertEqual(report.rounds[0].reason, "availabilityRecovery")
        XCTAssertEqual(report.rounds[0].cooling, ["A"])
        XCTAssertEqual(report.rounds[1].proxyNodes, ["B"])
        XCTAssertEqual(report.rounds[2].cooling, [])
        XCTAssertEqual(report.rounds[2].reason, "confirmingLead-1-2")
        XCTAssertEqual(report.recoveryDecisionSeconds, [20])
        XCTAssertEqual(report.switchCount, 2)
        XCTAssertEqual(report.unacceptableSwitchCount, 0)
        XCTAssertEqual(report.unresolvedOutages, 0)
    }

    func testGlobalOrResourceFailureKeepsSelectionWithoutPunishingNodes() async throws {
        let report = try await Replay.run(Self.globalFailure)
        XCTAssertEqual(report.rounds.map(\.selected), ["A", "A"])
        XCTAssertEqual(report.rounds.map(\.proxyRequests), [4, 1])
        XCTAssertEqual(report.rounds.map(\.cooldownCount), [0, 0])
        XCTAssertEqual(report.rounds.map(\.reason), ["proxyUnverified", "proxyUnverified"])
    }

    func testSwitchToUnavailableChoiceStartsOutageAtDecisionTime() async throws {
        let mistaken = Frame(at: 30, primary: ["A": .success(600), "B": .success(20)], manual: true,
                             available: ["A"], acceptable: ["A"], outageStartedAt: 10)
        let ended = try await Replay.run(.init(name: "switch-to-unavailable", nodes: Self.pair,
                                              initialChoice: "A", frames: [mistaken]))
        XCTAssertEqual(ended.rounds[0].selected, "B")
        XCTAssertEqual(ended.unacceptableSwitchCount, 1)
        XCTAssertEqual(ended.unresolvedOutages, 1)
        XCTAssertTrue(ended.recoveryDecisionSeconds.isEmpty)

        let recovered = try await Replay.run(.init(name: "recover-after-mistake", nodes: Self.pair,
            initialChoice: "A", frames: [mistaken,
                .init(at: 60, primary: ["A": .success(20), "B": .success(600)], manual: true,
                      available: ["A"], acceptable: ["A"])
            ]))
        XCTAssertEqual(recovered.rounds.map(\.selected), ["B", "A"])
        XCTAssertEqual(recovered.recoveryDecisionSeconds, [30])
        XCTAssertEqual(recovered.unresolvedOutages, 0)
    }

    func testBackupTargetCanRecoverOnlyWhenPrimaryHasNoSuccess() async throws {
        let report = try await Replay.run(Self.targetFailure)
        XCTAssertEqual(report.rounds[0].selected, "B")
        XCTAssertTrue(report.rounds[0].usedBackup)
        XCTAssertEqual(report.rounds[0].confirmations, 2)
        let mixed = Scenario(name: "do-not-mix-targets", nodes: Self.pair, initialChoice: "A", frames: [
            .init(at: 0, primary: ["A": .success(900), "B": .failed], backupDefault: .success(10), acceptable: ["A"])
        ])
        let mixedReport = try await Replay.run(mixed)
        XCTAssertEqual(mixedReport.rounds[0].selected, "A")
        XCTAssertFalse(mixedReport.rounds[0].usedBackup)
        XCTAssertEqual(mixedReport.rounds[0].cooldownCount, 0)
    }

    func testNetworkChangeResetsLeadAndRejectsInFlightProxyEvidence() async throws {
        let report = try await Replay.run(Self.pathReset)
        XCTAssertEqual(report.rounds.map(\.selected), ["A", "A", "B"])
        XCTAssertEqual(report.rounds.map(\.directRequests), [6, 6, 6])
        let interrupted = Scenario(name: "network-in-flight", nodes: Self.pair, initialChoice: "A", frames: [
            .init(at: 0, primaryDefault: .success(20), changeNetworkDuringProxy: true, acceptable: ["A"])
        ])
        let stopped = try await Replay.run(interrupted)
        XCTAssertEqual(stopped.rounds[0].selected, "A")
        XCTAssertEqual(stopped.rounds[0].reason, "networkChanged")
        XCTAssertEqual(stopped.rounds[0].proxyRequests, 1)
    }

    func testLargePoolCostIsBoundedAndSmallJitterDoesNotSwitch() async throws {
        let report = try await Replay.run(Self.boundedPool)
        XCTAssertTrue(report.rounds.allSatisfy { $0.directRequests <= 72 && $0.proxyRequests <= 8 })
        XCTAssertEqual(report.directRequests, 249) // 80个身份各一次 + 当前节点后续3轮各一次，共83组burst。
        XCTAssertEqual(report.switchCount, 0)
        XCTAssertEqual(report.rounds[0].directDeferred, 56)
        XCTAssertEqual(report.rounds.last?.directDeferred, 0)
        let jitter = try await Replay.run(Self.jitter)
        XCTAssertEqual(jitter.switchCount, 0)
        XCTAssertEqual(jitter.unacceptableSwitchCount, 0)
    }

    func testUDPRecoveryDoesNotSpendTCPBudgetOnUDP() async throws {
        let input = Scenario(name: "udp-recovery", nodes: [.init(id: "A"), .init(id: "B", udp: true)], initialChoice: "A", frames: [
            .init(at: 0, directFailures: ["A"], primary: ["A": .failed, "B": .success(40)],
                  backupDefault: .failed, available: ["B"], acceptable: ["B"])
        ])
        let report = try await Replay.run(input)
        XCTAssertEqual(report.rounds[0].selected, "B")
        XCTAssertEqual(report.directRequests, 3)
        XCTAssertEqual(report.rounds[0].reason, "availabilityRecovery")
    }

    func testFixtureValidationRejectsMissingProxyEvidenceAndUnknownTruth() async throws {
        do {
            _ = try await Replay.run(.init(name: "missing", nodes: Self.pair, initialChoice: "A", frames: [.init(at: 0)]))
            XCTFail("Missing observations must not silently become a node failure")
        } catch Replay.InputError.missingProxyObservation { }
        do {
            _ = try await Replay.run(.init(name: "bad-truth", nodes: Self.pair, initialChoice: "A", frames: [.init(at: 0, available: ["C"])]))
            XCTFail("Unknown oracle node")
        } catch Replay.InputError.invalidScenario { }
    }

    func testAliasDefaultCannotOverwriteExplicitMeasurementAndConflictsAreRejected() async throws {
        let specs: [Replay.Spec] = [.init(id: "A"), .init(id: "Alias", aliasOf: "A"), .init(id: "C")]
        let input = Scenario(name: "alias-input", nodes: specs, initialChoice: "C", frames: [
            .init(at: 0, directMs: ["A": 600, "C": 100], vpnRunning: false)
        ])
        let result = try await Replay.run(input)
        XCTAssertEqual(result.rounds[0].selected, "C")
        let conflict = Scenario(name: "alias-conflict", nodes: specs, initialChoice: "C", frames: [
            .init(at: 0, directMs: ["A": 600, "Alias": 20], vpnRunning: false)
        ])
        do { _ = try await Replay.run(conflict); XCTFail("Conflicting alias input must not depend on iteration order") }
        catch Replay.InputError.invalidScenario { }
        let sharedTruth = Scenario(name: "alias-truth", nodes: Array(specs.prefix(2)), initialChoice: "Alias", frames: [
            .init(at: 0, primaryDefault: .success(80), available: ["A"])
        ])
        let truth = try await Replay.run(sharedTruth)
        XCTAssertEqual(truth.unresolvedOutages, 0)
        XCTAssertTrue(truth.recoveryDecisionSeconds.isEmpty)
    }

    /// scripts/replay-selection.sh 的入口；也随全量测试运行。不设环境变量就不生成文件。
    func testScenarioSuiteAndOptionalJSONReport() async throws {
        var scenarios = Self.suite
        if let path = ProcessInfo.processInfo.environment["QZ_SELECTION_SCENARIOS"] {
            scenarios = try JSONDecoder().decode([Scenario].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        var reports: [Replay.Report] = []
        for input in scenarios { reports.append(try await Replay.run(input)) }
        XCTAssertFalse(reports.isEmpty)
        if let path = ProcessInfo.processInfo.environment["QZ_SELECTION_REPORT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoder.encode(reports).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
