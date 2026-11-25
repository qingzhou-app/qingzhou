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

public struct SplitExitListMetrics: Codable, Sendable, Equatable {
    public var rawDomainCount: Int
    public var deduplicatedByGeoSiteCNCount: Int
    public var postDeduplicationDomainCount: Int
    public var finalDomainCount: Int
    public var rawCIDRCount: Int
    public var finalCIDRCount: Int

    public init(
        rawDomainCount: Int,
        deduplicatedByGeoSiteCNCount: Int,
        postDeduplicationDomainCount: Int,
        finalDomainCount: Int,
        rawCIDRCount: Int,
        finalCIDRCount: Int
    ) {
        self.rawDomainCount = rawDomainCount
        self.deduplicatedByGeoSiteCNCount = deduplicatedByGeoSiteCNCount
        self.postDeduplicationDomainCount = postDeduplicationDomainCount
        self.finalDomainCount = finalDomainCount
        self.rawCIDRCount = rawCIDRCount
        self.finalCIDRCount = finalCIDRCount
    }
}

public struct SplitExitLists: Codable, Sendable, Equatable {
    public var domains: [String]
    /// 不含点的条目（`DOMAIN-KEYWORD,wechat` 这种）。xray 里裸串就是子串匹配，
    /// 所以它们必须**按关键字**注入，不能加 `domain:` 前缀（那会变成"以 .wechat 结尾"，
    /// 几乎匹配不到任何东西）。
    public var domainKeywords: [String]
    public var cidrs: [String]
    /// 源文件里的总条数（去重与截断前）。
    public var sourceDomainCount: Int
    public var sourceCIDRCount: Int
    /// 采样前被内置 `geosite:cn` 去重移除的域名条数。
    public var deduplicatedDomainCount: Int
    /// 最近一次成功更新的时间。nil = 从未成功过（当前是内置兜底）。
    public var fetchedAt: Date?
    /// 数据来源 URL（审计与展示用）。
    public var sources: [String]

    public init(domains: [String] = [], domainKeywords: [String] = [], cidrs: [String] = [],
                sourceDomainCount: Int = 0, sourceCIDRCount: Int = 0,
                deduplicatedDomainCount: Int = 0,
                fetchedAt: Date? = nil, sources: [String] = []) {
        self.domains = domains
        self.domainKeywords = domainKeywords
        self.cidrs = cidrs
        self.sourceDomainCount = sourceDomainCount
        self.sourceCIDRCount = sourceCIDRCount
        self.deduplicatedDomainCount = deduplicatedDomainCount
        self.fetchedAt = fetchedAt
        self.sources = sources
    }

    /// 旧存档没有 source / deduplicated 计数字段，解码时给 0（老文件本来也没截断，显示为 0 即可）。
    enum CodingKeys: String, CodingKey {
        case domains, domainKeywords, cidrs, sourceDomainCount, sourceCIDRCount, deduplicatedDomainCount, fetchedAt, sources
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        domainKeywords = try c.decodeIfPresent([String].self, forKey: .domainKeywords) ?? []
        cidrs = try c.decodeIfPresent([String].self, forKey: .cidrs) ?? []
        sourceDomainCount = try c.decodeIfPresent(Int.self, forKey: .sourceDomainCount) ?? 0
        sourceCIDRCount = try c.decodeIfPresent(Int.self, forKey: .sourceCIDRCount) ?? 0
        deduplicatedDomainCount = try c.decodeIfPresent(Int.self, forKey: .deduplicatedDomainCount) ?? 0
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt)
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
    }

    public var isEmpty: Bool { domains.isEmpty && domainKeywords.isEmpty && cidrs.isEmpty }
}

/// 注入上限。NE 扩展有 50 MiB 的 jetsam 硬上限，11 万条域名全塞进 routing 规则
/// 会吃掉可观的常驻内存（xray 侧每个域名还要建匹配结构）。
/// 超出部分仍有 `geosite:cn` / `geoip:cn` 兜底，所以不是"丢了就不管"。
/// 超限时怎么截断。
///
/// 不用 `prefix()`：源名单是按字母序排的，取前 N 条等于只保留 a–c 开头的域名，
/// 后面 7 万多条全丢 —— 那是**有偏**的截断，用户会以为"名单生效了"其实大半没有。
/// 改成等距抽样：整份名单上均匀取点，覆盖到字母表各段。
///
/// 代价如实写在文档里：抽样会丢掉部分条目，那部分仍有 `geosite:cn` 兜底；
/// 上限值是按 NE 50 MiB 内存预算给的保守估计，**未做真机内存实测**。
public enum SplitExitListSampler {
    public static func sample<T>(_ items: [T], limit: Int) -> [T] {
        guard limit > 0, items.count > limit else { return items }
        let stride = Double(items.count) / Double(limit)
        var out: [T] = []
        out.reserveCapacity(limit)
        for i in 0..<limit {
            out.append(items[Int(Double(i) * stride)])
        }
        return out
    }
}

