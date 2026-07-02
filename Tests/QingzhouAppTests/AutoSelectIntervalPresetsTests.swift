import XCTest
@testable import QingzhouApp

final class AutoSelectIntervalPresetsTests: XCTestCase {

    // MARK: 档位本身

    func testPresetsAreAscendingAndUnique() {
        let values = AutoSelectIntervalPresets.values
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(Set(values).count, values.count)
    }

    func testFallbackIsAPreset() {
        XCTAssertTrue(AutoSelectIntervalPresets.values.contains(AutoSelectIntervalPresets.fallback))
    }

    func testPresetValueMapsToItself() {
        for preset in AutoSelectIntervalPresets.values {
            XCTAssertEqual(AutoSelectIntervalPresets.nearest(to: preset), preset)
        }
    }

    // MARK: 旧值就近回退（旧 Stepper 是 60s 步进、60...86400 任意值）

    func testLegacyValuesSnapToNearestPreset() {
        // 旧值（秒）→ 期望档位（秒）
        let cases: [(TimeInterval, TimeInterval)] = [
            (60, 5 * 60),                 // 1 分钟 → 5 分钟（最小档）
            (7 * 60, 5 * 60),             // 7 分钟离 5 更近
            (11 * 60, 15 * 60),           // 11 分钟离 15 更近
            (20 * 60, 15 * 60),           // 20 分钟离 15 更近（差 5 vs 10）
            (25 * 60, 30 * 60),           // 25 分钟离 30 更近
            (45 * 60, 30 * 60),           // 45 分钟：与 30/60 等距 → 取较小档
            (50 * 60, 60 * 60),           // 50 分钟离 1 小时更近
            (3 * 60 * 60, 60 * 60),       // 3 小时离 1 小时更近（差 2h vs 3h）
            (10 * 60 * 60, 6 * 60 * 60),  // 10 小时离 6 小时更近
            (86400, 24 * 60 * 60),        // 旧上限 24 小时 → 原档
        ]
        for (legacy, expected) in cases {
            XCTAssertEqual(
                AutoSelectIntervalPresets.nearest(to: legacy), expected,
                "legacy \(Int(legacy))s 应吸附到 \(Int(expected))s"
            )
        }
    }

    func testTieBreaksToSmallerPreset() {
        // 45 分钟与 30 分钟、1 小时等距，取较小档
        XCTAssertEqual(AutoSelectIntervalPresets.nearest(to: 45 * 60), 30 * 60)
        // 10 分钟与 5/15 等距，取较小档
        XCTAssertEqual(AutoSelectIntervalPresets.nearest(to: 10 * 60), 5 * 60)
    }

    func testValuesBeyondRangeClampToBoundaryPresets() {
        XCTAssertEqual(AutoSelectIntervalPresets.nearest(to: 1), 5 * 60)
        XCTAssertEqual(AutoSelectIntervalPresets.nearest(to: 7 * 24 * 60 * 60), 24 * 60 * 60)
    }

    func testInvalidValuesFallBackToDefault() {
        XCTAssertEqual(AutoSelectIntervalPresets.nearest(to: 0), AutoSelectIntervalPresets.fallback)
        XCTAssertEqual(AutoSelectIntervalPresets.nearest(to: -60), AutoSelectIntervalPresets.fallback)
        XCTAssertEqual(AutoSelectIntervalPresets.nearest(to: .nan), AutoSelectIntervalPresets.fallback)
        XCTAssertEqual(AutoSelectIntervalPresets.nearest(to: .infinity), AutoSelectIntervalPresets.fallback)
        XCTAssertEqual(AutoSelectIntervalPresets.nearest(to: -.infinity), AutoSelectIntervalPresets.fallback)
    }
}
