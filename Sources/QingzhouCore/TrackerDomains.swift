import Foundation

/// 追踪器域名判定（域名分析的「追踪器」徽章 + 建议页「建议拒绝」的依据）。
///
/// 数据源：内置资源 `tracker-domains.txt` —— 约两百条广告网络 / 行为分析 / 移动归因 /
/// 会话回放 / DMP 的高频后缀，人工整理并用 scripts/update-tracker-domains.py 对照
/// EasyPrivacy / DuckDuckGo 清单校验（来源与许可见资源文件头注释）。
///
/// 匹配机制与 `CNDomains` 相同：host 逐级剥子域名做后缀匹配 ——
/// `stats.doubleclick.net` 命中 `doubleclick.net`。表支持多段后缀条目
/// （如 `hm.baidu.com`：百度统计是追踪器，baidu.com 主站不是）。
///
/// 定位是高频子集不是全量拦截表（那是几万条的活儿，交给规则源）；
/// 表外的追踪器会漏判，代价只是少一个徽章 / 少一条建议，宁缺毋滥。
public enum TrackerDomains {

    /// 内置后缀表。加载失败（理论上不可能）退化为空表 —— 只是不再标注，不影响功能。
    public static let suffixes: Set<String> = {
        guard let url = Bundle.module.url(forResource: "tracker-domains", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var set = Set<String>()
        for line in text.split(separator: "\n") {
            // 支持行尾注释（`foo.com # manual` 的人工核实标注）。
            // omittingEmptySubsequences: false —— 否则整行注释「# xxx」会把 # 后内容误当条目
            let content = line.split(separator: "#", maxSplits: 1,
                                     omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let s = content.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            set.insert(s.lowercased())
        }
        return set
    }()

    /// host 是否为已知追踪器域名。裸 IP / 无点主机名恒 false。
    public static func isTracker(_ host: String) -> Bool {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }          // FQDN 尾点
        guard !h.isEmpty, !h.contains(":") else { return false }   // 端口 / IPv6
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return false }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }  // IPv4
        // 逐级剥子域名做后缀匹配：a.b.doubleclick.net → b.doubleclick.net → doubleclick.net
        for start in 0...(labels.count - 2) {
            if suffixes.contains(labels[start...].joined(separator: ".")) { return true }
        }
        return false
    }
}
