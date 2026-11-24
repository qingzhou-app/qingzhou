import Foundation
import QingzhouCore

public enum RuleParseError: Error, Equatable, Sendable {
    case empty
    case missingFields(String)
    case unknownType(String)
    case unknownTarget(String)
    case invalidValue(String)
}

/// 把规则源文本解析成结构化规则。
///
/// 支持单行格式：
/// - `DOMAIN-SUFFIX,google.com,PROXY`
/// - `IP-CIDR,10.0.0.0/8,DIRECT,no-resolve`（`,no-resolve` 大小写不敏感解析到 `Rule.noResolve`）
/// - `IP-CIDR,10.0.0.0/8,DIRECT,no-resolve # lan`（保留注释到 `Rule.comment`）
/// - `FINAL,PROXY`
/// - `# 注释` / 空行 → 跳过
public enum RuleParser {
    /// 解析整段文本，返回有效规则；错误行收集起来不致命。
    public static func parseAll(_ text: String) -> (rules: [Rule], errors: [(line: String, error: Error)]) {
        var rules: [Rule] = []
        var errors: [(String, Error)] = []
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            do {
                rules.append(try parseLine(line))
            } catch {
                errors.append((line, error))
            }
        }
        return (rules, errors)
    }

    public static func parseLine(_ line: String) throws -> Rule {
        let (codePart, inlineComment) = splitInlineHashComment(line)
        guard !codePart.isEmpty else { throw RuleParseError.empty }

        let rawParts = codePart.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard !rawParts.isEmpty else { throw RuleParseError.empty }

        let typeRaw = rawParts[0].uppercased()
        guard let type = RuleType(rawValue: typeRaw) else {
            throw RuleParseError.unknownType(typeRaw)
        }

        // FINAL 是特例：FINAL,PROXY（保留 `# ...` 中含逗号的行内注释）
        if type == .final {
            guard rawParts.count >= 2 else { throw RuleParseError.missingFields(line) }
            let targetPart = rawParts[1]
            guard let target = RuleTarget(rawValue: targetPart.uppercased()) else {
                throw RuleParseError.unknownTarget(targetPart)
            }
            let extraParts = rawParts.dropFirst(2).filter { !$0.isEmpty }
            var commentParts: [String] = []
            if !extraParts.isEmpty {
                commentParts.append(extraParts.joined(separator: ","))
            }
            if let inlineComment {
                commentParts.append(inlineComment)
            }
            let comment = commentParts.isEmpty ? nil : commentParts.joined(separator: " ")
            return Rule(type: .final, value: "", target: target, comment: comment)
        }

        guard rawParts.count >= 3 else { throw RuleParseError.missingFields(line) }
        let value = rawParts[1]
        let targetPart = rawParts[2]
        guard let target = RuleTarget(rawValue: targetPart.uppercased()) else {
            throw RuleParseError.unknownTarget(targetPart)
        }

        var noResolve = false
        var remainingCommentParts: [String] = []
        if rawParts.count >= 4 {
            for idx in 3..<rawParts.count {
                let token = rawParts[idx]
                if token.lowercased() == "no-resolve" {
                    noResolve = true
                } else if !token.isEmpty {
                    remainingCommentParts.append(token)
                }
            }
        }

        var commentComponents: [String] = []
        if !remainingCommentParts.isEmpty {
            commentComponents.append(remainingCommentParts.joined(separator: ","))
        }
        if let inlineComment {
            commentComponents.append(inlineComment)
        }
        let comment = commentComponents.isEmpty ? nil : commentComponents.joined(separator: " ")

        // 对 IP-CIDR / IP-CIDR6 做轻量校验
        switch type {
        case .ipCIDR:
            guard CIDR.parseIPv4(value) != nil else { throw RuleParseError.invalidValue(value) }
        case .ipCIDR6:
            guard CIDR.parseIPv6(value) != nil else { throw RuleParseError.invalidValue(value) }
        default:
            break
        }

        return Rule(type: type, value: value, target: target, comment: comment, noResolve: noResolve)
    }

    private static func splitInlineHashComment(_ segment: String) -> (token: String, comment: String?) {
        guard let hashIdx = segment.firstIndex(of: "#") else {
            return (segment.trimmingCharacters(in: .whitespaces), nil)
        }
        let token = String(segment[..<hashIdx]).trimmingCharacters(in: .whitespaces)
        let after = String(segment[segment.index(after: hashIdx)...]).trimmingCharacters(in: .whitespaces)
        return (token, after.isEmpty ? nil : after)
    }
}
