import XCTest
import QingzhouCore
@testable import QingzhouApp

final class LocalizationTests: XCTestCase {
    func testSectionTitlesSwitchLanguageWithoutChangingGlobalLanguage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        for (language, title) in [("en", "Home"), ("zh-Hans", "首页")] {
            let directory = root.appendingPathComponent(language + ".lproj")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "\"首页\" = \"\(title)\";".write(to: directory.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        let bundle = try XCTUnwrap(Bundle(path: root.path))
        XCTAssertEqual(AppSection.home.localizedTitle(language: .en, bundle: bundle), "Home")
        XCTAssertEqual(AppSection.home.localizedTitle(language: .zhHans, bundle: bundle), "首页")
        XCTAssertEqual(AppSection.home.localizedTitle(language: .en, bundle: bundle), "Home")
        XCTAssertEqual(AppSection.nodes.localizedTitle(language: .en, bundle: bundle), "节点")
    }

    func testSystemUsesAutoupdatingCurrent() {
        let locale = LocaleResolver.locale(for: .system)
        // autoupdatingCurrent 的 identifier 与系统当前一致
        XCTAssertEqual(locale.identifier, Locale.autoupdatingCurrent.identifier)
    }

    func testFixedLanguagesMapToCorrectIdentifiers() {
        XCTAssertEqual(LocaleResolver.locale(for: .zhHans).identifier, "zh-Hans")
        XCTAssertEqual(LocaleResolver.locale(for: .zhHant).identifier, "zh-Hant")
        XCTAssertEqual(LocaleResolver.locale(for: .en).identifier, "en")
        XCTAssertEqual(LocaleResolver.locale(for: .ja).identifier, "ja")
    }

    func testJaLocaleFormatsDatesInJapanese() {
        let locale = LocaleResolver.locale(for: .ja)
        let date = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01 UTC
        let formatted = date.formatted(.dateTime.year().month(.wide).locale(locale))
        // 月份的日文写法包含「月」
        XCTAssertTrue(formatted.contains("月"), "got: \(formatted)")
    }

    func testEnLocaleFormatsDatesInEnglish() {
        let locale = LocaleResolver.locale(for: .en)
        let date = Date(timeIntervalSince1970: 1_704_067_200)
        let formatted = date.formatted(.dateTime.month(.wide).locale(locale))
        // 英文月名
        XCTAssertTrue(
            ["January", "December"].contains(where: { formatted.contains($0) }),
            "got: \(formatted)"
        )
    }
}
