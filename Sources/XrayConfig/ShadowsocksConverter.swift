// ShadowsocksConverter
//
// Node → xray-core shadowsocks outbound JSON。
//
// xray-core shadowsocks outbound 结构（参考 xtls/xray-core/proxy/shadowsocks）：
//   {
//     "protocol": "shadowsocks",
//     "settings": {
//       "servers": [{
//         "address": "...",
//         "port": 8388,
//         "method": "aes-256-gcm",
//         "password": "..."
//       }]
//     }
//   }
//
// 注意：
// - shadowsocks 一般不带 streamSettings —— TCP 直连，加密在协议层。这点跟 trojan/vmess/vless 不同。
// - 如果将来要支持 SIP003 plugin（v2ray-plugin / obfs-local），在 settings.servers[] 里加
//   `"plugin": ..., "pluginOpts": ...` 即可；当前 MVP 不实现。

import Foundation
import VPNCore

enum ShadowsocksConverter {

    static func toOutbound(_ node: Node) throws -> [String: Any] {
        guard let password = node.password, !password.isEmpty else {
            throw NodeConverterError.missingPassword
        }
        guard let cipher = node.cipher, !cipher.isEmpty else {
            throw NodeConverterError.missingCipher
        }

        let server: [String: Any] = [
            "address": node.host,
            "port": node.port,
            "method": cipher,
            "password": password
        ]

        return [
            "protocol": "shadowsocks",
            "settings": [
                "servers": [server]
            ]
        ]
    }
}
