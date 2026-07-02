import Foundation
import QingzhouCore

/// 解析 `vless://uuid@host:port?encryption=none&security=tls&type=ws&...#name` 链接。
enum VLESSParser {
    static func parse(_ urlString: String) throws -> Node {
        guard let comps = URLComponents(string: urlString) else {
            throw ProxyURLParseError.malformedURL
        }
        guard let host = comps.host, !host.isEmpty else { throw ProxyURLParseError.missingHost }
        guard let port = comps.port else { throw ProxyURLParseError.missingPort }
        // URLComponents 的 user / fragment 已 percent-decode，不再二次解码（见 TrojanParser 注释）。
        guard let uuid = comps.user, !uuid.isEmpty else {
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
            protocolType: .vless,
            host: host,
            port: port,
            uuid: uuid,
            parameters: params
        )
    }
}
