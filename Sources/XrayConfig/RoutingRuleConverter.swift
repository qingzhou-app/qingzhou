// RoutingRuleConverter —— 用户规则（自定义 + 远程）→ xray routing rules。
//
// 背景：customRules / remoteRules 之前只在 UI 层用（规则页展示、域名分析建议），
// 从未进入 xray 的 routing 配置 —— 对真实流量完全不生效。这个转换器补上这一环，
// XrayConfigComposer 在 rule 模式下把转换结果插在内置 geosite/geoip 规则之前。
//
// xray routing 字段语义（https://xtls.github.io/config/routing.html）：
//   - `domain` 数组：裸串 = 子串匹配（keyword）、`domain:` = 域名及其子域、
//     `full:` = 完全匹配、`geosite:` = geosite.dat 分类
//   - `ip` 数组：CIDR / 单 IP / `geoip:` 分类
//   - 数组内是 OR 关系；规则数组按序 first-match
//
// 设计要点：
//   - **保序合并**：只合并**相邻**且同 target、同字段种类（domain / ip）的规则。
//     跨段合并会破坏 first-match 语义（DOMAIN,x,PROXY 在 DOMAIN,x,REJECT 之后
//     被并到前面的 PROXY 组里，REJECT 就永远匹配不到了）。
//   - **畸形值跳过而不是抛错**：一条坏规则不该让 xray 起不来、VPN 连不上。
//     IP-CIDR 用 inet_pton 校验，域名值禁空白 / 逗号 / 冒号。
//   - **不支持的类型跳过**：PROCESS-NAME / USER-AGENT —— xray 在 TUN 层拿不到
//     进程名和 UA，无法匹配。这两类仍由 UI 层（域名分析）使用。
//   - **FINAL 不产出字段规则**：它是"兜底出口"，由 finalOutboundTag 单独取出，
//     composer 用它覆盖 rule 模式内置的 catch-all 规则的出口。

import Foundation
import QingzhouCore

/// 单条规则在转换为 xray-core 路由规则时的语义诊断。
public struct XrayRuleDiagnostic: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// `PROCESS-NAME` 仅在 `RuleEngine`（本机规则模拟与命中归因）生效，xray-core TUN 无进程名匹配能力。
        case unsupportedProcessName
        /// `USER-AGENT` 仅在 `RuleEngine`（本机规则模拟）生效，xray-core TUN 无 HTTP User-Agent 匹配能力。
        case unsupportedUserAgent
        /// `GEOIP` 分类不在内置精简 geoip.dat 中，需完整版 geoip.dat 才能生效。
        case missingFullGeoIP
        /// `GEOSITE` 分类不在内置 geosite.dat 白名单中，已跳过以防 xray 启动失败。
        case unsupportedGeoSite
        /// 规则值畸形或为空，已跳过以防 xray 启动失败。
        case invalidValue
        /// 规则带 `,no-resolve`，但 xray-core 无单条 `no-resolve` 开关（`.rule` 模式路由全局使用 `domainStrategy: "IPIfNonMatch"`）。
        case noResolveGlobalDomainStrategyCaveat
    }

    public let ruleID: UUID
    public let ruleType: RuleType
    public let ruleLine: String
    public let kind: Kind
    public let message: String

    public init(ruleID: UUID, ruleType: RuleType, ruleLine: String, kind: Kind, message: String) {
        self.ruleID = ruleID
        self.ruleType = ruleType
        self.ruleLine = ruleLine
        self.kind = kind
        self.message = message
    }
}

/// `RoutingRuleConverter.xrayRulesWithDiagnostics` 的结构化转换输出。
public struct XrayRuleConversionResult {
    public let rules: [[String: Any]]
    public let diagnostics: [XrayRuleDiagnostic]
    public let finalOutboundTag: String?

    public init(rules: [[String: Any]], diagnostics: [XrayRuleDiagnostic], finalOutboundTag: String?) {
        self.rules = rules
        self.diagnostics = diagnostics
        self.finalOutboundTag = finalOutboundTag
    }
}

public enum RoutingRuleConverter {

    /// Rule.target → composer 里的 outbound tag（proxy / direct / reject）。
    public static func outboundTag(for target: RuleTarget) -> String {
        switch target {
        case .proxy:  return "proxy"
        case .direct: return "direct"
        case .reject: return "reject"
        }
    }

    /// 用户规则 → xray routing rules（保序，相邻同类合并）。
    /// 不合法 / 不支持的规则被跳过（详情可通过 `xrayRulesWithDiagnostics(from:hasFullGeoIP:)` 获取），
    /// 宁可少一条规则，不可让 xray 启动失败。
    /// - Parameter hasFullGeoIP: 完整版 geoip.dat 是否就位（扩展检查 App Group 后传入）。
    ///   true 时任意国家/地区码的 GEOIP 规则都透传；false（默认）只放行内置精简版
    ///   包含的分类（cn/private），其余跳过 —— xray 对缺失分类直接启动失败。
    public static func xrayRules(from rules: [Rule], hasFullGeoIP: Bool = false) -> [[String: Any]] {
        xrayRulesWithDiagnostics(from: rules, hasFullGeoIP: hasFullGeoIP).rules
    }

