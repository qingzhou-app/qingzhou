// SplitExitLists —— 国内域名 / 国内 IP 名单（对应 Loyalsoldier/clash-rules 的
// direct.txt 与 cncidr.txt）。
//
// 为什么不用通用 Rule：
//   - 这两份名单是「纯名单」，没有出口语义（出口由 SplitExitPlan 固定），
//     做成 Rule 会凭空生出 target 字段，还得在转换层再丢掉；
//   - 体量大（direct.txt 数万条），只保留必要的两个字符串数组，
//     序列化进 App Group 文件给隧道扩展读，比塞进 VPN preferences（plist）现实得多。
//
// 解析刻意「宽进严出」：格式不认识的行直接跳过（名单由外部维护，格式漂移不该让
// 整份名单失效），但**一条都没解析出来**视为失败，由调用方保留上一份有效名单。

import Foundation

public struct SplitExitLists: Codable, Sendable, Equatable {
    public var domains: [String]
    /// 不含点的条目（`DOMAIN-KEYWORD,wechat` 这种）。xray 里裸串就是子串匹配，
    /// 所以它们必须**按关键字**注入，不能加 `domain:` 前缀（那会变成"以 .wechat 结尾"，
    /// 几乎匹配不到任何东西）。
    public var domainKeywords: [String]
    public var cidrs: [String]
    /// 最近一次成功更新的时间。nil = 从未成功过（当前是内置兜底）。
    public var fetchedAt: Date?
    /// 数据来源 URL（审计与展示用）。
    public var sources: [String]

    public init(domains: [String] = [], domainKeywords: [String] = [], cidrs: [String] = [],
                fetchedAt: Date? = nil, sources: [String] = []) {
        self.domains = domains
        self.domainKeywords = domainKeywords
        self.cidrs = cidrs
        self.fetchedAt = fetchedAt
        self.sources = sources
    }

    public var isEmpty: Bool { domains.isEmpty && domainKeywords.isEmpty && cidrs.isEmpty }
}

public enum SplitExitListParser {

    /// 解析域名名单。带点的进 `domains`（按后缀匹配），不带的进 `keywords`（按子串匹配）。
    ///
    /// 接受的行形态：
    ///   `DOMAIN-SUFFIX,qq.com` / `DOMAIN,example.cn` / `DOMAIN-KEYWORD,wechat`
    ///   也接受不带类型的裸值（`qq.com`）—— 有些镜像站会把类型列去掉。
    public static func parseDomains(_ text: String) -> (domains: [String], keywords: [String]) {
        var domains: [String] = []
        var keywords: [String] = []
        var seenDomain = Set<String>(), seenKeyword = Set<String>()
        forEachEntry(text) { value in
            if let d = normalizeDomain(value) {
                if seenDomain.insert(d).inserted { domains.append(d) }
            } else if let k = normalizeKeyword(value) {
                if seenKeyword.insert(k).inserted { keywords.append(k) }
            }
        }
        return (domains, keywords)
    }

    /// 解析 IP 名单（`IP-CIDR,1.0.1.0/24` 或裸 IP / CIDR）。
    public static func parseCIDRs(_ text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        forEachEntry(text) { value in
            guard let c = normalizeCIDR(value), seen.insert(c).inserted else { return }
            out.append(c)
        }
        return out
    }

    /// 把一行拆成「值」并回调。注释、空行、`NO-RESOLVE` 这类 flag 都在这里吃掉。
    private static func forEachEntry(_ text: String, _ body: (String) -> Void) {
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("//") { continue }
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash]).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
            }
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let value = (parts.count >= 2 ? parts[1] : parts[0]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            body(value)
        }
    }

    /// 域名归一：小写、去首尾点。拒绝含空白 / 斜杠 / 冒号 / 逗号的串（那是别的格式）。
    /// 允许通配前缀 `*.`（部分名单这么写），去掉它 —— xray 的 `domain:` 本身就含子域。
    static func normalizeDomain(_ raw: String) -> String? {
        var v = raw.lowercased()
        if v.hasPrefix("*.") { v.removeFirst(2) }
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !v.isEmpty, v.count <= 253 else { return nil }
        let forbidden = CharacterSet(charactersIn: " ,/\\:@\"'*").union(.whitespacesAndNewlines)
        guard v.rangeOfCharacter(from: forbidden) == nil else { return nil }
        // 只允许字母数字、连字符、下划线和点
        guard v.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else {
            return nil
        }
        guard v.contains(".") else { return nil }   // 单段不是域名
        return v
    }

    /// 不含点的条目就是关键字（`wechat`）。限制长度，避免把整段误文本当关键字注入。
    static func normalizeKeyword(_ raw: String) -> String? {
        var v = raw.lowercased()
        if v.hasPrefix("*.") { v.removeFirst(2) }
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !v.isEmpty, v.count <= 63 else { return nil }
        let forbidden = CharacterSet(charactersIn: " ,/\\:@\"'*").union(.whitespacesAndNewlines)
        guard v.rangeOfCharacter(from: forbidden) == nil else { return nil }
        guard v.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        guard !v.contains(".") else { return nil }
        return v
    }

    /// CIDR 归一：用 inet_pton 真解析，不靠正则猜；补默认前缀长度。
    static func normalizeCIDR(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespaces)
        let parts = v.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, let addr = parts.first, !addr.isEmpty else { return nil }
        if parts.count == 2 {
            guard let prefix = Int(parts[1]) else { return nil }
            var buf4 = in_addr(), buf6 = in6_addr()
            if inet_pton(AF_INET, String(addr), &buf4) == 1 {
                guard (0...32).contains(prefix) else { return nil }
            } else if inet_pton(AF_INET6, String(addr), &buf6) == 1 {
                guard (0...128).contains(prefix) else { return nil }
            } else {
                return nil
            }
            return "\(addr)/\(prefix)"
        }
        var buf4 = in_addr(), buf6 = in6_addr()
        if inet_pton(AF_INET, v, &buf4) == 1 { return "\(v)/32" }
        if inet_pton(AF_INET6, v, &buf6) == 1 { return "\(v)/128" }
        return nil
    }
}

/// 名单在 App Group 里的存放约定（主 App 写、隧道扩展读）。
/// 路径固定，两端各自拼 —— 两个模块互不依赖，只共享这个常量。
public enum SplitExitListsFile {
    public static let fileName = "split-exit-lists.json"

    public static func encode(_ lists: SplitExitLists) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(lists)
    }

    public static func decode(_ data: Data) -> SplitExitLists? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SplitExitLists.self, from: data)
    }
}
