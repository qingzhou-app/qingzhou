import Foundation
import QingzhouCore

public enum ProxyURLParseError: Error, Equatable, Sendable {
    case unsupportedScheme(String)
    /// 识别得出、但 xray-core 无出站实现的协议（SSR / TUIC）。与 `unsupportedScheme`（纯未知 scheme）
    /// 区分开：给用户「暂不支持该协议」的可读提示，而不是静默丢弃或含糊的未知类型。
    case unsupportedProtocol(name: String)
    case malformedURL
    case missingHost
    case missingPort
    case missingCredential
    case invalidPort(String)
    case invalidBase64
    case invalidJSON(String)
}

extension ProxyURLParseError: CustomStringConvertible {
    /// 面向用户的中文可读信息（UI 用 `String(describing:)` 展示解析失败原因）。
    public var description: String {
        switch self {
        case let .unsupportedScheme(s):    return "不支持的链接类型：\(s)"
        case let .unsupportedProtocol(n):  return "暂不支持 \(n) 协议（xray-core v26.6.27 未原生支持，无法作为出站）"
        case .malformedURL:                return "链接格式错误"
        case .missingHost:                 return "缺少服务器地址"
        case .missingPort:                 return "缺少端口"
        case .missingCredential:           return "缺少密码 / 凭证"
        case let .invalidPort(p):          return "非法端口：\(p)"
        case .invalidBase64:               return "Base64 解码失败"
        case let .invalidJSON(m):          return "JSON 解析失败：\(m)"
        }
    }
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
            // 识别得出但 xray-core 不支持的协议 → 明确的「暂不支持」，别混进未知 scheme 静默处理
            if let name = unsupportedProtocolName(for: scheme) {
                throw ProxyURLParseError.unsupportedProtocol(name: name)
            }
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

    /// 已知但 xray-core v26.6.27 无出站实现的协议 → 返回展示名，供「暂不支持」提示；否则 nil。
    /// SSR：auth_chain / obfs 插件族，xray-core 只实现标准 Shadowsocks（含 ss-2022），无 SSR。
    /// TUIC：基于 QUIC，sing-box / tuic 客户端专属，xray-core 无此出站。
    private static func unsupportedProtocolName(for scheme: String) -> String? {
        switch scheme.lowercased() {
        case "ssr", "shadowsocksr": return "SSR"
        case "tuic":                return "TUIC"
        default:                    return nil
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
