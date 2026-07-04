import Foundation
import QingzhouCore

/// 解析 `ss://` 链接。两种格式：
/// - SIP002:  `ss://base64(method:password)@host:port/?plugin=...#name`
/// - Legacy:  `ss://base64(method:password@host:port)#name`
enum ShadowsocksParser {
    static func parse(_ urlString: String) throws -> Node {
        // 把 fragment 切出来单独处理，避免它干扰 base64 内容
        let (body, fragment) = splitFragment(urlString)
        guard body.hasPrefix("ss://") else { throw ProxyURLParseError.malformedURL }
        let rest = String(body.dropFirst("ss://".count))

        if rest.contains("@") {
            return try parseSIP002(rest: rest, fragment: fragment)
        } else {
            return try parseLegacy(rest: rest, fragment: fragment)
        }
    }

    private static func splitFragment(_ s: String) -> (String, String?) {
        if let idx = s.firstIndex(of: "#") {
            let frag = String(s[s.index(after: idx)...]).removingPercentEncoding ?? String(s[s.index(after: idx)...])
            return (String(s[..<idx]), frag)
        }
        return (s, nil)
    }

    private static func parseSIP002(rest: String, fragment: String?) throws -> Node {
        // 形如 `userInfoBase64@host:port/?query`
        guard let atIdx = rest.firstIndex(of: "@") else { throw ProxyURLParseError.malformedURL }
        let userInfoB64 = String(rest[..<atIdx])
        let remainder = String(rest[rest.index(after: atIdx)...])

        // userinfo 优先按 base64(method:password) 解；解不出再按**明文** method:password 兜底。
        // ss-2022（`2022-blake3-*:password`）与部分面板导出的 SIP002 是明文 userinfo，
        // 含 `:`/`-` 不是合法 base64 —— 旧实现只认 base64 会把整批 ss 节点丢掉（机场兼容审计 P0）。
        let method: String
        let password: String
        if let decoded = String.fromPermissiveBase64(userInfoB64), let colon = decoded.firstIndex(of: ":") {
            method = String(decoded[..<colon])
            password = String(decoded[decoded.index(after: colon)...])
        } else {
            let plain = userInfoB64.removingPercentEncoding ?? userInfoB64
            guard let colon = plain.firstIndex(of: ":") else { throw ProxyURLParseError.invalidBase64 }
            method = String(plain[..<colon])
            password = String(plain[plain.index(after: colon)...])
        }

        // 把 remainder 重组成可以让 URLComponents 解析的形式
        guard let comps = URLComponents(string: "ss://placeholder@\(remainder)") else {
            throw ProxyURLParseError.malformedURL
        }
        guard let host = comps.host, !host.isEmpty else { throw ProxyURLParseError.missingHost }
        guard let port = comps.port else { throw ProxyURLParseError.missingPort }
        let params = Dictionary(
            (comps.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let v = item.value else { return nil }
                return (item.name, v)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return Node(
            name: fragment ?? "\(host):\(port)",
            protocolType: .shadowsocks,
            host: host,
            port: port,
            password: password,
            cipher: method,
            parameters: params
        )
    }

    private static func parseLegacy(rest: String, fragment: String?) throws -> Node {
        // 整段是 base64(method:password@host:port)，可能带 query
        // 但 legacy 形式很少带 query，这里只处理基础形式。
        guard let decoded = String.fromPermissiveBase64(rest) else {
            throw ProxyURLParseError.invalidBase64
        }
        guard let atIdx = decoded.firstIndex(of: "@"),
              let colonIdx = decoded[..<atIdx].firstIndex(of: ":") else {
            throw ProxyURLParseError.malformedURL
        }
        let method = String(decoded[..<colonIdx])
        let password = String(decoded[decoded.index(after: colonIdx)..<atIdx])
        let hostPort = decoded[decoded.index(after: atIdx)...]
        guard let portColon = hostPort.lastIndex(of: ":") else {
            throw ProxyURLParseError.missingPort
        }
        let host = String(hostPort[..<portColon])
        let portStr = String(hostPort[hostPort.index(after: portColon)...])
        guard let port = Int(portStr) else { throw ProxyURLParseError.invalidPort(portStr) }
        guard !host.isEmpty else { throw ProxyURLParseError.missingHost }
        return Node(
            name: fragment ?? "\(host):\(port)",
            protocolType: .shadowsocks,
            host: host,
            port: port,
            password: password,
            cipher: method
        )
    }
}
