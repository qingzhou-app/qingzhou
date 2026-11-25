import Foundation

enum XCStringsValidator {
    enum Issue: Equatable, CustomStringConvertible {
        case unexpectedSourceLanguage(expected: String, actual: String)
        case emptyCatalog
        case missingLocalization(key: String, language: String)
        case emptyLocalization(key: String, language: String)

        var description: String {
            switch self {
            case let .unexpectedSourceLanguage(expected, actual):
                return "unexpected sourceLanguage '\(actual)' (expected '\(expected)')"
            case .emptyCatalog:
                return "catalog contains no string entries"
            case let .missingLocalization(key, language):
                return "key '\(key)' missing '\(language)'"
            case let .emptyLocalization(key, language):
                return "key '\(key)' has empty '\(language)'"
            }
        }
    }

    struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct StringUnit: Decodable {
                    let state: String?
                    let value: String?
                }
                let stringUnit: StringUnit?
            }
            let shouldTranslate: Bool?
            let localizations: [String: Localization]?
        }
        let sourceLanguage: String
        let strings: [String: Entry]
    }

    static let requiredLanguages = ["en", "ja", "zh-Hant"]

    static func decode(data: Data) throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: data)
    }

    static func validate(
        data: Data,
        expectedSourceLanguage: String = "zh-Hans",
        requiredLanguages: [String] = XCStringsValidator.requiredLanguages
    ) throws -> (catalog: Catalog, issues: [Issue]) {
        let catalog = try decode(data: data)
        var issues: [Issue] = []

        if catalog.sourceLanguage != expectedSourceLanguage {
            issues.append(.unexpectedSourceLanguage(expected: expectedSourceLanguage, actual: catalog.sourceLanguage))
        }
        if catalog.strings.isEmpty {
            issues.append(.emptyCatalog)
        }

        for key in catalog.strings.keys.sorted() {
            guard let entry = catalog.strings[key], entry.shouldTranslate != false else {
                continue
            }
            for lang in requiredLanguages {
                guard let loc = entry.localizations?[lang], let value = loc.stringUnit?.value else {
                    issues.append(.missingLocalization(key: key, language: lang))
                    continue
                }
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.emptyLocalization(key: key, language: lang))
                }
            }
        }

        return (catalog, issues)
    }
}
