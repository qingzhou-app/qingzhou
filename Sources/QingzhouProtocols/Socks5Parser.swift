import Foundation
import QingzhouCore

/// 解析 SOCKS5 节点链接。支持两种写法：
///
/// 1. 标准 URL：`socks5://user:pass@host:port#name`
/// 2. **服务商四段式**：`host:port:user:pass`（或带 scheme：`socks5://host:port:user:pass`）
///
/// 第 2 种不是合法 URL（`:` 分隔、没有 `@`），但它是静态住宅代理最常见的下发格式 ——
/// 供应商标配的「IP:端口:账号:密码」一行。用户直接粘进来时如果不认，就只能手填四个框，
/// 所以这里显式支持；带不带 scheme 都接受。
///
/// 用户名 / 密码都是可选的：无认证的 SOCKS5（`socks5://host:port`）在局域网仍常见。
/// 认证只要给了一半（有 user 无 pass 或反之）就是配置错误 —— 那多半是密码里的 `@`
/// 忘了转义，静默当无认证会变成「连得上但被代理拒绝」，比报错更难查。
enum Socks5Parser {
    static func parse(_ urlString: String) throws -> Node {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        // 先试四段式：它不满足 URL 语法，必须抢在 URLComponents 之前判掉。
        if let node = parseFourField(trimmed) { return node }

        guard let comps = URLComponents(string: trimmed) else {
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

    /// 解析 `host:port:user:pass`。不是这个形状就返回 nil，交给 URL 那条路。
    ///
    /// 返回 nil 而不是抛错，是为了让「标准 URL」和「四段式」共用同一个入口：
    /// 调用方只需要 `try parse(...)`，不用先判断格式。
    static func parseFourField(_ raw: String) -> Node? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }

        // 尾部 #名称
        var name: String?
        if let hash = s.firstIndex(of: "#") {
            let fragment = String(s[s.index(after: hash)...])
            name = fragment.removingPercentEncoding ?? fragment
            s = String(s[..<hash])
        }
        // 带路径 / 带 @ 的是标准 URL 形状，不是四段式
        if s.contains("/") || s.contains("@") { return nil }

        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // 至少四段；密码里若含 ':' 会多出几段，全归给密码
        guard parts.count >= 4 else { return nil }

        let host = parts[0]
        guard looksLikeHost(host) else { return nil }
        guard let port = Int(parts[1]), (1...65535).contains(port) else { return nil }
        let user = parts[2]
        let pass = parts[3...].joined(separator: ":")
        guard !user.isEmpty, !pass.isEmpty else { return nil }

        return Node(
            name: name?.isEmpty == false ? name! : "\(host):\(port)",
            protocolType: .socks5,
            host: host,
            port: port,
            password: pass,
            parameters: ["username": user]
        )
    }

    /// 四段式里的第一段必须是「主机」：IPv4 / IPv6 / 含点的域名。
    /// 这层校验是为了避免把 `user:pass:extra:x` 这类纯文本误当节点。
    private static func looksLikeHost(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253 else { return false }
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 { return true }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 { return true }
        guard s.contains(".") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
