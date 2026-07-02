import Foundation
import QingzhouCore

/// 解析 `hysteria2://password@host:port?sni=...&insecure=1#name` 链接，
/// 同时兼容 `hy2://` 别名。
enum Hysteria2Parser {
    static func parse(_ urlString: String) throws -> Node {
        // URLComponents 对自定义 scheme 一般都能解析，hy2 也照样可以
        guard let comps = URLComponents(string: urlString) else {
            throw ProxyURLParseError.malformedURL
        }
        guard let host = comps.host, !host.isEmpty else { throw ProxyURLParseError.missingHost }
        guard let port = comps.port else { throw ProxyURLParseError.missingPort }
        // URLComponents 的 user / fragment 已 percent-decode，不再二次解码（见 TrojanParser 注释）。
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
            protocolType: .hysteria2,
            host: host,
            port: port,
            password: password,
            parameters: params
        )
    }
}
