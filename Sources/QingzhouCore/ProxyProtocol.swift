import Foundation

/// 受支持的代理协议。新增协议时同步更新 `QingzhouProtocols` 模块的解析器。
public enum ProxyProtocol: String, Codable, Sendable, CaseIterable {
    case trojan
    case shadowsocks
    case vmess
    case vless
    case hysteria2
    /// SOCKS5（含用户名/密码认证）。静态住宅代理通常是这个协议，只能当出站用。
    case socks5

    /// Hysteria2只要求QUIC/UDP监听，TCP握手不能用于判断它是否可用。
    /// SOCKS5 站点的 TCP 握手同样不代表能完成代理认证，但它是 TCP 协议，TCP 可达性
    /// 仍是有意义的初筛（真正的可用性判定要走一次认证请求，由代理探测完成）。
    public var supportsTCPProbe: Bool { self != .hysteria2 }

    /// URL scheme（不含 `://`）。`shadowsocks` 在链接中是 `ss`。
    public var urlScheme: String {
        switch self {
        case .trojan:      return "trojan"
        case .shadowsocks: return "ss"
        case .vmess:       return "vmess"
        case .vless:       return "vless"
        case .hysteria2:   return "hysteria2"
        case .socks5:      return "socks5"
        }
    }

    /// 反查：URL scheme → 协议。`hy2` 视为 `hysteria2` 的别名。
    public static func from(scheme: String) -> ProxyProtocol? {
        switch scheme.lowercased() {
        case "trojan":                    return .trojan
        case "ss":                        return .shadowsocks
        case "vmess":                     return .vmess
        case "vless":                     return .vless
        case "hysteria2", "hy2":          return .hysteria2
        // `socks` / `socks5h` 都是 SOCKS5 的常见写法（h 后缀表示由代理解析域名，
        // 对 xray 出站无差别：目标域名一律交给 SOCKS5 服务器解析）。
        case "socks5", "socks", "socks5h": return .socks5
        default:                          return nil
        }
    }
}
