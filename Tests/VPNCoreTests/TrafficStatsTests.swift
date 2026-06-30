import XCTest
@testable import VPNCore

final class TrafficStatsTests: XCTestCase {

    func testHistoryDropsOldestBeyondCapacity() {
        var h = TrafficHistory(capacity: 3)
        for i in 1...5 {
            h.record(TrafficStats(uploadSpeedBps: Int64(i)))
        }
        XCTAssertEqual(h.samples.count, 3, "超容量必须丢最老的")
        XCTAssertEqual(h.samples.map(\.uploadSpeedBps), [3, 4, 5])
        XCTAssertEqual(h.latest?.uploadSpeedBps, 5)
    }

    func testPeakSpeedTakesMaxOfUpAndDown() {
        var h = TrafficHistory(capacity: 10)
        h.record(TrafficStats(uploadSpeedBps: 100, downloadSpeedBps: 20))
        h.record(TrafficStats(uploadSpeedBps: 10, downloadSpeedBps: 400))
        XCTAssertEqual(h.peakSpeed, 400, "纵轴归一化取窗口内上下行最大值")
    }

    func testEmptyHistoryIsZeroPeakAndNilLatest() {
        let h = TrafficHistory(capacity: 5)
        XCTAssertEqual(h.peakSpeed, 0)
        XCTAssertNil(h.latest)
    }

    func testCapacityFloorIsAtLeastOne() {
        var h = TrafficHistory(capacity: 0)
        h.record(TrafficStats(uploadSpeedBps: 1))
        h.record(TrafficStats(uploadSpeedBps: 2))
        XCTAssertEqual(h.samples.count, 1, "容量下限为 1，不能退化成 0 永远存不下")
        XCTAssertEqual(h.latest?.uploadSpeedBps, 2)
    }

    func testTrafficStatsRoundTripsThroughJSON() throws {
        // 整秒时间戳：iso8601 默认不带小数秒，整秒编解码无损（跨进程速率样本不需要亚秒精度）
        let s = TrafficStats(uploadBytes: 1024, downloadBytes: 4096,
                             uploadSpeedBps: 128, downloadSpeedBps: 512,
                             activeConnections: 3,
                             sampledAt: Date(timeIntervalSince1970: 1_719_765_600))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(TrafficStats.self, from: enc.encode(s))
        XCTAssertEqual(back, s, "appex 编码→主 app 解码必须无损（跨进程 App Group 上报靠它）")
    }
}
