import Foundation
import QingzhouCore

/// 解析 `trojan://password@host:port?sni=...&type=...#name` 形式的链接。
enum TrojanParser {
    static func parse(_ urlString: String) throws -> Node {
        guard let comps = URLComponents(string: urlString) else {
            throw ProxyURLParseError.malformedURL
        }
        guard let host = comps.host, !host.isEmpty else { throw ProxyURLParseError.missingHost }
        guard let port = comps.port else { throw ProxyURLParseError.missingPort }
        // ⚠️ URLComponents 的 user / fragment 取出来**已经是 percent-decode 过的**，
        // 不能再 removingPercentEncoding 一次 —— 密码里真含 "%20" / 孤立 "%" 时
        // 双重解码会把它改掉甚至解成 nil（round-trip 单测抓出来的坑）。
        guard let password = comps.user, !password.isEmpty else {
            throw ProxyURLParseError.missingCredential
        }
        let name = comps.fragment ?? "\(host):\(port)"
        let params = Dictionary(
            (comps.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let v = item.value else { return nil }
                return (item.name, v)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return Node(
            name: name,
            protocolType: .trojan,
            host: host,
            port: port,
            password: password,
            parameters: params
        )
    }
}
