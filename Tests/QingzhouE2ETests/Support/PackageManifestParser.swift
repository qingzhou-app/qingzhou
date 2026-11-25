import Foundation

enum PackageManifestParser {
    enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case missingPackageCall
        case missingTargetsArray
        case targetNotFound(String)

        var description: String {
            switch self {
            case .missingPackageCall:
                return "Package(...) call with targets: [...] not found"
            case .missingTargetsArray:
                return "targets: [...] array not found in Package(...)"
            case let .targetNotFound(name):
                return "target '\(name)' not found in targets array"
            }
        }
    }

    enum Dependency: Equatable, Sendable {
        case byName(String)
        case target(name: String)
        case product(name: String, package: String?)
        case unknown(raw: String)

        var resolvedName: String? {
            switch self {
            case let .byName(name), let .target(name), let .product(name, _):
                return name
            case .unknown:
                return nil
            }
        }
    }

    struct Target: Equatable, Sendable {
        let kind: String
        let name: String
        let dependencies: [Dependency]

        var resolvedDependencyNames: [String] {
            dependencies.compactMap(\.resolvedName)
        }

        var unresolvedDependencies: [String] {
            dependencies.compactMap { dep in
                if case let .unknown(raw) = dep { return raw }
                return nil
            }
        }
    }

    struct Manifest: Equatable, Sendable {
        let targets: [Target]

        func target(named name: String, kind: String? = nil) -> Target? {
            targets.first { $0.name == name && (kind == nil || $0.kind == kind) }
        }

        func transitiveDependencyNames(of targetName: String) throws -> Set<String> {
            guard let root = target(named: targetName) else {
                throw ParseError.targetNotFound(targetName)
            }
            let byName = Dictionary(targets.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            var visitedTargets: Set<String> = [root.name]
            var reachable: Set<String> = []
            var queue = root.resolvedDependencyNames
            while let dep = queue.popLast() {
                reachable.insert(dep)
                if let next = byName[dep], visitedTargets.insert(next.name).inserted {
                    queue.append(contentsOf: next.resolvedDependencyNames)
                }
            }
            return reachable
        }
    }

    enum Token: Equatable, Sendable {
        case lparen
        case rparen
        case lbracket
        case rbracket
        case lbrace
        case rbrace
        case colon
        case comma
        case dot
        case identifier(String)
        case string(String)
        case other(String)
    }

    static func parse(_ source: String) throws -> Manifest {
        let tokens = tokenize(source)
        let packageInners = findPackageCalls(in: tokens)
        guard !packageInners.isEmpty else {
            throw ParseError.missingPackageCall
        }

        var targetsArrayInner: ArraySlice<Token>?
        for inner in packageInners {
            let args = splitTopLevelArgs(inner).map(parseLabeledArg)
            if let targetsArg = args.first(where: { $0.label == "targets" }),
               targetsArg.value.first == .lbracket {
                let valueTokens = Array(targetsArg.value)
                if let extracted = extractBalanced(tokens: valueTokens, openIndex: 0),
                   extracted.endIndex == valueTokens.count - 1 {
                    targetsArrayInner = extracted.inner
                    break
                }
            }
        }

        guard let targetsInner = targetsArrayInner else {
            throw ParseError.missingTargetsArray
        }

        let targetElements = splitTopLevelArgs(targetsInner)
        var parsedTargets: [Target] = []
        for elem in targetElements {
            if let target = parseTarget(elem) {
                parsedTargets.append(target)
            }
        }
        return Manifest(targets: parsedTargets)
    }

    /// Strips `//` line comments and nested `/* ... */` block comments outside Swift string literals,
    /// replacing block comments with a single space to avoid merging adjacent identifiers.
    static func strippingComments(_ source: String) -> String {
        let chars = Array(source)
        let count = chars.count
        var out = String()
        out.reserveCapacity(count)
        var i = 0

        while i < count {
            // Line comment
            if chars[i] == "/", i + 1 < count, chars[i + 1] == "/" {
                i += 2
                while i < count, !chars[i].isNewline {
                    i += 1
                }
                continue
            }

            // Nested block comment
            if chars[i] == "/", i + 1 < count, chars[i + 1] == "*" {
                i = skipBlockComment(chars, from: i)
                out.append(" ")
                continue
            }

            // Raw or regular string literal
            if let (_, nextIndex) = scanStringLiteral(chars, from: i) {
                out.append(contentsOf: chars[i..<nextIndex])
                i = nextIndex
                continue
            }

            out.append(chars[i])
            i += 1
        }
        return out
    }

    // MARK: - Lexer

    static func tokenize(_ source: String) -> [Token] {
        let chars = Array(source)
        let count = chars.count
        var tokens: [Token] = []
        var i = 0

        while i < count {
            let ch = chars[i]

            if ch.isWhitespace {
                i += 1
                continue
            }

            // Line comment
            if ch == "/", i + 1 < count, chars[i + 1] == "/" {
                i += 2
                while i < count, !chars[i].isNewline {
                    i += 1
                }
                continue
            }

            // Nested block comment
            if ch == "/", i + 1 < count, chars[i + 1] == "*" {
                i = skipBlockComment(chars, from: i)
                continue
            }

            // String literal (including raw #"..."# / #"""..."""# and multiline """...""")
            if let (value, nextIndex) = scanStringLiteral(chars, from: i) {
                tokens.append(.string(value))
                i = nextIndex
                continue
            }

            // Backticked identifier
            if ch == "`" {
                var j = i + 1
                while j < count, chars[j] != "`", !chars[j].isNewline {
                    j += 1
                }
                if j < count, chars[j] == "`" {
                    tokens.append(.identifier(String(chars[(i + 1)..<j])))
                    i = j + 1
                    continue
                }
            }

            // Identifier
            if isIdentifierStart(ch) {
                var j = i + 1
                while j < count, isIdentifierContinue(chars[j]) {
                    j += 1
                }
                tokens.append(.identifier(String(chars[i..<j])))
                i = j
                continue
            }

            switch ch {
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            case "[": tokens.append(.lbracket)
            case "]": tokens.append(.rbracket)
            case "{": tokens.append(.lbrace)
            case "}": tokens.append(.rbrace)
            case ":": tokens.append(.colon)
            case ",": tokens.append(.comma)
            case ".": tokens.append(.dot)
            default: tokens.append(.other(String(ch)))
            }
            i += 1
        }

        return tokens
    }

    private static func isIdentifierStart(_ ch: Character) -> Bool {
        ch == "_" || ch.isLetter
    }

    private static func isIdentifierContinue(_ ch: Character) -> Bool {
        ch == "_" || ch.isLetter || ch.isNumber
    }

    private static func skipBlockComment(_ chars: [Character], from start: Int) -> Int {
        let count = chars.count
        var i = start + 2
        var depth = 1
        while i < count, depth > 0 {
            if chars[i] == "/", i + 1 < count, chars[i + 1] == "*" {
                depth += 1
                i += 2
            } else if chars[i] == "*", i + 1 < count, chars[i + 1] == "/" {
                depth -= 1
                i += 2
            } else {
                i += 1
            }
        }
        return i
    }

    private static func scanStringLiteral(_ chars: [Character], from start: Int) -> (value: String, nextIndex: Int)? {
        let count = chars.count
        var hashCount = 0
        while start + hashCount < count, chars[start + hashCount] == "#" {
            hashCount += 1
        }
        let quoteStart = start + hashCount
        guard quoteStart < count, chars[quoteStart] == "\"" else {
            return nil
        }

        let isMultiline = quoteStart + 2 < count
            && chars[quoteStart + 1] == "\""
            && chars[quoteStart + 2] == "\""
        var i = quoteStart + (isMultiline ? 3 : 1)
        var value = ""

        while i < count {
            // Check closing delimiter
            if isMultiline {
                if i + 2 + hashCount < count,
                   chars[i] == "\"",
                   chars[i + 1] == "\"",
                   chars[i + 2] == "\"",
                   hasHashes(chars, at: i + 3, count: hashCount) {
                    return (value, i + 3 + hashCount)
                }
            } else {
                if chars[i] == "\"",
                   i + hashCount < count,
                   hasHashes(chars, at: i + 1, count: hashCount) {
                    return (value, i + 1 + hashCount)
                }
                if chars[i].isNewline {
                    return (value, i)
                }
            }

            // Check escape / interpolation (backslash followed by hashCount '#'s)
            if chars[i] == "\\", hasHashes(chars, at: i + 1, count: hashCount) {
                let escIdx = i + 1 + hashCount
                guard escIdx < count else {
                    i = escIdx
                    break
                }
                let escChar = chars[escIdx]
                if escChar == "(" {
                    let endInterp = skipBalancedInterpolation(chars, openParenIndex: escIdx)
                    value.append(contentsOf: chars[i..<endInterp])
                    i = endInterp
                    continue
                }
                switch escChar {
                case "n": value.append("\n")
                case "r": value.append("\r")
                case "t": value.append("\t")
                case "0": value.append("\0")
                case "\"": value.append("\"")
                case "\\": value.append("\\")
                default: value.append(escChar)
                }
                i = escIdx + 1
                continue
            }

            value.append(chars[i])
            i += 1
        }

        return (value, i)
    }

    private static func hasHashes(_ chars: [Character], at index: Int, count hashCount: Int) -> Bool {
        guard hashCount > 0 else { return true }
        guard index + hashCount <= chars.count else { return false }
        for offset in 0..<hashCount where chars[index + offset] != "#" {
            return false
        }
        return true
    }

    private static func skipBalancedInterpolation(_ chars: [Character], openParenIndex: Int) -> Int {
        let count = chars.count
        var i = openParenIndex + 1
        var depth = 1
        while i < count, depth > 0 {
            if chars[i] == "/", i + 1 < count, chars[i + 1] == "/" {
                i += 2
                while i < count, !chars[i].isNewline { i += 1 }
                continue
            }
            if chars[i] == "/", i + 1 < count, chars[i + 1] == "*" {
                i = skipBlockComment(chars, from: i)
                continue
            }
            if let (_, nextIndex) = scanStringLiteral(chars, from: i) {
                i = nextIndex
                continue
            }
            if chars[i] == "(" {
                depth += 1
            } else if chars[i] == ")" {
                depth -= 1
            }
            i += 1
        }
        return i
    }

    // MARK: - Balanced Delimiter & Argument Helpers

    private static func matchingCloser(for opener: Token) -> Token? {
        switch opener {
        case .lparen: return .rparen
        case .lbracket: return .rbracket
        case .lbrace: return .rbrace
        default: return nil
        }
    }

    private static func extractBalanced(
        tokens: [Token],
        openIndex: Int
    ) -> (inner: ArraySlice<Token>, endIndex: Int)? {
        guard openIndex < tokens.count, let initialCloser = matchingCloser(for: tokens[openIndex]) else {
            return nil
        }
        var stack: [Token] = [initialCloser]
        var i = openIndex + 1
        while i < tokens.count {
            let tok = tokens[i]
            if let closer = matchingCloser(for: tok) {
                stack.append(closer)
            } else if tok == stack.last {
                stack.removeLast()
                if stack.isEmpty {
                    return (tokens[(openIndex + 1)..<i], i)
                }
            }
            i += 1
        }
        return nil
    }

    private static func splitTopLevelArgs(_ slice: ArraySlice<Token>) -> [ArraySlice<Token>] {
        var result: [ArraySlice<Token>] = []
        var stack: [Token] = []
        var segmentStart = slice.startIndex
        var i = slice.startIndex

        while i < slice.endIndex {
            let tok = slice[i]
            if let closer = matchingCloser(for: tok) {
                stack.append(closer)
            } else if tok == stack.last {
                stack.removeLast()
            } else if tok == .comma, stack.isEmpty {
                if segmentStart < i {
                    result.append(slice[segmentStart..<i])
                }
                segmentStart = slice.index(after: i)
            }
            i = slice.index(after: i)
        }

        if segmentStart < slice.endIndex {
            result.append(slice[segmentStart..<slice.endIndex])
        }
        return result
    }

    private static func parseLabeledArg(_ arg: ArraySlice<Token>) -> (label: String?, value: ArraySlice<Token>) {
        let firstIdx = arg.startIndex
        let secondIdx = arg.index(after: firstIdx)
        if firstIdx < arg.endIndex,
           secondIdx < arg.endIndex,
           case let .identifier(label) = arg[firstIdx],
           arg[secondIdx] == .colon {
            let valueStart = arg.index(after: secondIdx)
            return (label, arg[valueStart..<arg.endIndex])
        }
        return (nil, arg)
    }

    // MARK: - Manifest Structure Parsing

    private static func findPackageCalls(in tokens: [Token]) -> [ArraySlice<Token>] {
        var calls: [ArraySlice<Token>] = []
        var i = 0
        while i + 1 < tokens.count {
            if tokens[i] == .identifier("Package"), tokens[i + 1] == .lparen {
                let isMethodOnOtherObject: Bool
                if i >= 1, tokens[i - 1] == .dot {
                    isMethodOnOtherObject = !(i >= 2 && tokens[i - 2] == .identifier("PackageDescription"))
                } else {
                    isMethodOnOtherObject = false
                }
                if !isMethodOnOtherObject, let extracted = extractBalanced(tokens: tokens, openIndex: i + 1) {
                    calls.append(extracted.inner)
                    i = extracted.endIndex + 1
                    continue
                }
            }
            i += 1
        }
        return calls
    }

    private static func parseTarget(_ slice: ArraySlice<Token>) -> Target? {
        var tokens = Array(slice)
        if tokens.starts(with: [.identifier("PackageDescription"), .dot]) {
            tokens.removeFirst(2)
        }
        if tokens.starts(with: [.identifier("Target"), .dot]) {
            tokens.removeFirst(2)
        } else if tokens.first == .dot {
            tokens.removeFirst()
        }

        guard tokens.count >= 3,
              case let .identifier(kind) = tokens[0],
              tokens[1] == .lparen,
              let extracted = extractBalanced(tokens: tokens, openIndex: 1),
              extracted.endIndex == tokens.count - 1 else {
            return nil
        }

        let args = splitTopLevelArgs(extracted.inner).map(parseLabeledArg)
        guard let nameArg = args.first(where: { $0.label == "name" }),
              let name = extractSingleString(nameArg.value) else {
            return nil
        }

        var dependencies: [Dependency] = []
        if let depArg = args.first(where: { $0.label == "dependencies" }) {
            let depTokens = Array(depArg.value)
            if depTokens.first == .lbracket,
               let depExtracted = extractBalanced(tokens: depTokens, openIndex: 0),
               depExtracted.endIndex == depTokens.count - 1 {
                dependencies = splitTopLevelArgs(depExtracted.inner).map(parseDependency)
            } else {
                dependencies = [.unknown(raw: renderTokens(depArg.value))]
            }
        }

        return Target(kind: kind, name: name, dependencies: dependencies)
    }

    private static func parseDependency(_ slice: ArraySlice<Token>) -> Dependency {
        if let directName = extractSingleString(slice) {
            return .byName(directName)
        }

        var tokens = Array(slice)
        if tokens.starts(with: [.identifier("PackageDescription"), .dot]) {
            tokens.removeFirst(2)
        }
        if tokens.starts(with: [.identifier("Target"), .dot]) {
            tokens.removeFirst(2)
        }
        if tokens.starts(with: [.identifier("Dependency"), .dot]) {
            tokens.removeFirst(2)
        }
        if tokens.first == .dot {
            tokens.removeFirst()
        }

        if tokens.count >= 3,
           case let .identifier(method) = tokens[0],
           tokens[1] == .lparen,
           let extracted = extractBalanced(tokens: tokens, openIndex: 1),
           extracted.endIndex == tokens.count - 1 {
            let args = splitTopLevelArgs(extracted.inner).map(parseLabeledArg)
            let nameValue = args.first(where: { $0.label == "name" })?.value
                ?? (args.first?.label == nil ? args.first?.value : nil)

            switch method {
            case "byName", "byNameItem":
                if let nameValue, let name = extractSingleString(nameValue) {
                    return .byName(name)
                }
            case "target", "targetItem":
                if let nameValue, let name = extractSingleString(nameValue) {
                    return .target(name: name)
                }
            case "product", "productItem":
                if let nameValue, let name = extractSingleString(nameValue) {
                    let pkgValue = args.first(where: { $0.label == "package" })?.value
                    let pkg = pkgValue.flatMap(extractSingleString)
                    return .product(name: name, package: pkg)
                }
            default:
                break
            }
        }

        return .unknown(raw: renderTokens(slice))
    }

    private static func extractSingleString(_ slice: ArraySlice<Token>) -> String? {
        guard slice.count == 1, let first = slice.first, case let .string(value) = first else {
            return nil
        }
        return value
    }

    private static func renderTokens(_ slice: ArraySlice<Token>) -> String {
        slice.map { tok in
            switch tok {
            case .lparen: return "("
            case .rparen: return ")"
            case .lbracket: return "["
            case .rbracket: return "]"
            case .lbrace: return "{"
            case .rbrace: return "}"
            case .colon: return ":"
            case .comma: return ","
            case .dot: return "."
            case let .identifier(id): return id
            case let .string(s): return "\"\(s)\""
            case let .other(o): return o
            }
        }.joined(separator: " ")
    }
}
