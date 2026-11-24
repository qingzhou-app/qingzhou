import Foundation
import QingzhouCore

/// 解析 `socks5://user:pass@host:port#name` 形式的链接。
///
/// 用户名 / 密码都是可选的：无认证的 SOCKS5（`socks5://host:port`）在局域网 / 内网场景仍常见，
/// 直接拒绝会让用户没法把内网 socks 当直连出口用。认证只要给了一半（有 user 无 pass 或有
/// pass 无 user）就是配置错误 —— 那种链接多半是密码里带 `@` 忘了转义，静默当无认证处理会
/// 变成「连得上但代理拒绝」，比报错更难查。
enum Socks5Parser {
    static func parse(_ urlString: String) throws -> Node {
        guard let comps = URLComponents(string: urlString) else {
            throw ProxyURLParseError.malformedURL
        }
        guard let host = comps.host, !host.isEmpty else { throw ProxyURLParseError.missingHost }
        guard let port = comps.port else { throw ProxyURLParseError.missingPort }

        // URLComponents 取出的 user / password 已 percent-decode，不能再解一次（同 TrojanParser）。
        let user = comps.user
        let pass = comps.password
        if (user?.isEmpty == false) != (pass?.isEmpty == false) {
            throw ProxyURLParseError.missingCredential
        }

        var params: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            guard let v = item.value, !v.isEmpty else { continue }
            params[item.name] = v
        }

        let name = (comps.fragment?.removingPercentEncoding ?? comps.fragment) ?? "\(host):\(port)"
        return Node(
            name: name,
            protocolType: .socks5,
            host: host,
            port: port,
            password: (pass?.isEmpty == false) ? pass : nil,
            parameters: params.merging(
                (user?.isEmpty == false) ? ["username": user!] : [:],
                uniquingKeysWith: { first, _ in first }
            )
        )
    }
}
