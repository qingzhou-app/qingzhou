import Foundation
import QingzhouCore

public enum ProxyURLParseError: Error, Equatable, Sendable {
    case unsupportedScheme(String)
    case malformedURL
    case missingHost
    case missingPort
    case missingCredential
    case invalidPort(String)
    case invalidBase64
    case invalidJSON(String)
}

/// 协议链接解析入口。根据 URL scheme 分发到具体协议解析器。
public enum ProxyURLParser {
    /// 解析单条节点链接。
    public static func parse(_ urlString: String) throws -> Node {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.range(of: "://") else {
            throw ProxyURLParseError.malformedURL
        }
        let scheme = String(trimmed[..<schemeEnd.lowerBound])
        guard let proto = ProxyProtocol.from(scheme: scheme) else {
            throw ProxyURLParseError.unsupportedScheme(scheme)
        }
        do {
            return try dispatch(proto, trimmed)
        } catch ProxyURLParseError.malformedURL {
            // 兜底：分享链接的 `#名称` 段常含未编码 emoji/中文。iOS 17+/macOS 14+ 的 Foundation
            // 已足够宽松能容忍，但严格 Foundation（如 Linux swift-corelibs）会对裸 fragment
            // 让 `URLComponents(string:)` 整条返回 nil → 抛 malformedURL → 节点被丢。
            // 把 fragment 预编码后重试一次，别为了名字丢掉整个可用节点。
            let retried = fragmentEncoded(trimmed)
            guard retried != trimmed else { throw ProxyURLParseError.malformedURL }
            return try dispatch(proto, retried)
        }
    }

    private static func dispatch(_ proto: ProxyProtocol, _ url: String) throws -> Node {
        switch proto {
        case .trojan:      return try TrojanParser.parse(url)
        case .shadowsocks: return try ShadowsocksParser.parse(url)
        case .vmess:       return try VMessParser.parse(url)
        case .vless:       return try VLESSParser.parse(url)
        case .hysteria2:   return try Hysteria2Parser.parse(url)
        }
    }

    /// 把 URL 里第一个 `#` 之后的 fragment（节点名）百分号编码，使 `URLComponents(string:)`
    /// 在严格 Foundation 下也能解析出 name（含裸 emoji/中文）。
    /// 已经是 `%xx` 的转义保持不动（allowed 含 `%`，不双重编码）；没有 `#` 原样返回。
    static func fragmentEncoded(_ url: String) -> String {
        guard let hashIdx = url.firstIndex(of: "#") else { return url }
        let base = String(url[..<hashIdx])
        let frag = String(url[url.index(after: hashIdx)...])
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.insert(charactersIn: "%")
        let encoded = frag.addingPercentEncoding(withAllowedCharacters: allowed) ?? frag
        return base + "#" + encoded
    }

    /// 解析一批链接（每行一条），忽略空行和无法识别的行；返回成功解析到的节点。
    public static func parseBatch(_ text: String) -> (nodes: [Node], errors: [(String, Error)]) {
        var nodes: [Node] = []
        var errors: [(String, Error)] = []
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            do {
                nodes.append(try parse(line))
            } catch {
                errors.append((line, error))
            }
        }
        return (nodes, errors)
    }
}
