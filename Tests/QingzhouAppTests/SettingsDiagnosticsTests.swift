import XCTest
@testable import QingzhouApp

/// 诊断区「上次采样」时间差的文案 —— 这行读数承担故障自诊断
/// （秒数持续增大 = 扩展没在写；「刚刚」但数字不动 = 不可能），格式钉住。
final class SettingsDiagnosticsTests: XCTestCase {

    func testAgeText() {
        XCTAssertEqual(SettingsView.ageText(0), "刚刚")
        XCTAssertEqual(SettingsView.ageText(1.5), "刚刚")
        XCTAssertEqual(SettingsView.ageText(-30), "刚刚", "时钟偏差出现负值时并进\"刚刚\"，不显示负数")
        XCTAssertEqual(SettingsView.ageText(2), "2 秒前")
        XCTAssertEqual(SettingsView.ageText(59.9), "59 秒前")
        XCTAssertEqual(SettingsView.ageText(60), "1 分钟前")
        XCTAssertEqual(SettingsView.ageText(3599), "59 分钟前")
        XCTAssertEqual(SettingsView.ageText(3600), "1 小时前")
        XCTAssertEqual(SettingsView.ageText(7300), "2 小时前")
    }
}
