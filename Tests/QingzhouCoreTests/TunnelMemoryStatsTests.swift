import XCTest
@testable import QingzhouCore

/// 扩展内存快照的编解码契约 —— 扩展（ISO8601 encode）和主 App（AppGroupStorage 的
/// ISO8601 decode）两端独立实现，靠这组测试钉住格式不漂移。
final class TunnelMemoryStatsTests: XCTestCase {

    func testCodableRoundTripISO8601() throws {
        let stats = TunnelMemoryStats(
            footprintBytes: 23 * 1024 * 1024,
            availableBytes: 27 * 1024 * 1024,
            sessionPeakBytes: 31 * 1024 * 1024,
            allTimePeakBytes: 42 * 1024 * 1024,
            limitBytes: 50 * 1024 * 1024,
            warningCount: 2,
            error: "task_info(TASK_VM_INFO) kr=4",
            sampledAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(TunnelMemoryStats.self, from: encoder.encode(stats))
        XCTAssertEqual(back, stats)
    }

    func testAvailableBytesOptionalOnMacOS() throws {
        // macOS 上 os_proc_available_memory 不可用 → availableBytes 为 nil，JSON 里可缺席
        let json = #"{"footprintBytes":1024,"sessionPeakBytes":2048,"allTimePeakBytes":4096,"limitBytes":0,"warningCount":0,"sampledAt":"2026-07-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stats = try decoder.decode(TunnelMemoryStats.self, from: Data(json.utf8))
        XCTAssertNil(stats.availableBytes)
        XCTAssertNil(stats.error, "旧版扩展写的 JSON 没有 error 字段，解码必须兼容")
        XCTAssertEqual(stats.footprintBytes, 1024)
    }

    // MARK: - GeoDataBundle（内置 geo 数据能力声明）

    func testBundledGeoIPOnlyCnAndPrivate() {
        XCTAssertTrue(GeoDataBundle.supportsGeoIP("cn"))
        XCTAssertTrue(GeoDataBundle.supportsGeoIP("CN"))
        XCTAssertTrue(GeoDataBundle.supportsGeoIP(" private "))
        XCTAssertTrue(GeoDataBundle.supportsGeoIP("!cn"), "反转前缀不影响分类码本身的支持判断")
        XCTAssertFalse(GeoDataBundle.supportsGeoIP("us"))
        XCTAssertFalse(GeoDataBundle.supportsGeoIP("jp"))
        XCTAssertFalse(GeoDataBundle.supportsGeoIP(""))
    }
}
