import Foundation
import QingzhouCore

/// 把 `Node` 反序列化成 `trojan:// / vmess:// / ...` 分享链接形式 —— `ProxyURLParser.parse`
/// 的反方向。与各协议 Parser 同住 QingzhouProtocols，字段映射一一对应，round-trip 有单测保证：
/// `parse(shareLink(node))` 的语义字段（协议/主机/端口/凭据/参数/名称）与原 node 一致。
///
/// 调用方主要有三个：
///   1. QR 分享 / 复制分享链接 / 批量导出 UI
///   2. 启动 VPN 时把 Node 喂给 xray-core 之前先转 share link（libXray fallback 通道）
public enum NodeEncoder {

    /// 把节点编码成可分享的链接字符串。失败返回 nil（极少发生 —— 主要是 URL 字段无法 percent-encode）。
    public static func shareLink(_ node: Node) -> String? {
        var queryItems: [URLQueryItem] = []
        for (k, v) in node.parameters.sorted(by: { $0.key < $1.key }) {
            queryItems.append(URLQueryItem(name: k, value: v))
        }
        var comps = URLComponents()
        comps.scheme = node.protocolType.urlScheme
        comps.host = node.host
        comps.port = node.port
        if !queryItems.isEmpty { comps.queryItems = queryItems }
        comps.fragment = node.name

        switch node.protocolType {
        case .trojan, .hysteria2:
            comps.percentEncodedUser = node.password.flatMap(Self.strictEncode)
            return comps.url?.absoluteString
        case .vless:
            comps.percentEncodedUser = node.uuid.flatMap(Self.strictEncode)
            return comps.url?.absoluteString
        case .shadowsocks:
            // SIP002 形式：ss://base64url(method:password)@host:port#name
            // 用 URL-safe 无 padding 的 base64（SIP002 惯例）：标准 base64 的 `+ / =` 在
            // userinfo 里非法，URLComponents 会 percent-encode 成 %2B%2F%3D，而各家解析器
            //（包括我们自己的 ShadowsocksParser）都是先按 `@` 切再直接 base64 解码、
            // 不做 percent-decode —— 带 % 的形式 round-trip 必挂。
            let credential = "\(node.cipher ?? ""):\(node.password ?? "")"
            let b64url = Data(credential.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            comps.user = b64url
            return comps.url?.absoluteString
        case .vmess:
            // vmess://base64(json) 形式 —— v2rayN 兼容字段集合。
            // "v" 是链接格式版本号，不属于节点参数（VMessParser 也不会把它存进 parameters）。
            var json: [String: Any] = [
                "v": "2",
                "ps": node.name,
                "add": node.host,
                "port": "\(node.port)",
                "id": node.uuid ?? "",
                "aid": node.alterId ?? 0,
                "scy": node.cipher ?? "auto"
            ]
            for (k, v) in node.parameters where k != "v" { json[k] = v }
            guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return nil }
            return "vmess://" + data.base64EncodedString()
        }
    }

    /// 批量导出：每行一条分享链接（跳过编码失败的节点）。产物可直接粘贴回「添加节点」
    /// 或任何支持 v2rayN 订阅明文格式的客户端。
    public static func shareLinks(_ nodes: [Node]) -> String {
        nodes.compactMap { shareLink($0) }.joined(separator: "\n")
    }

    /// userinfo（密码 / uuid）的严格 percent-encode：只放行 RFC 3986 unreserved 字符。
    /// 不能用 `comps.user = ...`（宽松编码）—— 密码里的 `:` 在 userinfo 里是合法字符
    /// 不会被转义，结果被各家解析器（含我们自己）当成 user:password 分隔符截断。
    private static func strictEncode(_ s: String) -> String? {
        s.addingPercentEncoding(withAllowedCharacters: Self.unreserved)
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
