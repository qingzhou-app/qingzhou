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
    /// 不合法 / 不支持的规则被静默跳过（宁可少一条规则，不可让 xray 启动失败）。
    public static func xrayRules(from rules: [Rule]) -> [[String: Any]] {
        // 中间表示：一段 = 一条待产出的 xray rule
        struct Group {
            let kind: FieldKind
            let tag: String
            var entries: [String]
        }
        var groups: [Group] = []

        for rule in rules {
            guard let (kind, entry) = convert(rule) else { continue }
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
        }

        return groups.map { g in
            switch g.kind {
            case .domain:
                return ["type": "field", "domain": g.entries, "outboundTag": g.tag]
            case .ip:
                return ["type": "field", "ip": g.entries, "outboundTag": g.tag]
            }
        }
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

    /// 单条 Rule → (字段种类, 数组条目)。不支持 / 畸形返回 nil。
    static func convert(_ rule: Rule) -> (FieldKind, String)? {
        let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch rule.type {
        case .domain:
            guard isValidDomainValue(value) else { return nil }
            return (.domain, "full:\(value.lowercased())")
        case .domainSuffix:
            guard isValidDomainValue(value) else { return nil }
            return (.domain, "domain:\(value.lowercased())")
        case .domainKeyword:
            // 裸串 = 子串匹配，正是 KEYWORD 的语义
            guard isValidDomainValue(value) else { return nil }
            return (.domain, value.lowercased())
        case .ipCIDR:
            guard isValidCIDR(value, ipv6: false) else { return nil }
            return (.ip, value)
        case .ipCIDR6:
            guard isValidCIDR(value, ipv6: true) else { return nil }
            return (.ip, value)
        case .geoip:
            guard isValidGeoCode(value) else { return nil }
            // 内置 geoip.dat 是精简版（only-cn-private，给 NE 50MB 内存预算省地）。
            // 缺失的分类**必须**跳过：xray 对 routing 规则里找不到的 geoip 分类直接
            // 启动失败（"country not found"），一条 GEOIP,us 规则就能让 VPN 起不来。
            // UI 层（RulesView）对这类规则显示「规则不生效」提示。
            guard GeoDataBundle.supportsGeoIP(value) else { return nil }
            return (.ip, "geoip:\(value.lowercased())")
        case .processName, .userAgent, .final:
            // PROCESS-NAME / USER-AGENT：xray 在 TUN 层无法匹配；FINAL 由 finalOutboundTag 处理
            return nil
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
}
