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

    /// 从节点名里识别倍率。覆盖常见机场写法：
    /// `2x` `2X` `x2` `×2` `2倍` `倍率:1.5` `[3x]` `0.5倍` `| 2x |` `-5x-` 等。
    public static func fromName(_ name: String) -> Double? {
        // 按置信度从高到低尝试；命中即返回。
        // 1) 「倍率[:：] 数字」/「数字 倍」—— 有「倍」字，最不容易误判
        if let v = firstMatch(in: name, pattern: #"倍率?\s*[:：]?\s*([0-9]+(?:\.[0-9]+)?)"#) { return v }
        if let v = firstMatch(in: name, pattern: #"([0-9]+(?:\.[0-9]+)?)\s*倍"#) { return v }
        // 2) 有分隔符包裹的「数字 x」/「x 数字」—— 分隔符降低把无关数字误当倍率的概率
        //    分隔符 = 串首尾 / 空白 / 括号 / 竖线 / 中点 / 冒号 / 连字符
        let delim = #"(?:^|[\s\[\(【（|·:：\-])"#
        let delimEnd = #"(?:$|[\s\]\)】）|·:：\-])"#
        if let v = firstMatch(in: name, pattern: delim + #"([0-9]+(?:\.[0-9]+)?)\s*[xX×]"# + delimEnd) { return v }
        if let v = firstMatch(in: name, pattern: delim + #"[xX×]\s*([0-9]+(?:\.[0-9]+)?)"# + delimEnd) { return v }
        return nil
    }

    private static func firstMatch(in text: String, pattern: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges >= 2,
              let g = Range(m.range(at: 1), in: text),
              let v = Double(text[g]), plausibleRange.contains(v) else { return nil }
        return v
    }
}
