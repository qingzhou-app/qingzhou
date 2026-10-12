import Foundation

/// 受支持的代理协议。新增协议时同步更新 `QingzhouProtocols` 模块的解析器。
public enum ProxyProtocol: String, Codable, Sendable, CaseIterable {
    case trojan
    case shadowsocks
    case vmess
    case vless
    case hysteria2

    /// Hysteria2只要求QUIC/UDP监听，TCP握手不能用于判断它是否可用。
    public var supportsTCPProbe: Bool { self != .hysteria2 }

    /// URL scheme（不含 `://`）。`shadowsocks` 在链接中是 `ss`。
    public var urlScheme: String {
        switch self {
        case .trojan:      return "trojan"
        case .shadowsocks: return "ss"
        case .vmess:       return "vmess"
        case .vless:       return "vless"
        case .hysteria2:   return "hysteria2"
        }
    }

    /// 反查：URL scheme → 协议。`hy2` 视为 `hysteria2` 的别名。
    public static func from(scheme: String) -> ProxyProtocol? {
        switch scheme.lowercased() {
        case "trojan":              return .trojan
        case "ss":                  return .shadowsocks
        case "vmess":               return .vmess
        case "vless":               return .vless
        case "hysteria2", "hy2":    return .hysteria2
        default:                    return nil
        }
    }
}
