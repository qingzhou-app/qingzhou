// VLESSConverter
//
// Node → xray-core vless outbound JSON。
//
// xray-core vless outbound 结构（参考 xtls/xray-core/proxy/vless）：
//   {
//     "protocol": "vless",
//     "settings": {
//       "vnext": [{
//         "address": "...",
//         "port": 443,
//         "users": [{
//           "id": "<uuid>",
//           "encryption": "none",
//           "flow": "xtls-rprx-vision"   // 仅 REALITY / TLS 才有
//         }]
//       }]
//     },
//     "streamSettings": { ... }   // 同 trojan / vmess
//   }
//
// vless 跟 vmess 的差别：
// - settings.users[].encryption 是固定 "none"（vless 协议本身没加密，安全靠 transport TLS）
// - 多了一个 flow 字段（XTLS Vision），现在大家几乎都用 xtls-rprx-vision
// - REALITY 是 vless 的常见伴生，参数 pbk/sid/spx 由 StreamSettingsBuilder.buildREALITYSettings 处理

import Foundation
import VPNCore

enum VLESSConverter {

    static func toOutbound(_ node: Node) throws -> [String: Any] {
        guard let uuid = node.uuid, !uuid.isEmpty else {
            throw NodeConverterError.missingUUID
        }

        var user: [String: Any] = [
            "id": uuid,
            "encryption": node.parameters["encryption"] ?? "none"
        ]
        if let flow = node.parameters["flow"], !flow.isEmpty {
            user["flow"] = flow
        }

        let server: [String: Any] = [
            "address": node.host,
            "port": node.port,
            "users": [user]
        ]

        // vless 默认 security 跟 vmess 一样是 "none" —— 用户必须显式写 `security=tls` / `security=reality`
        let streamSettings = try StreamSettingsBuilder.build(node: node, defaultSecurity: "none")

        return [
            "protocol": "vless",
            "settings": [
                "vnext": [server]
            ],
            "streamSettings": streamSettings
        ]
    }
}
