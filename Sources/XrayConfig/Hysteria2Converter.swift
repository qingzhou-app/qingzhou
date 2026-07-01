// Hysteria2Converter
//
// Node → xray-core hysteria2 outbound JSON。
//
// 我们打包的这版 xray-core 是带 hysteria 传输的 fork（xcframework 符号里能看到
// proxy/hysteria、HysteriaClientConfig、hysteriaSettings、Xray.Transport.Internet.Hysteria）。
// 它把 hysteria2 拆成「协议段 + 传输段」两块配置，跟 trojan/vmess 那种"协议在 settings、
// 传输细节在 streamSettings"的写法不一样 —— 鉴权口令甚至跑到了 streamSettings 里：
//
//   {
//     "protocol": "hysteria",                 // ← 协议名是 "hysteria"，不是 "hysteria2"
//     "settings": {                           //   = infra/conf HysteriaClientConfig
//       "version": 2,                         //   version 必须是 2，否则 Build() 直接报 "version != 2"
//       "address": "1.2.3.4",
//       "port": 443
//     },
//     "streamSettings": {
//       "network": "hysteria",
//       "security": "tls",                    //   hysteria 跑在 QUIC 上，TLS 是硬性要求
//       "tlsSettings": { "serverName": "...", "alpn": ["h3"] },
//       "hysteriaSettings": {                 //   = infra/conf HysteriaConfig
//         "version": 2,                       //   这里 version 也必须是 2
//         "auth": "<password>"                //   ★ 鉴权口令在这里，settings 里不放密码
//       }
//     }
//   }
//
// 几个容易踩的坑（都对应 xray-core 源码 infra/conf/{hysteria.go,transport_internet.go}）：
// - 口令(auth)只认 streamSettings.hysteriaSettings.auth；settings 里不带 password。
// - settings 和 hysteriaSettings 两处 version 都得填 2，缺一个 xray 起不来。
// - **绝不 emit allowInsecure**：跟其它四个协议一样，这版 xray-core 移除了该字段。hy2 链接里
//   常带 insecure=1（自签证书），这里一律丢掉 —— 真要跳过校验得用 pinnedPeerCertSha256，
//   但 share link 给不了证书指纹。（XrayConfigComposer 还会递归再剥一层兜底。）
// - ALPN 固定 h3：hysteria2 协议层就是 HTTP/3 over QUIC；链接显式给了 alpn 才尊重它。
// - Salamander obfs：本 fork 的 HysteriaConfig 结构体里没有 obfs 字段，无法表达 —— 带 obfs
//   的节点这条路只能当普通 hy2 跑（多写的 key xray 会忽略），真要 obfs 暂不支持。

import Foundation
import VPNCore

enum Hysteria2Converter {

    static func toOutbound(_ node: Node) throws -> [String: Any] {
        guard let password = node.password, !password.isEmpty else {
            throw NodeConverterError.missingPassword
        }
        let p = node.parameters

        // —— settings：HysteriaClientConfig（只装 server endpoint + version，不放口令）——
        let settings: [String: Any] = [
            "version": 2,
            "address": node.host,
            "port": node.port
        ]

        // —— streamSettings.tlsSettings ——
        // SNI 别名跟 StreamSettingsBuilder.buildTLSSettings 保持一致：sni / peer / host，退节点 host。
        var tls: [String: Any] = [
            "serverName": p["sni"] ?? p["peer"] ?? p["host"] ?? node.host
        ]
        // ALPN：hysteria2 = HTTP/3 over QUIC，默认 h3；链接显式声明了就用链接的。
        if let alpnStr = p["alpn"], !alpnStr.isEmpty {
            tls["alpn"] = alpnStr.split(separator: ",").map { String($0) }
        } else {
            tls["alpn"] = ["h3"]
        }
        if let fp = p["fp"], !fp.isEmpty {
            tls["fingerprint"] = fp
        }
        // 注意：这里**没有**也不能有 allowInsecure —— 见文件头注释。

        // —— streamSettings.hysteriaSettings：HysteriaConfig ——
        var hysteria: [String: Any] = [
            "version": 2,
            "auth": password
        ]
        // udpIdleTimeout 选填，xray 要求落在 2...600（否则 Build() 报错）；链接里几乎不会带，
        // 带了且合法才透传，非法值直接忽略让 xray 用默认 60。
        if let raw = p["udpIdleTimeout"], let t = Int(raw), (2...600).contains(t) {
            hysteria["udpIdleTimeout"] = t
        }

        let streamSettings: [String: Any] = [
            "network": "hysteria",
            "security": "tls",
            "tlsSettings": tls,
            "hysteriaSettings": hysteria
        ]

        return [
            "protocol": "hysteria",
            "settings": settings,
            "streamSettings": streamSettings
        ]
    }
}
