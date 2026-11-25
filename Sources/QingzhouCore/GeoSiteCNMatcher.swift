import Foundation

/// 轻量的 `geosite:cn` 域名覆盖判定器，供主 App 对远程国内域名名单做前置去重，
/// 无需让 `QingzhouApp` 依赖 `XrayCore` 或打包 2 MB+ `geosite.dat`。
///
/// 数据来源：`Resources/geosite-cn.txt`（由 `scripts/extract-geosite-cn.py` 从
/// `Apps/Tunnel-Shared/Resources/geosite.dat` 的 `CN` 分类提取）。
/// 匹配语义对齐 xray-core geosite:cn：
/// - `full:`：精确主机名匹配
/// - `domain:`：精确匹配或其任意子域后缀匹配（含 42 个单标签顶级域如 `cn`、`alibaba`）
/// - `regexp:`：预编译正则匹配
public struct GeoSiteCNMatcher: Sendable {
    private struct CompiledRegex: @unchecked Sendable {
        let pattern: String
        let regex: NSRegularExpression
    }

    public let rootDomains: Set<String>
    public let fullDomains: Set<String>
    public let regexPatterns: [String]
    private let compiledRegexes: [CompiledRegex]

    public var entryCount: Int {
        rootDomains.count + fullDomains.count + regexPatterns.count
    }

    public static let empty = GeoSiteCNMatcher(rootDomains: [], fullDomains: [], regexPatterns: [])

    public static let bundled: GeoSiteCNMatcher = {
        guard let url = Bundle.module.url(forResource: "geosite-cn", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .empty
        }
        return GeoSiteCNMatcher(parsing: text)
    }()

    public init(
        rootDomains: Set<String> = [],
        fullDomains: Set<String> = [],
        regexPatterns: [String] = []
    ) {
        self.rootDomains = Set(
            rootDomains
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        self.fullDomains = Set(
            fullDomains
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        var patterns: [String] = []
        var compiled: [CompiledRegex] = []
        for raw in regexPatterns {
            let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            patterns.append(p)
            if let regex = try? NSRegularExpression(pattern: p) {
                compiled.append(CompiledRegex(pattern: p, regex: regex))
            }
        }
        self.regexPatterns = patterns
        self.compiledRegexes = compiled
    }

    public init(parsing text: String) {
        var roots = Set<String>()
        var fulls = Set<String>()
        var regexes: [String] = []

        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("domain:") {
                let value = String(line.dropFirst("domain:".count))
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                if !value.isEmpty { roots.insert(value) }
            } else if line.hasPrefix("full:") {
                let value = String(line.dropFirst("full:".count))
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                if !value.isEmpty { fulls.insert(value) }
            } else if line.hasPrefix("regexp:") {
                let pattern = String(line.dropFirst("regexp:".count))
                    .trimmingCharacters(in: .whitespaces)
                if !pattern.isEmpty { regexes.append(pattern) }
            }
        }

        self.init(rootDomains: roots, fullDomains: fulls, regexPatterns: regexes)
    }

    /// 判断给定域名（或 `+.` / `*.` 后缀规则值）是否已被内置 `geosite:cn` 覆盖。
    public func isCovered(_ domain: String) -> Bool {
        var d = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if d.hasPrefix("+.") || d.hasPrefix("*.") {
            d.removeFirst(2)
        }
        while d.hasSuffix(".") {
            d.removeLast()
        }
        guard !d.isEmpty, !d.contains(":"), !d.contains(where: \.isWhitespace) else {
            return false
        }
        let labels = d.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty }),
              !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            return false
        }

        if fullDomains.contains(d) {
            return true
        }
        if rootDomains.contains(d) {
            return true
        }
        var searchStart = d.startIndex
        while let dot = d[searchStart...].firstIndex(of: ".") {
            let next = d.index(after: dot)
            if next < d.endIndex, rootDomains.contains(String(d[next...])) {
                return true
            }
            searchStart = next
        }
        if !compiledRegexes.isEmpty {
            let nsRange = NSRange(d.startIndex..<d.endIndex, in: d)
            for entry in compiledRegexes {
                if entry.regex.firstMatch(in: d, range: nsRange) != nil {
                    return true
                }
            }
        }
        return false
    }
}
