import XCTest
import QingzhouCore
@testable import QingzhouApp

/// 「跟随出口地区」的推导逻辑。
///
/// 这块最容易做错的地方是**过度承诺**：语言映射要保守（拿不准就不动），
/// 时区命令要能直接用，不能给一条会在用户机器上失败的字符串。
final class ExitRegionProfileTests: XCTestCase {

    func testSummaryCombinesPlaceAndTimeZone() {
        let r = ExitRegionProfile(countryCode: "SG", country: "Singapore", city: "Singapore",
                                  timezoneID: "Asia/Singapore")
        XCTAssertEqual(r.summary, "Singapore · Singapore · Asia/Singapore")
    }

    func testSummaryFallsBackWhenNoPlace() {
        let r = ExitRegionProfile(timezoneID: "Asia/Tokyo")
        XCTAssertEqual(r.summary, "Asia/Tokyo")
    }

    func testTimeZoneResolves() {
        let r = ExitRegionProfile(timezoneID: "Europe/London")
        XCTAssertEqual(r.timeZone?.identifier, "Europe/London")
        XCTAssertNil(ExitRegionProfile(timezoneID: "Not/AZone").timeZone)
    }

    // MARK: - 语言映射

    func testLanguageMappingCoveredCases() {
        XCTAssertEqual(ExitRegionProfile(countryCode: "CN").suggestedLanguage, .zhHans)
        XCTAssertEqual(ExitRegionProfile(countryCode: "TW").suggestedLanguage, .zhHant)
        XCTAssertEqual(ExitRegionProfile(countryCode: "HK").suggestedLanguage, .zhHant)
        XCTAssertEqual(ExitRegionProfile(countryCode: "JP").suggestedLanguage, .ja)
        XCTAssertEqual(ExitRegionProfile(countryCode: "GB").suggestedLanguage, .en)
        XCTAssertEqual(ExitRegionProfile(countryCode: "sg").suggestedLanguage, .en, "大小写不该影响")
    }

    /// 没有把握的地区返回 nil —— 让界面保持用户原来的语言，而不是猜一个。
    func testLanguageMappingLeavesUnknownAlone() {
        for code in ["DE", "FR", "RU", "BR", "ZZ", ""] {
            XCTAssertNil(ExitRegionProfile(countryCode: code).suggestedLanguage, code)
        }
        XCTAssertNil(ExitRegionProfile().suggestedLanguage)
    }

    // MARK: - 系统时区命令

    func testSystemTimeZoneCommandIsRunnable() {
        let r = ExitRegionProfile(timezoneID: "Asia/Singapore")
        XCTAssertEqual(r.systemTimeZoneCommand(), "sudo systemsetup -settimezone Asia/Singapore")
    }

    func testSystemTimeZoneCommandNilForBadZone() {
        XCTAssertNil(ExitRegionProfile(timezoneID: "Mars/Olympus").systemTimeZoneCommand())
        XCTAssertNil(ExitRegionProfile().systemTimeZoneCommand())
    }

    // MARK: - PublicIPInfo 接线

    func testPublicIPInfoExposesExitRegion() {
        let info = PublicIPInfo(ip: "1.2.3.4", country: "Japan", city: "Tokyo",
                                countryCode: "JP", timezoneID: "Asia/Tokyo",
                                latitude: 35.6, longitude: 139.7)
        let region = info.exitRegion
        XCTAssertEqual(region.countryCode, "JP")
        XCTAssertEqual(region.timezoneID, "Asia/Tokyo")
        XCTAssertEqual(region.latitude, 35.6)
        XCTAssertEqual(region.suggestedLanguage, .ja)
    }

    /// 老存档没有这些字段，解码不能失败（否则历史 IP 记录会让整个快照读不出来）。
    func testPublicIPInfoDecodesLegacyPayload() throws {
        let json = #"{"ip":"1.2.3.4","fetchedAt":"2026-11-24T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let info = try decoder.decode(PublicIPInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.ip, "1.2.3.4")
        XCTAssertNil(info.timezoneID)
        XCTAssertNil(info.exitRegion.timeZone)
    }
}
