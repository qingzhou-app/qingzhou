import Foundation
import QingzhouCore
import QingzhouProtocols

/// 订阅响应体解析器（无网络副作用，便于单测）。
public enum SubscriptionParser {
    /// 解析订阅响应体。订阅源主流编码方式：
    /// 1. 整体 base64，解码后是按行分隔的链接；
    /// 2. 明文按行分隔的链接（部分订阅商如 yizhihongxing 也支持这种）；
    /// 3. 单个明文链接（手动添加单服务器场景）；
    /// 4. **Clash / Mihomo / Stash YAML 配置**（含 `proxies:` 顶层 key）；
    /// 5. **SIP008 在线配置 JSON**（Outline / 部分 SS 机场，含 `servers` 数组）。
    ///
    /// 策略：先嗅探 Clash YAML（最特征明显）→ 再嗅探 SIP008 JSON → 都不是才走 base64/明文链接路径。
    /// 结果里带 `formatRecognized`，用来区分「订阅确实为空」和「格式无法识别」。
    public static func parse(body: String, userInfoHeader: String? = nil) -> SubscriptionPayload {
        let info = userInfoHeader.map(SubscriptionUserInfo.parse)

        // 优先识别 Clash YAML
        if ClashConfigParser.isClashConfig(body) {
            do {
                let (nodes, errs) = try ClashConfigParser.parse(body)
                let failedLines = errs.map { (line: $0.name, error: NSError(
                    domain: "ClashConfig", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: $0.reason]
                ) as Error) }
                return SubscriptionPayload(nodes: nodes, failedLines: failedLines, userInfo: info,
                                           formatRecognized: true)
            } catch {
                // 解析失败就 fall through 到后续路径
            }
        }

        // 再识别 SIP008 JSON（trim 后以 `{` 开头，且能 decode 出 servers 数组）
        if SIP008Parser.looksLikeSIP008(body),
           let (nodes, errs) = try? SIP008Parser.parse(body) {
            let failedLines = errs.map { (line: $0.name, error: NSError(
                domain: "SIP008", code: -1,
                userInfo: [NSLocalizedDescriptionKey: $0.reason]
            ) as Error) }
            return SubscriptionPayload(nodes: nodes, failedLines: failedLines, userInfo: info,
                                       formatRecognized: true)
        }

        let text = decodeIfBase64(body)
        let (nodes, errors) = ProxyURLParser.parseBatch(text)
        // 认定「格式已识别」的条件：解出了节点，或原文含 `://`（是链接列表，只是可能有坏行）。
        // 两者都不满足 = 既不是 Clash / SIP008、又不是链接列表 → 格式无法识别。
        let recognized = !nodes.isEmpty || text.contains("://")
        return SubscriptionPayload(nodes: nodes, failedLines: errors, userInfo: info,
                                   formatRecognized: recognized)
    }

    /// 启发式：去掉空白后，如果整段看起来像 base64 且能解码，就解码，否则按原样返回。
    static func decodeIfBase64(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // 含 "://" 几乎可以肯定是明文链接
        if trimmed.contains("://") { return body }
        // 长度过短或含明显非 base64 字符，跳过
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=-_\n\r ")
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return body
        }
        if let decoded = String.fromPermissiveBase64(trimmed) {
            return decoded
        }
        return body
    }
}
