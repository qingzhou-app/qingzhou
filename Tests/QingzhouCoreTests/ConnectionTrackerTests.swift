import XCTest
@testable import QingzhouCore

/// ConnectionTracker：连接的「最后活跃时间 + 超时老化」判定。
/// xray access log 只记连接建立、没有关闭事件，所以「已关闭」只能靠：
/// - 同一身份（源地址+目标+端口）重现 → 刷新活跃时间；
/// - 超过 idleTimeout 无活动 → 置 closedAt；
/// - 隧道停止 → 全部立即关闭。
final class ConnectionTrackerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func conn(
        source: String = "10.0.0.2:54321",
        host: String = "example.com",
        port: Int = 443,
        type: ConnectionType = .https
    ) -> Connection {
        Connection(
            targetHost: host,
            sourceAddress: source,
            targetAddress: "\(host):\(port)",
            type: type,
            route: "PROXY",
            matchedRule: ""
        )
    }

    // MARK: - ingest

    func testIngestInsertsNewActiveConnection() {
        var tracker = ConnectionTracker()
        tracker.ingest(conn(), at: t0)
        XCTAssertEqual(tracker.connections.count, 1)
        XCTAssertTrue(tracker.connections[0].isActive)
    }

    func testIngestSameIdentityRefreshesInsteadOfDuplicating() {
        var tracker = ConnectionTracker()
        // 返回值 = 是否为新连接：域名每日历史靠它决定「连接次数」计不计数
        XCTAssertTrue(tracker.ingest(conn(), at: t0))
        XCTAssertFalse(tracker.ingest(conn(), at: t0 + 60))   // 同身份重现 → 刷新活跃时间，不重复插入
        XCTAssertEqual(tracker.connections.count, 1)

        // t0+120：距首次 120s > 超时，但距最近活跃只有 60s → 仍应活跃
        tracker.ageOut(at: t0 + 120)
        XCTAssertTrue(tracker.connections[0].isActive)
    }

    func testIngestDifferentPortIsDifferentConnection() {
        var tracker = ConnectionTracker()
        tracker.ingest(conn(port: 443), at: t0)
        tracker.ingest(conn(port: 80, type: .http), at: t0)
        XCTAssertEqual(tracker.connections.count, 2)
    }

    func testIngestDifferentSourceIsDifferentConnection() {
        var tracker = ConnectionTracker()
        tracker.ingest(conn(source: "10.0.0.2:1111"), at: t0)
        tracker.ingest(conn(source: "10.0.0.2:2222"), at: t0)
        XCTAssertEqual(tracker.connections.count, 2)
    }

    func testNewestInsertedFirst() {
        var tracker = ConnectionTracker()
        tracker.ingest(conn(host: "old.com"), at: t0)
        tracker.ingest(conn(host: "new.com"), at: t0 + 1)
        XCTAssertEqual(tracker.connections[0].targetHost, "new.com")
    }

    // MARK: - ageOut

    func testAgeOutClosesIdleConnection() {
        var tracker = ConnectionTracker()
        tracker.ingest(conn(), at: t0)
        tracker.ageOut(at: t0 + ConnectionTracker.idleTimeout + 1)
        XCTAssertFalse(tracker.connections[0].isActive)
        // closedAt 取最后活跃时刻（关闭大概率发生在最后活跃后不久，比 ageOut 时刻更接近真相）
        XCTAssertEqual(tracker.connections[0].closedAt, t0)
    }

    func testAgeOutKeepsFreshConnection() {
        var tracker = ConnectionTracker()
        tracker.ingest(conn(), at: t0)
        tracker.ageOut(at: t0 + ConnectionTracker.idleTimeout - 1)
        XCTAssertTrue(tracker.connections[0].isActive)
    }

    func testAgeOutDoesNotTouchAlreadyClosed() {
        var tracker = ConnectionTracker()
        tracker.ingest(conn(), at: t0)
        tracker.ageOut(at: t0 + ConnectionTracker.idleTimeout + 1)
        let firstClosedAt = tracker.connections[0].closedAt
        tracker.ageOut(at: t0 + 10_000)
        XCTAssertEqual(tracker.connections[0].closedAt, firstClosedAt)
    }

    func testClosedIdentityReappearsAsNewConnection() {
        var tracker = ConnectionTracker()
        tracker.ingest(conn(), at: t0)
        tracker.ageOut(at: t0 + ConnectionTracker.idleTimeout + 1)
        tracker.ingest(conn(), at: t0 + 200)   // 同身份再来 → 是一条新连接
        XCTAssertEqual(tracker.connections.count, 2)
        XCTAssertTrue(tracker.connections[0].isActive)
        XCTAssertFalse(tracker.connections[1].isActive)
    }

    func testIdleTimeoutWithinRecommendedRange() {
        XCTAssertGreaterThanOrEqual(ConnectionTracker.idleTimeout, 90)
        XCTAssertLessThanOrEqual(ConnectionTracker.idleTimeout, 120)
    }

    // MARK: - closeAll（隧道停止）

    func testCloseAllClosesEveryActiveConnection() {
        var tracker = ConnectionTracker()
        tracker.ingest(conn(source: "10.0.0.2:1111"), at: t0)
        tracker.ingest(conn(source: "10.0.0.2:2222"), at: t0 + 5)
        tracker.closeAll(at: t0 + 30)
        XCTAssertTrue(tracker.connections.allSatisfy { !$0.isActive })
        // 隧道就是此刻停的 → closedAt 取 closeAll 时刻
        XCTAssertTrue(tracker.connections.allSatisfy { $0.closedAt == t0 + 30 })
    }

    func testCloseAllThenSameIdentityIsNewConnection() {
        var tracker = ConnectionTracker()
        tracker.ingest(conn(), at: t0)
        tracker.closeAll(at: t0 + 30)
        tracker.ingest(conn(), at: t0 + 60)   // VPN 重开后同身份重现 → 新连接
        XCTAssertEqual(tracker.connections.count, 2)
        XCTAssertTrue(tracker.connections[0].isActive)
    }

    func testCloseAllKeepsEarlierClosedAtIntact() {
        var tracker = ConnectionTracker()
        tracker.ingest(conn(source: "10.0.0.2:1111"), at: t0)
        tracker.ageOut(at: t0 + ConnectionTracker.idleTimeout + 1)   // 先老化关闭
        tracker.ingest(conn(source: "10.0.0.2:2222"), at: t0 + 200)
        tracker.closeAll(at: t0 + 230)
        XCTAssertEqual(tracker.connections.first { $0.sourceAddress.hasSuffix("1111") }?.closedAt, t0)
        XCTAssertEqual(tracker.connections.first { $0.sourceAddress.hasSuffix("2222") }?.closedAt, t0 + 230)
    }

    // MARK: - 容量上限

    func testTrimsBeyondMaxCountDroppingOldest() {
        var tracker = ConnectionTracker(maxCount: 3)
        for i in 0..<5 {
            tracker.ingest(conn(source: "10.0.0.2:\(1000 + i)"), at: t0 + TimeInterval(i))
        }
        XCTAssertEqual(tracker.connections.count, 3)
        // 最旧的两条（1000、1001）被丢弃
        XCTAssertEqual(
            tracker.connections.map(\.sourceAddress),
            ["10.0.0.2:1004", "10.0.0.2:1003", "10.0.0.2:1002"]
        )
    }

    func testEvictedIdentityCanBeIngestedAgain() {
        var tracker = ConnectionTracker(maxCount: 2)
        tracker.ingest(conn(source: "10.0.0.2:1000"), at: t0)
        tracker.ingest(conn(source: "10.0.0.2:1001"), at: t0 + 1)
        tracker.ingest(conn(source: "10.0.0.2:1002"), at: t0 + 2)   // 挤掉 1000
        tracker.ingest(conn(source: "10.0.0.2:1000"), at: t0 + 3)   // 1000 重新出现 → 正常插入
        XCTAssertEqual(tracker.connections.count, 2)
        XCTAssertEqual(tracker.connections[0].sourceAddress, "10.0.0.2:1000")
    }

    func testInPlaceElementMutationSurvivesRefresh() {
        // AppState 会原地回填 sourceApp（macOS content filter 标注），刷新活跃时间不该丢掉它
        var tracker = ConnectionTracker()
        tracker.ingest(conn(), at: t0)
        tracker.connections[0].sourceApp = "com.example.app"
        tracker.ingest(conn(), at: t0 + 10)   // 同身份刷新
        XCTAssertEqual(tracker.connections[0].sourceApp, "com.example.app")
    }
}
