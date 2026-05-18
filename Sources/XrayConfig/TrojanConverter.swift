// TrojanConverter
//
// Node → xray-core trojan outbound JSON。
//
// xray-core trojan outbound 结构（参考 xtls/xray-core/proxy/trojan）：
//   {
//     "protocol": "trojan",
//     "settings": {
//       "servers": [{"address": "...", "port": 443, "password": "..."}]
//     },
//     "streamSettings": {
//       "network": "tcp" | "ws" | "grpc" | "h2" | ...,
//       "security": "tls" | "reality" | "none",
//       "tlsSettings": { "serverName": ..., "allowInsecure": ..., "alpn": ..., "fingerprint": ... },
//       "wsSettings": { "path": ..., "headers": { "Host": ... } },
//       ...
//     }
//   }
// trojan 默认 security 是 "tls" —— 没有加密的 trojan 几乎一定是配置错误，但仍然允许显式
// 在 share link 里 `security=none` 关掉。

import Foundation
import VPNCore

enum TrojanConverter {

    static func toOutbound(_ node: Node) throws -> [String: Any] {
        guard let password = node.password, !password.isEmpty else {
            throw NodeConverterError.missingPassword
        }

        let server: [String: Any] = [
            "address": node.host,
            "port": node.port,
            "password": password
        ]

        let streamSettings = try StreamSettingsBuilder.build(node: node, defaultSecurity: "tls")

        return [
            "protocol": "trojan",
            "settings": [
                "servers": [server]
            ],
            "streamSettings": streamSettings
        ]
    }
}
