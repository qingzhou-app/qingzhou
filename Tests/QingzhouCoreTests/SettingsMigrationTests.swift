import XCTest
@testable import QingzhouCore

/// Settings 的 Codable 解码必须容忍旧版本（字段缺失），给默认值。
/// 这点对持久化是刚性需求：用户升级 app 时不能因为新字段把旧 JSON 全报废。
final class SettingsMigrationTests: XCTestCase {

    private func decode(_ json: String) throws -> Settings {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(Settings.self, from: data)
    }

    func testDecodeEmptyJSONUsesDefaults() throws {
        let s = try decode("{}")
        XCTAssertEqual(s.proxyMode, .rule)
        XCTAssertEqual(s.subscriptionRefreshIntervalSeconds, 3600)
        XCTAssertEqual(s.theme, .system)
    }

    func testDecodeOldSnapshotWithRemovedFields() throws {
        // 旧 settings.json 里可能还残留已移除的 httpPort/socksPort/systemProxyEnabled，
        // 解码应当忽略它们、不崩。
        let json = """
        {
          "proxyMode": "global",
          "autoSelectTrigger": "off",
          "autoSelectIntervalSeconds": 600,
          "nodeSortOrder": "name",
          "systemProxyEnabled": false,
          "launchAtLogin": false,
          "httpPort": 8888,
          "socksPort": 1080,
          "logLevel": "WARN",
          "theme": "dark",
          "language": "en"
        }
        """
        let s = try decode(json)
        XCTAssertEqual(s.proxyMode, .global)
        XCTAssertEqual(s.theme, .dark)
        XCTAssertEqual(s.language, .en)
        XCTAssertEqual(s.subscriptionRefreshIntervalSeconds, 3600)
    }

    func testRoundtripPreservesNewField() throws {
        var s = Settings()
        s.subscriptionRefreshIntervalSeconds = 900
        let data = try JSONEncoder().encode(s)
        let reloaded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(reloaded.subscriptionRefreshIntervalSeconds, 900)
    }

    func testZeroIntervalMeansOff() throws {
        var s = Settings()
        s.subscriptionRefreshIntervalSeconds = 0
        XCTAssertEqual(s.subscriptionRefreshIntervalSeconds, 0)
    }

    // MARK: - autoMeasureIntervalSeconds (S7 Phase 1)

    /// 新加字段，旧 JSON 里不会有 —— 解码必须给默认值（30 分钟），不能崩。
    func testDecodeWithoutAutoMeasureUsesDefault() throws {
        // 上面 testDecodeOldSnapshotWithoutNewFields 那段 JSON 故意没 autoMeasureIntervalSeconds
        let json = """
        {
          "proxyMode": "global",
          "autoSelectTrigger": "off",
          "subscriptionRefreshIntervalSeconds": 1800,
          "nodeSortOrder": "name",
          "httpPort": 8888,
          "socksPort": 1080
        }
        """
        let s = try decode(json)
        XCTAssertEqual(s.autoMeasureIntervalSeconds, 30 * 60)
    }

    func testAutoMeasureRoundtripsZero() throws {
        var s = Settings()
        s.autoMeasureIntervalSeconds = 0
        let data = try JSONEncoder().encode(s)
        let reloaded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(reloaded.autoMeasureIntervalSeconds, 0)
    }

    func testAutoMeasureRoundtripsCustom() throws {
        var s = Settings()
        s.autoMeasureIntervalSeconds = 15 * 60
        let data = try JSONEncoder().encode(s)
        let reloaded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(reloaded.autoMeasureIntervalSeconds, 15 * 60)
    }
}