    /// 用户规则 → xray routing rules + 显式语义诊断（`PROCESS-NAME` / `USER-AGENT` /
    /// 缺失完整 geoip / 不支持 geosite / `,no-resolve` 语义差异）。
    public static func xrayRulesWithDiagnostics(from rules: [Rule],
                                                hasFullGeoIP: Bool = false) -> XrayRuleConversionResult {
        // 中间表示：一段 = 一条待产出的 xray rule
        struct Group {
            let kind: FieldKind
            let tag: String
            var entries: [String]
        }
        var groups: [Group] = []
        var diagnostics: [XrayRuleDiagnostic] = []

        for rule in rules {
            if rule.noResolve && rule.type != .final {
                diagnostics.append(XrayRuleDiagnostic(
                    ruleID: rule.id,
                    ruleType: rule.type,
                    ruleLine: rule.lineForm,
                    kind: .noResolveGlobalDomainStrategyCaveat,
                    message: "xray-core 无单条 rule 级 no-resolve 开关；规则模式全局使用 routing.domainStrategy = \"IPIfNonMatch\"。"
                ))
            }

            let outcome = convertWithDiagnostic(rule, hasFullGeoIP: hasFullGeoIP)
            switch outcome {
            case .converted(let kind, let entry):
                let tag = outboundTag(for: rule.target)
                if var last = groups.last, last.kind == kind, last.tag == tag {
                    // 相邻同段：并进同一条 xray rule（数组内 OR，语义等价且省规则条数）
                    if !last.entries.contains(entry) {
                        last.entries.append(entry)
                        groups[groups.count - 1] = last
                    }
                } else {
                    groups.append(Group(kind: kind, tag: tag, entries: [entry]))
                }
            case .skipped(let kind, let message):
                diagnostics.append(XrayRuleDiagnostic(
                    ruleID: rule.id,
                    ruleType: rule.type,
                    ruleLine: rule.lineForm,
                    kind: kind,
                    message: message
                ))
            case .finalHandledSeparately:
                break
            }
        }

        let xrayRuleDicts: [[String: Any]] = groups.map { g in
            switch g.kind {
            case .domain:
                return ["type": "field", "domain": g.entries, "outboundTag": g.tag]
            case .ip:
                return ["type": "field", "ip": g.entries, "outboundTag": g.tag]
            }
        }
        return XrayRuleConversionResult(
            rules: xrayRuleDicts,
            diagnostics: diagnostics,
            finalOutboundTag: finalOutboundTag(from: rules)
        )
    }

    /// 用户规则里第一条 FINAL 的出口 tag；没有 FINAL 时 nil。
    /// composer 在 rule 模式用它替换内置 catch-all（"其余走代理"）的出口 ——
    /// FINAL 的语义就是"以上都没匹配到时走哪"，不能当普通规则插在前面
    /// （那会吞掉后面所有内置规则）。
    public static func finalOutboundTag(from rules: [Rule]) -> String? {
        rules.first { $0.type == .final }.map { outboundTag(for: $0.target) }
    }

    // MARK: - 单条转换

    enum FieldKind { case domain, ip }

    private enum ConvertOutcome {
        case converted(FieldKind, String)
        case skipped(XrayRuleDiagnostic.Kind, String)
        case finalHandledSeparately
    }

    /// 单条 Rule → (字段种类, 数组条目)。不支持 / 畸形返回 nil。
    static func convert(_ rule: Rule, hasFullGeoIP: Bool = false) -> (FieldKind, String)? {
        switch convertWithDiagnostic(rule, hasFullGeoIP: hasFullGeoIP) {
        case .converted(let kind, let entry):
            return (kind, entry)
        case .skipped, .finalHandledSeparately:
            return nil
        }
    }

