import XCTest
import QingzhouCore
import QingzhouLogging
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

    func testAllXCStringsHaveCompleteFourLanguageTranslations() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // QingzhouAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let xcstringsRelativePaths = [
            "Apps/App-Shared/Localizable.xcstrings",
            "Apps/App-Shared/AppShortcuts.xcstrings",
            "Apps/App-Shared/InfoPlist.xcstrings",
            "Apps/Tunnel-Shared/Localizable.xcstrings",
            "Apps/Widget-Shared/Localizable.xcstrings",
        ]

        struct Catalog: Decodable {
            struct Entry: Decodable {
                struct Loc: Decodable {
                    struct StringUnit: Decodable {
                        let state: String?
                        let value: String?
                    }
                    let stringUnit: StringUnit?
                }
                let shouldTranslate: Bool?
                let localizations: [String: Loc]?
            }
            let sourceLanguage: String
            let strings: [String: Entry]
        }

        let requiredLanguages = ["en", "ja", "zh-Hant"]
        let decoder = JSONDecoder()
        for rel in xcstringsRelativePaths {
            let fileURL = repoRoot.appendingPathComponent(rel)
            let data = try Data(contentsOf: fileURL)
            let catalog = try decoder.decode(Catalog.self, from: data)
            XCTAssertEqual(catalog.sourceLanguage, "zh-Hans", "\(rel) sourceLanguage")
            XCTAssertFalse(catalog.strings.isEmpty, "\(rel) should not be empty")

            for (key, entry) in catalog.strings {
                if entry.shouldTranslate == false { continue }
                let locs = entry.localizations ?? [:]
                for lang in requiredLanguages {
                    let value = locs[lang]?.stringUnit?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    XCTAssertFalse(value.isEmpty, "\(rel) key \"\(key)\" is missing non-empty '\(lang)' translation")
                }
            }
        }
    }

    func testM2UIKeysExistInLocalizableXCStrings() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // QingzhouAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root

        struct Catalog: Decodable {
            struct Entry: Decodable {
                struct Loc: Decodable {
                    struct StringUnit: Decodable { let value: String? }
                    let stringUnit: StringUnit?
                }
                let localizations: [String: Loc]?
            }
            let strings: [String: Entry]
        }

        let catalogURL = repoRoot.appendingPathComponent("Apps/App-Shared/Localizable.xcstrings")
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))

        // 1) M2 核心界面与辅助类显式引用键（含动态插值与枚举分支）
        let requiredKeys = [
            "网段", "域名", "关键字", "更新中…", "更新名单", "这一类是空的", "无匹配",
            "未知时区", "无法写入 App Group 共享目录", "已复制",
            "%lld / 源 %lld", "已显示 %lld / %lld 条", "%lld 条",
            "国内名单：%@ 域名 / %@ 网段（%@）", "国内名单不可用：%@",
            "国内名单尚未下载，当前只用内置 geosite/geoip",
            "%@：响应为空或非 UTF-8",
            "解析结果为空（域名 %lld 条 / IP %lld 条），已保留上一份",
            "写入失败：%@", "写入后回读校验失败，已保留上一份", "；",
            "名单源配置错误（需要域名与 IP 两份）",
            "「%@」需下载完整版 geo 数据后才会生效（内置精简版仅含 cn / private）",
            "「%@」不在内置 geosite 分类白名单里，这条规则会被跳过。",
            "全部显示（%lld 条，可能卡顿）",
            "出口地区：%@",
            "界面语言 → %@（仅连接期间生效，不改你的语言设置）",
            "系统时区将自动切换为 %@（由 guard 执行，断开 VPN 自动还原）。",
            "已开启「经 root 中继出网」，但读不到中继凭据。先安装 guard：sudo sh Tools/qingzhou-guard/install.sh",
            "关闭来源 App 标注", "启用来源 App 标注",
            "暂无自定义规则", "无匹配规则", "尚未加载远程规则",
            "no-resolve（不触发本地 DNS 解析）",
            "xray 隧道无单条 no-resolve 开关，规则模式全局使用 IPIfNonMatch。",
            "PROCESS-NAME 仅用于本机规则模拟与命中归因，xray TUN 隧道不匹配进程名。",
            "USER-AGENT 仅用于本机规则模拟，xray TUN 隧道无法匹配 HTTP User-Agent。",
            "仅本机规则模拟生效，xray TUN 隧道不匹配进程名",
            "仅本机规则模拟生效，xray TUN 隧道不匹配 User-Agent",
            "含 no-resolve（xray 隧道无单条开关，规则模式按 IPIfNonMatch 处理）",
            "不在内置 geosite 分类白名单里，xray 隧道将跳过此规则",
            "进程名（仅 macOS）",
        ]

        let langs = ["en", "ja", "zh-Hant"]
        for key in requiredKeys {
            let entry = catalog.strings[key]
            XCTAssertNotNil(entry, "Localizable.xcstrings missing M2 key: \"\(key)\"")
            for lang in langs {
                let v = entry?.localizations?[lang]?.stringUnit?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                XCTAssertFalse(v.isEmpty, "Key \"\(key)\" missing '\(lang)' translation")
            }
        }

        // 2) 静态扫描 M2 UI/辅助源码里的无插值中文字符串字面量（排除注释与语言原生自称）
        let scannedFiles = [
            "Sources/QingzhouApp/SplitExitListsView.swift",
            "Sources/QingzhouApp/RulesView.swift",
            "Sources/QingzhouApp/SettingsView.swift",
            "Sources/QingzhouApp/SplitExitListsUpdater.swift",
            "Sources/QingzhouApp/Localization.swift",
        ]
        let intentionalNonTranslated: Set<String> = ["简体中文", "繁體中文", "日本語"]
        let literalRegex = try NSRegularExpression(pattern: #""([^"\\]*(?:\\.[^"\\]*)*)""#)
        let hanRegex = try NSRegularExpression(pattern: #"\p{Han}"#)

        for rel in scannedFiles {
            let content = try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)
            for (idx, rawLine) in content.components(separatedBy: .newlines).enumerated() {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("logger.") { continue }
                let nsLine = rawLine as NSString
                let matches = literalRegex.matches(in: rawLine, range: NSRange(location: 0, length: nsLine.length))
                for match in matches {
                    let literal = nsLine.substring(with: match.range(at: 1))
                    if literal.contains(#"\("#) || intentionalNonTranslated.contains(literal) { continue }
                    let nsLit = literal as NSString
                    guard hanRegex.firstMatch(in: literal, range: NSRange(location: 0, length: nsLit.length)) != nil else { continue }
                    XCTAssertNotNil(
                        catalog.strings[literal],
                        "\(rel):\(idx + 1) uninterpolated Chinese literal \"\(literal)\" missing from Localizable.xcstrings"
                    )
                }
            }
        }
    }

    @MainActor
    func testAppStateInitPreservesAllFourSupportedLanguagesAndMigratesSystem() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = Persistence(directory: dir)
        let logger = Logger(capacity: 50, minimumLevel: .error)

        for lang in [AppLanguage.zhHans, .zhHant, .en, .ja] {
            var settings = Settings()
            settings.language = lang
            settings.iCloudSyncEnabled = false
            let snap = Persistence.Snapshot(subscriptions: [], nodes: [], customRules: [], settings: settings, currentNodeId: nil)
            try persistence.saveSnapshot(snap)

            let state = AppState(logger: logger, persistence: persistence)
            XCTAssertEqual(state.settings.language, lang, "AppState.init 不得覆盖受支持语种 \(lang.rawValue)")
            XCTAssertEqual(state.effectiveLanguage, lang)
        }

        // 已下架的 .system 仍应一次性迁移到 .zhHans（SettingsView Picker 仅列出 4 个固定语种）
        var legacySettings = Settings()
        legacySettings.language = .system
        legacySettings.iCloudSyncEnabled = false
        try persistence.saveSnapshot(Persistence.Snapshot(subscriptions: [], nodes: [], customRules: [], settings: legacySettings, currentNodeId: nil))
        let migrated = AppState(logger: logger, persistence: persistence)
        XCTAssertEqual(migrated.settings.language, .zhHans)
    }
}
