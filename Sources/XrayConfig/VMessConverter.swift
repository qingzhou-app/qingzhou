// VMessConverter
//
// Node → xray-core vmess outbound JSON。
//
// xray-core vmess outbound 结构：
//   {
//     "protocol": "vmess",
//     "settings": {
//       "vnext": [{
//         "address": "...",
//         "port": 443,
//         "users": [{
//           "id": "<uuid>",
//           "alterId": 0,
//           "security": "auto" | "aes-128-gcm" | "chacha20-poly1305" | "none" | "zero"
//         }]
//       }]
//     },
//     "streamSettings": { ... }   // 同 trojan
//   }
//
// 注意区分两个 "security"：
//   - settings.vnext[].users[].security：vmess 协议层的加密方式（对应 share link 的 `scy`）
//   - streamSettings.security：传输层的安全（"tls" / "reality" / "none"）
// 这两个完全独立，新人最容易搞混。

import Foundation
import VPNCore

enum VMessConverter {

    static func toOutbound(_ node: Node) throws -> [String: Any] {
        guard let uuid = node.uuid, !uuid.isEmpty else {
            throw NodeConverterError.missingUUID
        }

        var user: [String: Any] = [
            "id": uuid,
            "alterId": node.alterId ?? 0,
            "security": node.cipher ?? "auto"
        ]
        // 部分订阅会带 fingerprint —— 实际 xray-core 不读 user 里的 fingerprint，
        // 但留着不影响（vnext 里多余 key 被忽略）。
        if let fp = node.parameters["fp"], !fp.isEmpty {
            user["fingerprint"] = fp
        }

        let server: [String: Any] = [
            "address": node.host,
            "port": node.port,
            "users": [user]
        ]

        let streamSettings = try StreamSettingsBuilder.build(node: node, defaultSecurity: "none")

        return [
            "protocol": "vmess",
            "settings": [
                "vnext": [server]
            ],
            "streamSettings": streamSettings
        ]
    }
}