    private static func convertWithDiagnostic(_ rule: Rule, hasFullGeoIP: Bool) -> ConvertOutcome {
        let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch rule.type {
        case .domain:
            guard isValidDomainValue(value) else {
                return .skipped(.invalidValue, "无效 DOMAIN 规则值：\(rule.value)")
            }
            return .converted(.domain, "full:\(value.lowercased())")
        case .domainSuffix:
            guard isValidDomainValue(value) else {
                return .skipped(.invalidValue, "无效 DOMAIN-SUFFIX 规则值：\(rule.value)")
            }
            return .converted(.domain, "domain:\(value.lowercased())")
        case .domainKeyword:
            // 裸串 = 子串匹配，正是 KEYWORD 的语义
            guard isValidDomainValue(value) else {
                return .skipped(.invalidValue, "无效 DOMAIN-KEYWORD 规则值：\(rule.value)")
            }
            return .converted(.domain, value.lowercased())
        case .ipCIDR:
            guard isValidCIDR(value, ipv6: false) else {
                return .skipped(.invalidValue, "无效 IP-CIDR 规则值：\(rule.value)")
            }
            return .converted(.ip, value)
        case .ipCIDR6:
            guard isValidCIDR(value, ipv6: true) else {
                return .skipped(.invalidValue, "无效 IP-CIDR6 规则值：\(rule.value)")
            }
            return .converted(.ip, value)
        case .geoip:
            guard isValidGeoCode(value) else {
                return .skipped(.invalidValue, "无效 GEOIP 规则值：\(rule.value)")
            }
            // 内置 geoip.dat 是精简版（only-cn-private，给 NE 50MB 内存预算省地）。
            // 缺失的分类**必须**跳过：xray 对 routing 规则里找不到的 geoip 分类直接
            // 启动失败（"country not found"），一条 GEOIP,us 规则就能让 VPN 起不来。
            // UI 层（RulesView）对这类规则显示「需下载完整版 geo 数据」提示。
            // 完整版（App Group 下载）就位时 hasFullGeoIP=true，全部分类码解锁。
            guard hasFullGeoIP || GeoDataBundle.supportsGeoIP(value) else {
                return .skipped(.missingFullGeoIP, "内置精简 geoip.dat 不含「\(value)」，需下载完整版 geo 数据。")
            }
            return .converted(.ip, "geoip:\(value.lowercased())")
        case .geoSite:
            guard isValidGeoSiteCode(value) else {
                return .skipped(.invalidValue, "无效 GEOSITE 规则值：\(rule.value)")
            }
            // 同 GEOIP：引用了内置 geosite.dat 里没有的分类，xray 会直接启动失败
            //（"failed to load geosite"），一条坏规则 = 整机断网。默认只放行白名单。
            guard GeoDataBundle.supportsGeoSite(value) else {
                return .skipped(.unsupportedGeoSite, "「\(value)」不在内置 geosite.dat 分类白名单中，已跳过。")
            }
            return .converted(.domain, "geosite:\(value.lowercased())")
        case .processName:
            return .skipped(.unsupportedProcessName, "PROCESS-NAME 仅在 App 本机规则模拟与命中归因中使用，xray-core TUN 不支持按进程名路由。")
        case .userAgent:
            return .skipped(.unsupportedUserAgent, "USER-AGENT 仅在 App 本机规则模拟中使用，xray-core TUN 无法匹配 HTTP User-Agent。")
        case .final:
            return .finalHandledSeparately
        }
    }

    // MARK: - 值校验（防一条坏规则拖垮整个 xray 配置）

    /// 域名 / 关键字值：非空，不含空白、逗号（规则分隔符）、冒号（会被 xray 当匹配前缀）、
    /// 双引号 / 斜杠（明显不是域名）。
    private static func isValidDomainValue(_ v: String) -> Bool {
        guard !v.isEmpty else { return false }
        let forbidden = CharacterSet(charactersIn: ",:\"/\\").union(.whitespacesAndNewlines)
        return v.rangeOfCharacter(from: forbidden) == nil
    }

    /// CIDR（也接受不带 /prefix 的单 IP）。用 inet_pton 做真解析，不靠正则猜。
    private static func isValidCIDR(_ v: String, ipv6: Bool) -> Bool {
        guard !v.isEmpty else { return false }
        let parts = v.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, let addrPart = parts.first, !addrPart.isEmpty else { return false }
        if parts.count == 2 {
            guard let prefix = Int(parts[1]), prefix >= 0, prefix <= (ipv6 ? 128 : 32) else {
                return false
            }
        }
        var buf = [UInt8](repeating: 0, count: 16)
        return inet_pton(ipv6 ? AF_INET6 : AF_INET, String(addrPart), &buf) == 1
    }

    /// geoip 分类码：字母 / 数字 / 连字符（cn、private、telegram、netflix…）。
    private static func isValidGeoCode(_ v: String) -> Bool {
        guard !v.isEmpty else { return false }
        return v.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "!" }
    }

    /// geosite 分类码：除 geoip 允许的字符外还可带下划线；`!` 只能出现在中间
    ///（`geolocation-!cn` 是合法分类名，前缀 `!` 是「反转」写法，xray 无此语义）。
    private static func isValidGeoSiteCode(_ v: String) -> Bool {
        guard !v.isEmpty, !v.hasPrefix("!") else { return false }
        return v.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "!" || $0 == "_" }
    }
}
