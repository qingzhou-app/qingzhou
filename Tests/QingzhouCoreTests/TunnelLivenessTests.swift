import XCTest
@testable import QingzhouCore

final class TunnelLivenessTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_752_000_000)

    func testFreshHeartbeatIsForwarding() {
        // 心跳 1 秒前 → 扩展活着在转发
        XCTAssertEqual(
            TunnelLiveness.forwarding(lastHeartbeat: t0.addingTimeInterval(-1), now: t0),
            .forwarding
        )
    }

    func testStaleHeartbeatIsStalled() {
        // 心跳 30 秒前 → 扩展死/卡（会话可能还显示连着）
        XCTAssertEqual(
            TunnelLiveness.forwarding(lastHeartbeat: t0.addingTimeInterval(-30), now: t0),
            .stalled
        )
    }

    func testMissingHeartbeatIsUnknown() {
        XCTAssertEqual(TunnelLiveness.forwarding(lastHeartbeat: nil, now: t0), .unknown)
    }

    func testWindowBoundaryInclusive() {
        // 恰好等于窗口 → 仍算新鲜（转发）
        XCTAssertEqual(
            TunnelLiveness.forwarding(
                lastHeartbeat: t0.addingTimeInterval(-TunnelLiveness.heartbeatFreshWindow), now: t0),
            .forwarding
        )
        // 超窗 1 秒 → 卡死
        XCTAssertEqual(
            TunnelLiveness.forwarding(
                lastHeartbeat: t0.addingTimeInterval(-TunnelLiveness.heartbeatFreshWindow - 1), now: t0),
            .stalled
        )
    }

    func testIdleTunnelStillForwarding() {
        // 关键语义:空闲无流量时扩展仍每秒写心跳(速率 0),所以 2 秒前的心跳=活着,
        // 不能因为「没上网」就误判成 stalled。
        XCTAssertEqual(
            TunnelLiveness.forwarding(lastHeartbeat: t0.addingTimeInterval(-2), now: t0),
            .forwarding
        )
    }
}
