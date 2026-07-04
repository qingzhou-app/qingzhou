import Foundation

/// 从节点名 / 元数据识别「倍率」（rate multiplier）。
///
/// 机场（订阅提供方）常给节点标倍率：高倍率节点走的是更贵的专线（IEPL/IPLC），
/// 按倍率扣流量——0.5x 用 1GB 只扣 0.5GB，2x 用 1GB 扣 2GB。延迟接近时优先低倍率
/// 能实打实省钱/省流量。
///
/// 数据来源优先级（见 `Node.effectiveRate`）：**元数据**（Clash 的 rate 字段等，最准）
/// → **节点名正则**（各机场命名千奇百怪，尽力而为）。识别不出 = nil（比较时按 1.0 处理）。
public enum NodeRateParser {
    /// 合理倍率区间：过滤掉把「4K」「1080P」「x265」这类误当倍率的数字。
    private static let plausibleRange = 0.1...100.0

    /// 直接解析一个可能是倍率的原始字符串（元数据字段值，如 "2"、"0.5"、"1.5x"）。
    public static func parse(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        // 元数据里也可能带 x/倍 后缀，先抠数字
        if let v = Double(raw), plausibleRange.contains(v) { return v }
        return fromName(raw)
    }

    // ⚠️ 正则**预编译成静态常量**：`fromName` 在节点列表里每行每次渲染都会被调用
    //（Node.effectiveRate），若每次 new 一个 NSRegularExpression，30+ 节点 × 每秒刷新
    // 会把主线程编译到卡死（macOS 上表现为鼠标悬停彩虹转圈 —— 真机踩过）。
    // 编译一次、复用；匹配本身很便宜。按置信度从高到低排列，命中即返回。
    private static let delim = #"(?:^|[\s\[\(【（|·:：\-])"#
    private static let delimEnd = #"(?:$|[\s\]\)】）|·:：\-])"#
    private static let patterns: [NSRegularExpression] = [
        // 1) 「倍率[:：] 数字」/「数字 倍」—— 有「倍」字，最不容易误判
        #"倍率?\s*[:：]?\s*([0-9]+(?:\.[0-9]+)?)"#,
        #"([0-9]+(?:\.[0-9]+)?)\s*倍"#,
        // 2) 分隔符包裹的「数字 x」/「x 数字」—— 分隔符降低把无关数字误当倍率的概率
        delim + #"([0-9]+(?:\.[0-9]+)?)\s*[xX×]"# + delimEnd,
        delim + #"[xX×]\s*([0-9]+(?:\.[0-9]+)?)"# + delimEnd,
        // 3) 结尾「:数字」/「：数字」—— 一枝红杏等机场把倍率写成 `日本-OS-1-:0.6`（冒号+尾部数字，
        //    无 x/倍 关键字）。锚定串尾 + 冒号前导，配合 0.1~100 区间过滤端口，误判风险低。
        #"[:：]\s*([0-9]+(?:\.[0-9]+)?)\s*$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// 从节点名里识别倍率。覆盖常见机场写法：
    /// `2x` `2X` `x2` `×2` `2倍` `倍率:1.5` `[3x]` `0.5倍` `| 2x |` `-5x-` 等。
    public static func fromName(_ name: String) -> Double? {
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        for re in patterns {
            guard let m = re.firstMatch(in: name, range: range), m.numberOfRanges >= 2,
                  let g = Range(m.range(at: 1), in: name),
                  let v = Double(name[g]) else { continue }
            if plausibleRange.contains(v) { return v }
        }
        return nil
    }
}
