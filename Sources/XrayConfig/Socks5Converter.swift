// Socks5Converter
//
// Node → xray-core SOCKS5 出站 JSON。
//
// xray-core socks 出站结构（xtls/xray-core/proxy/socks/config.proto → ClientConfig）：
//   {
//     "protocol": "socks",
//     "settings": {
//       "servers": [{
//         "address": "1.2.3.4",
//         "port": 1080,
//         "users": [{"user": "u", "pass": "p"}]   // 可省略 = 无认证
//       }]
//     }
//   }
//
// ⚠️ `proxy/socks` 的 `udp` 字段属于 **ServerConfig（入站）**，客户端侧没有 UDP 开关 ——
// 想「关掉某个 SOCKS5 出口的 UDP」只能靠 routing 的 network 限定（见 SplitExitPlan），
// 不是在这里加字段。写错成 settings.udp 会被 xray 当未知字段忽略/报错，且看不出原因。
//
// 本文件不处理链式代理：`dialerProxy` 属于传输层 sockopt，由 SplitExitPlan 统一注入，
// 这样同一份 socks 出站既能直连也能经跳板，不必复制两份转换逻辑。

import Foundation
import QingzhouCore

enum Socks5Converter {

    static func toOutbound(_ node: Node) throws -> [String: Any] {
        var server: [String: Any] = [
            "address": node.host,
            "port": node.port
        ]
        if let user = node.parameters["username"], !user.isEmpty,
           let pass = node.password, !pass.isEmpty {
            server["users"] = [["user": user, "pass": pass]]
        }
        return [
            "protocol": "socks",
            "settings": ["servers": [server]]
        ]
    }
}
