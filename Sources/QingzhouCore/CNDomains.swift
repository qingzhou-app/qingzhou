import Foundation

/// 中国大陆域名归属判定（域名分析「建议」的 直连/代理 判断依据）。
///
/// 两层规则：
/// 1. TLD：`.cn`、`.中国`(xn--fiqs8s)、`.中國`(xn--fiqz9s) 结尾 → 恒判 CN；
/// 2. 后缀表：内置资源 `cn-domains.txt`（约 300 条常见大陆服务的 registrable domain，
///    来自 geosite:cn 的高频人工子集，来源/更新方式见资源文件头注释），
///    host 逐级剥子域名后缀匹配 —— `www.baidu.com` 命中 `baidu.com`。
///
/// 刻意不引 libXray 的完整 geosite.dat（85MB Go runtime 会拖垮主 App 启动），也不引
/// 完整 Public Suffix List。表外的大陆域名会漏判（宁缺毋滥），代价只是少一条优化建议。
public enum CNDomains {

    /// 内置后缀表。加载失败（理论上不可能）退化为空表，只剩 TLD 规则。
    public static let suffixes: Set<String> = {
        guard let url = Bundle.module.url(forResource: "cn-domains", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var set = Set<String>()
        for line in text.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#") else { continue }
            set.insert(s.lowercased())
        }
        return set
    }()

    /// 中国 TLD（含 IDN punycode）。`.cn` 覆盖了全部 `*.com.cn` / `*.gov.cn` 等二级后缀。
    private static let cnTLDs: Set<String> = ["cn", "xn--fiqs8s", "xn--fiqz9s"]

    /// host 是否大概率是中国大陆域名。裸 IP / 无点主机名恒 false。
    public static func isLikelyCN(_ host: String) -> Bool {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }          // FQDN 尾点
        guard !h.isEmpty, !h.contains(":") else { return false }   // 端口 / IPv6
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return false }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }  // IPv4
        if let tld = labels.last, cnTLDs.contains(tld) { return true }
        // 逐级剥子域名做后缀匹配：a.b.baidu.com → b.baidu.com → baidu.com
        for start in 0...(labels.count - 2) {
            if suffixes.contains(labels[start...].joined(separator: ".")) { return true }
        }
        return false
    }
}
