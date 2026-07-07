import XCTest
@testable import QingzhouCore

/// NodeMetricsHistory：每节点环形测量历史（最多 20 条），打分引擎稳定性维度的数据源。
/// key 用 identityFingerprint（订阅刷新后 UUID 可能变、指纹稳定）；失败也要记录
/// （latencyMs=nil），成功率就靠失败样本算 —— 只记成功会把烂节点洗白。
final class NodeMetricsHistoryTests: XCTestCase {

    private let fp = "trojan://pw@a.com:443"
    /// 整秒时间戳：Persistence 用 iso8601 编码日期（丢亚秒精度），
    /// 用整秒构造才能做 round-trip 相等断言。
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 环形容量

    func testRingKeepsAtMostCapacityDroppingOldest() {
        var history = NodeMetricsHistory()
        for i in 0..<25 {
            history.recordDirect(fingerprint: fp, latencyMs: i, at: t0.addingTimeInterval(Double(i)))
        }
        let samples = history.samples(for: fp)
        XCTAssertEqual(samples.count, NodeMetricsHistory.capacity)
        // 最老的 5 条被挤掉，保留 5..24
        XCTAssertEqual(samples.first?.latencyMs, 5)
        XCTAssertEqual(samples.last?.latencyMs, 24)
    }

    func testFailureIsRecordedAsNilLatency() {
        var history = NodeMetricsHistory()
        history.recordDirect(fingerprint: fp, latencyMs: nil, at: t0)
        let samples = history.samples(for: fp)
        XCTAssertEqual(samples.count, 1)
        XCTAssertNil(samples.first?.latencyMs)
    }

    func testUnknownFingerprintYieldsEmpty() {
        XCTAssertTrue(NodeMetricsHistory().samples(for: "nope").isEmpty)
        XCTAssertTrue(NodeMetricsHistory().isEmpty)
    }

    // MARK: - 经代理结果的同轮回填

    func testProxiedAttachesToRecentDirectSample() {
        var history = NodeMetricsHistory()
        history.recordDirect(fingerprint: fp, latencyMs: 100, at: t0)
        // 精选紧跟全量测速（同一轮内），并进同一条样本，不另起一条
        history.recordProxied(fingerprint: fp, proxiedMs: 180, at: t0.addingTimeInterval(60))
        let samples = history.samples(for: fp)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.latencyMs, 100)
        XCTAssertEqual(samples.first?.proxiedMs, 180)
    }

    func testProxiedOutsideRoundWindowAppendsStandaloneSample() {
        var history = NodeMetricsHistory()
        history.recordDirect(fingerprint: fp, latencyMs: 100, at: t0)
        // 距上一条直连样本太久（> sameRoundWindow）：这是独立的手动经代理测速，另起一条
        let later = t0.addingTimeInterval(NodeMetricsHistory.sameRoundWindow + 1)
        history.recordProxied(fingerprint: fp, proxiedMs: 250, at: later)
        let samples = history.samples(for: fp)
        XCTAssertEqual(samples.count, 2)
        XCTAssertNil(samples.last?.latencyMs)
        XCTAssertEqual(samples.last?.proxiedMs, 250)
    }

    func testProxiedOnEmptyHistoryAppendsStandaloneSample() {
        var history = NodeMetricsHistory()
        history.recordProxied(fingerprint: fp, proxiedMs: 120, at: t0)
        let samples = history.samples(for: fp)
        XCTAssertEqual(samples.count, 1)
        XCTAssertNil(samples.first?.latencyMs)
        XCTAssertEqual(samples.first?.proxiedMs, 120)
    }

    // MARK: - 序列化

    func testCodableRoundTripWithISO8601Dates() throws {
        var history = NodeMetricsHistory()
        history.recordDirect(fingerprint: fp, latencyMs: 88, at: t0)
        history.recordDirect(fingerprint: fp, latencyMs: nil, at: t0.addingTimeInterval(30))
        history.recordProxied(fingerprint: fp, proxiedMs: 140, at: t0.addingTimeInterval(60))
        history.recordDirect(fingerprint: "ss://x@b.com:8388", latencyMs: 42, at: t0)

        // 与 Persistence 同一套日期策略（iso8601），保证真实落盘格式可 round-trip
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(history)
        let decoded = try decoder.decode(NodeMetricsHistory.self, from: data)
        XCTAssertEqual(decoded, history)
    }

    // MARK: - 清理

    func testPruneKeepsOnlyGivenFingerprints() {
        var history = NodeMetricsHistory()
        history.recordDirect(fingerprint: fp, latencyMs: 50, at: t0)
        history.recordDirect(fingerprint: "vless://u@dead.com:443", latencyMs: 60, at: t0)
        history.prune(keeping: [fp])
        XCTAssertEqual(history.samples(for: fp).count, 1)
        XCTAssertTrue(history.samples(for: "vless://u@dead.com:443").isEmpty)
    }
}
