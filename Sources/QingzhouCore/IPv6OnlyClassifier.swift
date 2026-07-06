import Foundation

/// 「仅 IPv6 站点」判定：解析 DoH（dns-json）应答，判断一个域名是否只有 AAAA、没有 A。
///
/// 背景：轻舟为保护 fakedns 的域名反查 / 按域名分流，全链路只走 IPv4（取舍与调研数据
/// 见 docs/IPV6.md）。代价是极少数仅 IPv6 的站点直连不可达（调研：头部站点占比
/// ≤0.01%，现存的全是技术 demo 页）。用户真遇到时不能黑盒失败 —— 主 App 侧探测到
/// 这种域名要在连接页标注出来。
///
/// 纯解析、无 IO —— 探测的网络部分在 QingzhouApp 的 IPv6OnlyProber。
public enum IPv6OnlyClassifier {

    /// 一个域名的地址族画像。
    public enum Verdict: String, Sendable {
        case hasIPv4        // 有 A 记录（不管有没有 AAAA）—— 当前链路可达
        case ipv6Only       // 只有 AAAA、没有 A —— 当前全 IPv4 直连链路不可达
        case unresolvable   // 两族都没有 / NXDOMAIN / 应答异常 —— 不是 IPv6 问题
    }

    /// 输入两份 DoH JSON 应答（type=A 与 type=AAAA 的 /resolve 结果），输出判定。
    public static func classify(aResponse: Data, aaaaResponse: Data) -> Verdict {
        if hasAnswer(aResponse, recordType: 1) { return .hasIPv4 }
        return hasAnswer(aaaaResponse, recordType: 28) ? .ipv6Only : .unresolvable
    }

    /// DoH dns-json 应答里是否含指定类型的记录（A=1 / AAAA=28）。
    /// Status != 0（NXDOMAIN 等）或结构不对都算没有；CNAME（type=5）不算 ——
    /// 只认最终地址记录，CNAME 链走完没有地址照样连不上。
    static func hasAnswer(_ data: Data, recordType: Int) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["Status"] as? Int) == 0,
              let answers = obj["Answer"] as? [[String: Any]] else { return false }
        return answers.contains { ($0["type"] as? Int) == recordType }
    }
}
