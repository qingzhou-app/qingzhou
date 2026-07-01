// NodeConverter
//
// 把 Swift `Node` 直接转成 xray-core 的 outbound JSON。
//
// 为什么不直接调 libXray.ConvertShareLinksToXrayJson？
// - libXray 是 gomobile bind 出来的、几十 MB 的 binary。能不让它进主 App 二进制就别让它进。
// - libXray 在某些 share link 上有 bug（实测的 sendThrough 把 fragment 当本地 IP 那次）。
//   自己写一份给应用层更精确的控制和确定性的字段映射。
// - 测试友好：Swift 转换器能在普通单测里跑；libXray 那条路要拖 Go runtime + xcframework。
//
// 当前覆盖：trojan / vmess / vless / shadowsocks / hysteria2 五个协议全部走原生转换。
// 输出格式：与 libXray.convertShareLinks 一致 ——
//   {"outbounds": [{"protocol": "...", "settings": {...}, "streamSettings": {...}}]}
// 之后 XrayConfigComposer 在这个 outbounds 数组外面套上 tun inbound + routing + dns。

import Foundation
import VPNCore

public enum NodeConverterError: Swift.Error, LocalizedError, Equatable {
    case missingPassword
    case missingUUID
    case missingCipher
    case invalidPort(Int)
    case unsupportedProtocol(String)
    case unsupportedTransport(String)

    public var errorDescription: String? {
        switch self {
        case .missingPassword:           return "节点缺少 password 字段"
        case .missingUUID:               return "节点缺少 uuid 字段"
        case .missingCipher:             return "节点缺少 cipher / encryption 字段"
        case let .invalidPort(p):        return "节点端口非法：\(p)"
        case let .unsupportedProtocol(s):  return "暂不支持的协议：\(s)"
        case let .unsupportedTransport(s): return "暂不支持的 transport：\(s)"
        }
    }
}

/// 入口：根据 `Node.protocolType` 分发到对应协议转换器，再包成 `{"outbounds": [...]}` 顶层。
public enum NodeConverter {

    /// 输出顶层 JSON，等价于 libXray.convertShareLinks 的产物。
    /// 之后喂给 `XrayConfigComposer.compose(outboundsJSON:mode:)` 包出完整 xray 配置。
    public static func toOutboundsJSON(_ node: Node) throws -> String {
        let outbound = try toOutboundDict(node)
        let payload: [String: Any] = ["outbounds": [outbound]]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 给单元测试 / XrayConfigComposer 用的字典形式（避免双重 JSON 序列化）。
    public static func toOutboundDict(_ node: Node) throws -> [String: Any] {
        guard (1...65535).contains(node.port) else {
            throw NodeConverterError.invalidPort(node.port)
        }
        switch node.protocolType {
        case .trojan:       return try TrojanConverter.toOutbound(node)
        case .vmess:        return try VMessConverter.toOutbound(node)
        case .vless:        return try VLESSConverter.toOutbound(node)
        case .shadowsocks:  return try ShadowsocksConverter.toOutbound(node)
        case .hysteria2:    return try Hysteria2Converter.toOutbound(node)
        }
    }
}
