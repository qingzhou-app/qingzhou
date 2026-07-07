import XCTest
@testable import QingzhouCore

/// 「源端口 → 来源 App」映射的解析与时间窗匹配（macOS content filter 标注管线的纯逻辑部分）。
/// XPC 线上格式是 [String: String]：值为 "bundleID"（旧扩展）或 "bundleID\t<unix秒>"（新扩展）。
/// 带时间戳的条目要求 |seenAt − openedAt| ≤ 窗口才认领 —— 端口被系统回收复用给别的 App 时,
/// 老连接（openedAt 远早于新 flow 的 seenAt）不再被误标。
final class SourceAppMapTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_751_900_000)

    func testLegacyValueWithoutTimestampMatchesAnyOpenedAt() {
        let map = SourceAppMap(raw: ["50000": "com.apple.Safari"])
        // 旧扩展没有时间戳 → 退回纯端口匹配（原有行为），连接多老都认
        XCTAssertEqual(map.bundleID(forPort: "50000", openedAt: t0), "com.apple.Safari")
        XCTAssertEqual(map.bundleID(forPort: "50000", openedAt: t0.addingTimeInterval(-3600)), "com.apple.Safari")
        XCTAssertNil(map.bundleID(forPort: "50001", openedAt: t0))
    }

    func testTimestampedValueMatchesWithinWindow() {
        // flow 在 t0 被 filter 观测；连接在 t0+2s 被 ingest（轮询滞后）→ 认领
        let map = SourceAppMap(raw: ["50000": "com.apple.Safari\t1751900000"])
        XCTAssertEqual(map.bundleID(forPort: "50000", openedAt: t0.addingTimeInterval(2)), "com.apple.Safari")
        // 时钟粒度导致 seenAt 略晚于 openedAt 也认（窗口对称）
        XCTAssertEqual(map.bundleID(forPort: "50000", openedAt: t0.addingTimeInterval(-2)), "com.apple.Safari")
    }

    func testTimestampedValueRejectsPortReuse() {
        // 端口复用场景：老连接 openedAt 在 1 小时前，新 flow（别的 App）刚被观测 → 不认领
        let map = SourceAppMap(raw: ["50000": "com.tencent.WeChat\t1751900000"])
        XCTAssertNil(map.bundleID(forPort: "50000", openedAt: t0.addingTimeInterval(-3600)))
        XCTAssertNil(map.bundleID(forPort: "50000", openedAt: t0.addingTimeInterval(3600)))
    }

    func testWindowBoundaryIsInclusive() {
        let map = SourceAppMap(raw: ["50000": "com.apple.Safari\t1751900000"])
        XCTAssertEqual(
            map.bundleID(forPort: "50000", openedAt: t0.addingTimeInterval(SourceAppMap.matchWindow)),
            "com.apple.Safari"
        )
        XCTAssertNil(
            map.bundleID(forPort: "50000", openedAt: t0.addingTimeInterval(SourceAppMap.matchWindow + 1))
        )
    }

    func testMalformedTimestampFallsBackToLegacyMatch() {
        // 时间戳解析不了 → 按旧格式对待（宁可保留原有行为也不丢标注）
        let map = SourceAppMap(raw: ["50000": "com.apple.Safari\tnot-a-number"])
        XCTAssertEqual(map.bundleID(forPort: "50000", openedAt: t0.addingTimeInterval(-3600)), "com.apple.Safari")
    }

    func testIsEmpty() {
        XCTAssertTrue(SourceAppMap().isEmpty)
        XCTAssertTrue(SourceAppMap(raw: [:]).isEmpty)
        XCTAssertFalse(SourceAppMap(raw: ["1": "a"]).isEmpty)
    }

    // MARK: - 同端口多条记录（15s 内两个 App 先后复用同端口的场景）

    func testTwoAppsReusingSamePortResolveByNearestTimestamp() {
        // 旧 App 在 t0 建连、新 App 在 t0+10s 复用同端口，两条都在窗口内 → 按时间最近邻认领
        let map = SourceAppMap(raw: ["50000": "com.old.app\t1751900000\ncom.new.app\t1751900010"])
        XCTAssertEqual(map.bundleID(forPort: "50000", openedAt: t0.addingTimeInterval(1)), "com.old.app")
        XCTAssertEqual(map.bundleID(forPort: "50000", openedAt: t0.addingTimeInterval(9)), "com.new.app")
    }

    func testMultiEntryStillRejectsWhenAllOutsideWindow() {
        let map = SourceAppMap(raw: ["50000": "com.a.app\t1751900000\ncom.b.app\t1751900010"])
        XCTAssertNil(map.bundleID(forPort: "50000", openedAt: t0.addingTimeInterval(-3600)))
    }

    func testLegacyEntryOnlyUsedWhenNoTimestampedEntryMatches() {
        // 混合值：带时间戳的条目窗口内命中 → 优先；全部超窗 → 退回无时间戳条目（旧扩展兼容语义）
        let map = SourceAppMap(raw: ["50000": "com.legacy.app\ncom.new.app\t1751900000"])
        XCTAssertEqual(map.bundleID(forPort: "50000", openedAt: t0.addingTimeInterval(2)), "com.new.app")
        XCTAssertEqual(map.bundleID(forPort: "50000", openedAt: t0.addingTimeInterval(-3600)), "com.legacy.app")
    }
}