public enum SplitExitListsLimits {
    public static let domains = 30_000
    public static let keywords = 2_000
    public static let cidrs = 8_000
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
            // `+.app` / `*.app` 这类是"后缀"语义，即使只有一个标签（顶级域）也是后缀，
            // 不能当关键字 —— 关键字是子串匹配，`app` 会命中 happy/apple 之类的域名。
            let suffixPrefixed = value.hasPrefix("+.") || value.hasPrefix("*.")
            if let d = normalizeDomain(value, allowSingleLabel: suffixPrefixed) {
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

    /// 把一行拆成「值」并回调。支持三种实际存在的写法：
    ///
    /// 1. Clash rule-provider（Loyalsoldier 的 release 分支就是这个）：
    ///    ```
    ///    payload:
    ///      - '2mdn-cn.net'
    ///    ```
    /// 2. Clash 规则行：`DOMAIN-SUFFIX,qq.com` / `IP-CIDR,1.0.1.0/24,no-resolve`
    /// 3. 裸值：`qq.com`
    ///
    /// 注释、空行、`payload:` 表头、`no-resolve` 这类 flag 都在这里吃掉。
    private static func forEachEntry(_ text: String, _ body: (String) -> Void) {
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("//") { continue }
            // 表头（payload:）不是数据
            if line.hasPrefix("payload") { continue }
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash]).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
            }

            // --- 形态 1：YAML 列表项 `- 'x'` / `- "x"` / `- x` ---
            if line.hasPrefix("-") {
                var v = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if v.count >= 2,
                   (v.hasPrefix("'") && v.hasSuffix("'")) || (v.hasPrefix("\"") && v.hasSuffix("\"")) {
                    v = String(v.dropFirst().dropLast())
                }
                v = v.trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { body(v) }
                continue
            }

            // --- 形态 2/3：逗号分隔的规则行，或裸值 ---
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let value = (parts.count >= 2 ? parts[1] : parts[0]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            body(value)
        }
    }

    /// 域名归一：小写、去首尾点。拒绝含空白 / 斜杠 / 冒号 / 逗号的串（那是别的格式）。
    /// 允许通配前缀 `*.`（部分名单这么写），去掉它 —— xray 的 `domain:` 本身就含子域。
    static func normalizeDomain(_ raw: String, allowSingleLabel: Bool = false) -> String? {
        var v = raw.lowercased()
        // Clash rule-provider 用 `+.domain` 表示"该域及其子域"，`*.domain` 也常见。
        // 两种前缀都要剥掉 —— xray 的 `domain:` 本身就是含子域的语义，剥掉即等价。
        // 不剥的话 `+` 会被下面的字符校验判为非法，整份名单几乎全被丢掉（线上踩过：
        // direct.txt 11 万条只剩 562 条）。
        for prefix in ["+.", "*."] where v.hasPrefix(prefix) {
            v.removeFirst(2)
            break
        }
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !v.isEmpty, v.count <= 253 else { return nil }
        let forbidden = CharacterSet(charactersIn: " ,/\\:@\"'*").union(.whitespacesAndNewlines)
        guard v.rangeOfCharacter(from: forbidden) == nil else { return nil }
        // 只允许字母数字、连字符、下划线和点
        guard v.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else {
            return nil
        }
        // 单段只有在明确带后缀前缀时才收（`+.app` = 顶级域），否则视为关键字
        guard v.contains(".") || allowSingleLabel else { return nil }
        return v
    }

    /// 不含点的条目就是关键字（`wechat`）。限制长度，避免把整段误文本当关键字注入。
    static func normalizeKeyword(_ raw: String) -> String? {
        var v = raw.lowercased()
        for prefix in ["+.", "*."] where v.hasPrefix(prefix) {
            v.removeFirst(2)
            break
        }
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !v.isEmpty, v.count <= 63 else { return nil }
        let forbidden = CharacterSet(charactersIn: " ,/\\:@\"'*").union(.whitespacesAndNewlines)
        guard v.rangeOfCharacter(from: forbidden) == nil else { return nil }
        guard v.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        guard !v.contains(".") else { return nil }
        return v
    }

    /// CIDR 归一：用 inet_pton 真解析，不靠正则猜；补默认前缀长度。
    public static func normalizeCIDR(_ raw: String) -> String? {
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
