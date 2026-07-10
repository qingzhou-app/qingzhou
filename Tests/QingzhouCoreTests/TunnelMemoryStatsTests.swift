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

    // MARK: - TunnelMemoryPeakGuard（历史峰值坏数据的读侧钳制 + 写侧防护）

    /// 2026-07 真实事故回归：用户 Mac 的 memory-stats.json 里 allTimePeakBytes=8427511368
    /// （≈7.85 GiB，崩溃循环时代 autoreleasepool 缺失泄漏的真实读数），落盘后被每次启动
    /// 读回接续，永久粘住。读侧必须把它判损坏丢弃。
    func testSanitizedPersistedPeakDiscardsRealWorldCorruptValue() {
        XCTAssertEqual(TunnelMemoryPeakGuard.sanitizedPersistedPeak(8_427_511_368), 0,
                       "8.4GB 的历史峰值物理上不可能（iOS jetsam 50MB / macOS 常态 ~60MB），必须丢弃重建")
    }

    func testSanitizedPersistedPeakKeepsPlausibleValues() {
        let normal: Int64 = 54 * 1024 * 1024   // 用户 Mac 实测真实 footprint 量级
        XCTAssertEqual(TunnelMemoryPeakGuard.sanitizedPersistedPeak(normal), normal)
        // 恰好在上限 = 可信（闭区间）
        XCTAssertEqual(
            TunnelMemoryPeakGuard.sanitizedPersistedPeak(TunnelMemoryPeakGuard.maxPlausiblePeakBytes),
            TunnelMemoryPeakGuard.maxPlausiblePeakBytes)
    }

    func testSanitizedPersistedPeakDiscardsNonPositiveAndJustOverCap() {
        XCTAssertEqual(TunnelMemoryPeakGuard.sanitizedPersistedPeak(0), 0)
        XCTAssertEqual(TunnelMemoryPeakGuard.sanitizedPersistedPeak(-1), 0, "负数 = 编码损坏，同样丢弃")
        XCTAssertEqual(
            TunnelMemoryPeakGuard.sanitizedPersistedPeak(TunnelMemoryPeakGuard.maxPlausiblePeakBytes + 1),
            0, "超上限 1 字节即损坏 —— 边界必须是硬的")
    }

    func testMergingPeakTracksPlausibleSamples() {
        let mb30: Int64 = 30 * 1024 * 1024
        let mb40: Int64 = 40 * 1024 * 1024
        XCTAssertEqual(TunnelMemoryPeakGuard.mergingPeak(0, sample: mb30), mb30, "首个样本建立峰值")
        XCTAssertEqual(TunnelMemoryPeakGuard.mergingPeak(mb40, sample: mb30), mb40, "小于峰值不回退")
        XCTAssertEqual(TunnelMemoryPeakGuard.mergingPeak(mb30, sample: mb40), mb40, "大于峰值则抬高")
    }

    func testMergingPeakRefusesGarbageSample() {
        let peak: Int64 = 54 * 1024 * 1024
        // 写侧防护：哪怕再出一次 8.4GB 级别的病理读数，也不得并入峰值（读侧钳制的前置防线）
        XCTAssertEqual(TunnelMemoryPeakGuard.mergingPeak(peak, sample: 8_427_511_368), peak)
        XCTAssertEqual(TunnelMemoryPeakGuard.mergingPeak(peak, sample: TunnelMemoryPeakGuard.maxPlausiblePeakBytes + 1), peak)
        XCTAssertEqual(TunnelMemoryPeakGuard.mergingPeak(peak, sample: 0), peak, "非正样本（采样失败占位）不并入")
        XCTAssertEqual(TunnelMemoryPeakGuard.mergingPeak(peak, sample: -1), peak)
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
