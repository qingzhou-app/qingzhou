import XCTest
@testable import QingzhouApp

final class AutoStopPresetsTests: XCTestCase {

    // MARK: 档位本身

    func testPresetsAreAscendingAndUnique() {
        let values = AutoStopPresets.values
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(Set(values).count, values.count)
    }

    func testContainsOffAndStandardTiers() {
        let values = AutoStopPresets.values
        XCTAssertTrue(values.contains(0), "必须有「关闭」档")
        XCTAssertTrue(values.contains(30 * 60))
        XCTAssertTrue(values.contains(60 * 60))
        XCTAssertTrue(values.contains(2 * 60 * 60))
        XCTAssertTrue(values.contains(4 * 60 * 60))
    }

    #if DEBUG
    func testDebugTierPresentInDebugBuilds() {
        XCTAssertTrue(AutoStopPresets.values.contains(60), "DEBUG 构建应有 1 分钟调试档")
    }
    #endif

    func testPresetValueMapsToItself() {
        for preset in AutoStopPresets.values {
            XCTAssertEqual(AutoStopPresets.nearest(to: preset), preset)
        }
    }

    func testInvalidValuesSnapToOff() {
        XCTAssertEqual(AutoStopPresets.nearest(to: -1), 0)
        XCTAssertEqual(AutoStopPresets.nearest(to: 0), 0)
        XCTAssertEqual(AutoStopPresets.nearest(to: .nan), 0)
        XCTAssertEqual(AutoStopPresets.nearest(to: .infinity), 0)
    }

    func testArbitraryValuesSnapToNearest() {
        // iCloud 同步 / 手改 JSON 可能带来任意值，就近吸附
        XCTAssertEqual(AutoStopPresets.nearest(to: 2000), 30 * 60)       // 33 分钟 → 30 分钟
        XCTAssertEqual(AutoStopPresets.nearest(to: 50 * 60), 60 * 60)    // 50 分钟 → 1 小时
        XCTAssertEqual(AutoStopPresets.nearest(to: 3 * 60 * 60), 2 * 60 * 60) // 差相同取较小档
        XCTAssertEqual(AutoStopPresets.nearest(to: 100 * 60 * 60), 4 * 60 * 60) // 超上限 → 最大档
    }

    // MARK: 档位文案（toast / picker 共用）

    func testLabels() {
        XCTAssertEqual(AutoStopPresets.label(for: 0), "关闭")
        XCTAssertEqual(AutoStopPresets.label(for: 60), "1 分钟")
        XCTAssertEqual(AutoStopPresets.label(for: 30 * 60), "30 分钟")
        XCTAssertEqual(AutoStopPresets.label(for: 60 * 60), "1 小时")
        XCTAssertEqual(AutoStopPresets.label(for: 4 * 60 * 60), "4 小时")
    }

    // MARK: 剩余时间文案（<1h → mm:ss；≥1h → h:mm）

    func testRemainingTextUnderOneHourIsMinutesSeconds() {
        let now = Date()
        XCTAssertEqual(AutoStopPresets.remainingText(until: now.addingTimeInterval(29 * 60 + 59), now: now), "29:59")
        XCTAssertEqual(AutoStopPresets.remainingText(until: now.addingTimeInterval(5 * 60), now: now), "5:00")
        XCTAssertEqual(AutoStopPresets.remainingText(until: now.addingTimeInterval(42), now: now), "0:42")
        XCTAssertEqual(AutoStopPresets.remainingText(until: now.addingTimeInterval(9), now: now), "0:09")
    }

    func testRemainingTextAtOrAboveOneHourIsHoursMinutes() {
        let now = Date()
        XCTAssertEqual(AutoStopPresets.remainingText(until: now.addingTimeInterval(3600), now: now), "1:00")
        XCTAssertEqual(AutoStopPresets.remainingText(until: now.addingTimeInterval(2 * 3600), now: now), "2:00")
        XCTAssertEqual(AutoStopPresets.remainingText(until: now.addingTimeInterval(3600 + 59 * 60), now: now), "1:59")
        XCTAssertEqual(AutoStopPresets.remainingText(until: now.addingTimeInterval(4 * 3600 - 1), now: now), "3:59")
    }

    func testRemainingTextClampsAtZero() {
        let now = Date()
        XCTAssertEqual(AutoStopPresets.remainingText(until: now, now: now), "0:00")
        XCTAssertEqual(AutoStopPresets.remainingText(until: now.addingTimeInterval(-30), now: now), "0:00")
    }

    func testRemainingTextRoundsPartialSecondsUp() {
        let now = Date()
        // 剩 0.4 秒不该显示 0:00（还没到点），进位到 0:01
        XCTAssertEqual(AutoStopPresets.remainingText(until: now.addingTimeInterval(0.4), now: now), "0:01")
    }
}
