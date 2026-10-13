import XCTest
import NetworkExtension
import QingzhouCore
@testable import QingzhouApp

final class TunnelSessionCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func configuration(requestID: UUID? = nil) -> AppliedTunnelConfiguration {
        AppliedTunnelConfiguration(
            node: Node(name: "A", protocolType: .trojan, host: "a.example", port: 443, password: "pw"),
            mode: .global, blockQUIC: true, requestID: requestID)
    }

    private func session(_ config: AppliedTunnelConfiguration?, startedAt: Date? = nil,
                         stoppedAt: Date? = nil) -> TunnelSessionInfo {
        TunnelSessionInfo(startedAt: startedAt ?? now, autoStopSeconds: 0,
            stoppedAt: stoppedAt, appliedConfiguration: config)
    }

    // A lingering file cannot establish that a disconnected or stopped tunnel is running.
    func testOnlyLiveConnectedSessionsAreApplied() {
        let config = configuration()
        var coordinator = TunnelSessionCoordinator()
        for status in [NEVPNStatus.connected, .reasserting] {
            coordinator.update(session: session(config), status: status)
            XCTAssertEqual(coordinator.appliedConfiguration?.id, config.id)
        }
        for status in [NEVPNStatus.invalid, .disconnected, .connecting, .disconnecting] {
            coordinator.update(session: session(config), status: status)
            XCTAssertNil(coordinator.appliedConfiguration)
        }
        coordinator.update(session: session(config, stoppedAt: now), status: .connected)
        XCTAssertNil(coordinator.appliedConfiguration)
        coordinator.update(session: nil, status: .connected)
        XCTAssertNil(coordinator.appliedConfiguration)
        coordinator.update(session: session(nil), status: .connected)
        XCTAssertNil(coordinator.appliedConfiguration, "Legacy metadata must remain unknown")
    }

    // Old files and a different start request must not satisfy a newly submitted start.
    func testStartRequiresCurrentRequestAndSessionTime() {
        let request = UUID()
        let config = configuration(requestID: request)
        var coordinator = TunnelSessionCoordinator()
        coordinator.startSubmitted(at: now, requestID: request)
        coordinator.update(session: session(config, startedAt: now.addingTimeInterval(-2)), status: .connected)
        XCTAssertNil(coordinator.appliedConfiguration)
        coordinator.update(session: session(configuration(requestID: UUID())), status: .connected)
        XCTAssertNil(coordinator.appliedConfiguration)
        coordinator.update(session: session(config, startedAt: now.addingTimeInterval(-1)), status: .connected)
        XCTAssertEqual(coordinator.appliedConfiguration?.id, config.id)
    }

    // A switch reply cannot falsely confirm an older shared file or a different request.
    func testSwitchAcknowledgementAndRequestMustBothMatch() throws {
        let request = UUID()
        let config = configuration(requestID: request)
        var coordinator = TunnelSessionCoordinator()
        coordinator.recordAcknowledgement(config.id)
        coordinator.expectRequest(request)
        coordinator.update(session: session(configuration(requestID: request)), status: .connected)
        XCTAssertNil(coordinator.appliedConfiguration)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        payload["requestID"] = UUID().uuidString
        let wrongRequest = try JSONDecoder().decode(AppliedTunnelConfiguration.self,
            from: JSONSerialization.data(withJSONObject: payload))
        coordinator.update(session: session(wrongRequest), status: .connected)
        XCTAssertNil(coordinator.appliedConfiguration)
        coordinator.update(session: session(config), status: .connected)
        XCTAssertEqual(coordinator.appliedConfiguration?.id, config.id)
    }

    // A file disproved by a fresh heartbeat stays rejected across subsequent polls.
    func testContradictionPersistsUntilFreshMatchingHeartbeat() {
        let config = configuration()
        var coordinator = TunnelSessionCoordinator()
        coordinator.update(session: session(config), status: .connected)
        coordinator.ingestHeartbeat(TrafficStats(sampledAt: now, configurationID: UUID()), now: now)
        XCTAssertNil(coordinator.appliedConfiguration)
        coordinator.update(session: session(config), status: .connected)
        XCTAssertNil(coordinator.appliedConfiguration)
        coordinator.ingestHeartbeat(TrafficStats(sampledAt: now.addingTimeInterval(-4), configurationID: config.id), now: now)
        coordinator.update(session: session(config), status: .connected)
        XCTAssertNil(coordinator.appliedConfiguration)
        coordinator.ingestHeartbeat(TrafficStats(sampledAt: now, configurationID: config.id), now: now)
        coordinator.update(session: session(config), status: .connected)
        XCTAssertEqual(coordinator.appliedConfiguration?.id, config.id)
    }

    func testStaleOrUnversionedHeartbeatCannotContradictAppliedSession() {
        let config = configuration()
        var coordinator = TunnelSessionCoordinator()
        coordinator.update(session: session(config), status: .connected)
        for stats in [TrafficStats(sampledAt: now.addingTimeInterval(-4), configurationID: UUID()),
                      TrafficStats(sampledAt: now.addingTimeInterval(4), configurationID: UUID()),
                      TrafficStats(sampledAt: now)] {
            coordinator.ingestHeartbeat(stats, now: now)
            XCTAssertEqual(coordinator.appliedConfiguration?.id, config.id)
        }
    }

    // A full restart replaces the old switch acknowledgement with the new start request.
    func testRestartReplacesSwitchAcknowledgement() {
        let old = configuration()
        let request = UUID()
        let new = configuration(requestID: request)
        var coordinator = TunnelSessionCoordinator()
        coordinator.recordAcknowledgement(old.id)
        coordinator.startSubmitted(at: now, requestID: request)
        coordinator.update(session: session(new), status: .connected)
        XCTAssertEqual(coordinator.appliedConfiguration?.id, new.id)
    }

    // Stop clears confirmation and contradiction state; adoption accepts a running old session.
    func testStopThenAdoptionClearsPreviousConfirmationState() {
        let config = configuration()
        var coordinator = TunnelSessionCoordinator()
        coordinator.update(session: session(config), status: .connected)
        coordinator.ingestHeartbeat(TrafficStats(sampledAt: now, configurationID: UUID()), now: now)
        coordinator.recordAcknowledgement(UUID())
        coordinator.expectRequest(UUID())
        coordinator.clearAppliedState()
        XCTAssertNil(coordinator.appliedConfiguration)
        coordinator.adoptRunningSession()
        coordinator.update(session: session(config, startedAt: now.addingTimeInterval(-100)), status: .connected)
        XCTAssertEqual(coordinator.appliedConfiguration?.id, config.id)
    }
}
