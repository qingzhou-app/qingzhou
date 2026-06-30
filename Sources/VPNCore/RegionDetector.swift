import Foundation

/// 从节点名里识别地区。
///
/// 机场节点名五花八门，但地区信息几乎总在名字里，形式无非几种：
///   - 中文名：`香港`、`日本`、`新加坡`、`美国`
///   - 国家/地区码：`HK`、`JP`、`SG`、`US`
///   - 英文名：`Hong Kong`、`Japan`
///   - 旗帜 emoji：🇭🇰 🇯🇵 🇸🇬
///
/// 识别策略：按关键词匹配，返回统一的中文地区名（用于 UI 展示 + 排除/优先设置的 key）。
/// 没匹配上的归为 `nil`（UI 里显示成「其它」）。
public enum RegionDetector {

    /// (统一地区名, 匹配关键词)。关键词大小写不敏感。
    /// 顺序敏感：先匹配更具体的（如「台湾」在「湾」之前不是问题，但把高歧义的放后面）。
    public static let table: [(region: String, keywords: [String])] = [
        ("香港", ["香港", "HK", "HongKong", "Hong Kong", "🇭🇰"]),
        ("台湾", ["台湾", "臺灣", "台灣", "TW", "Taiwan", "🇹🇼"]),
        ("日本", ["日本", "JP", "Japan", "东京", "東京", "大阪", "Tokyo", "Osaka", "🇯🇵"]),
        ("新加坡", ["新加坡", "狮城", "獅城", "SG", "Singapore", "🇸🇬"]),
        ("韩国", ["韩国", "韓國", "KR", "Korea", "首尔", "首爾", "Seoul", "🇰🇷"]),
        ("美国", ["美国", "美國", "US", "USA", "United States", "America", "硅谷", "洛杉矶", "Los Angeles", "🇺🇸"]),
        ("英国", ["英国", "英國", "UK", "GB", "United Kingdom", "London", "伦敦", "倫敦", "🇬🇧"]),
        ("德国", ["德国", "德國", "DE", "Germany", "法兰克福", "Frankfurt", "🇩🇪"]),
        ("荷兰", ["荷兰", "荷蘭", "NL", "Netherlands", "阿姆斯特丹", "Amsterdam", "🇳🇱"]),
        ("法国", ["法国", "法國", "FR", "France", "巴黎", "Paris", "🇫🇷"]),
        ("加拿大", ["加拿大", "CA", "Canada", "🇨🇦"]),
        ("澳大利亚", ["澳大利亚", "澳洲", "AU", "Australia", "悉尼", "Sydney", "🇦🇺"]),
        ("俄罗斯", ["俄罗斯", "俄羅斯", "RU", "Russia", "莫斯科", "Moscow", "🇷🇺"]),
        ("印度", ["印度", "IN", "India", "孟买", "Mumbai", "🇮🇳"]),
        ("土耳其", ["土耳其", "TR", "Turkey", "🇹🇷"]),
        ("马来西亚", ["马来西亚", "馬來西亞", "MY", "Malaysia", "🇲🇾"]),
        ("泰国", ["泰国", "泰國", "TH", "Thailand", "曼谷", "Bangkok", "🇹🇭"]),
        ("越南", ["越南", "VN", "Vietnam", "🇻🇳"]),
        ("菲律宾", ["菲律宾", "菲律賓", "PH", "Philippines", "🇵🇭"]),
        ("阿根廷", ["阿根廷", "AR", "Argentina", "🇦🇷"]),
        ("巴西", ["巴西", "BR", "Brazil", "🇧🇷"]),
    ]

    /// 从节点名识别地区，返回统一中文地区名；识别不出返回 nil。
    ///
    /// 匹配规则按关键词类型分开，避免短国家码误命中：
    ///   - 中文 / emoji：子串匹配（"美国"、🇭🇰 足够独特）
    ///   - 长英文名（>3 字符，如 "Singapore"）：子串匹配（够长不会误命中）
    ///   - 短国家码（≤3，如 US/HK/AU）：必须是独立 token，否则 "US" 会命中 "RUSSIA"、
    ///     "AU" 命中 "AUSTRALIA"。节点名里地区码几乎总被 `-_ :|·/` 这类分隔符隔开。
    public static func detect(from name: String) -> String? {
        // 把名字里的 ASCII 字母 / 数字段切成 token（"香港-HK-1" → {"HK","1"}）
        let tokens = Set(
            name.uppercased()
                .split(whereSeparator: { !$0.isASCII || !($0.isLetter || $0.isNumber) })
                .map(String.init)
        )
        for (region, keywords) in table {
            for kw in keywords {
                let isASCII = kw.allSatisfy { $0.isASCII }
                if !isASCII {
                    if name.contains(kw) { return region }
                } else {
                    let up = kw.uppercased()
                    if up.count <= 3 {
                        if tokens.contains(up) { return region }    // 短码：精确 token
                    } else {
                        if name.uppercased().contains(up) { return region }  // 长名：子串
                    }
                }
            }
        }
        return nil
    }

    /// 节点的地区名，识别不出归为「其它」。
    public static func regionOrOther(for name: String) -> String {
        detect(from: name) ?? unknownDisplayName
    }

    /// UI 兜底名：识别不出时显示「其它」。
    public static let unknownDisplayName = "其它"
}
