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
// 几个容易踩的坑（都对应 xray-core v26.6.27 源码 infra/conf/{hysteria.go,transport_internet.go}）：
// - 口令(auth)只认 streamSettings.hysteriaSettings.auth；settings 里不带 password。
// - settings 和 hysteriaSettings 两处 version 都得填 2，缺一个 xray 起不来。
// - **绝不 emit allowInsecure**：跟其它四个协议一样，这版 xray-core 移除了该字段。hy2 链接里
//   常带 insecure=1（自签证书），这里一律丢掉 —— 真要跳过校验得用 pinnedPeerCertSha256(pinSHA256)。
//   （XrayConfigComposer 还会递归再剥一层兜底。）
// - ALPN 固定 h3：hysteria2 协议层就是 HTTP/3 over QUIC；链接显式给了 alpn 才尊重它。
//
// ★ v26.6.27 的 schema 迁移（这次升级的核心原因，见 transport_internet.go）：
//   - congestion / up / down / udphop **移出** hysteriaSettings，进了
//     `streamSettings.finalmask.quicParams`（HysteriaConfig.Build 只对旧位置发
//     deprecation 警告、不再消费）。所以本转换器把 brutal 带宽 / 拥塞控制 / 端口跳跃
//     全写进 quicParams，**不再往 hysteriaSettings 塞这些死键**。
//   - Salamander obfs 由 finalmask 承载：`finalmask.udp = [{type:"salamander",
//     settings:{password:...}}]`（udpmaskLoader 注册了 "salamander" → Salamander 结构，
//     Build 出 salamander.Config）。历史遗留的「带 obfs 的 hy2 握手失败」到此修复。
//
// 端口跳跃：mport（"40000-50000" / "443,8443-8500"）→ quicParams.udpHop.ports（PortList
//   接受逗号+区间字符串）；hopInterval 秒数 → udpHop.interval（xray 硬下限 5s，非法忽略）。

import Foundation
import QingzhouCore

enum Hysteria2Converter {

    static func toOutbound(_ node: Node) throws -> [String: Any] {
        guard let password = node.password, !password.isEmpty else {
            throw NodeConverterError.missingPassword
        }
        let p = node.parameters

        // —— settings：HysteriaClientConfig（只装 server endpoint + version，不放口令）——
        // 端口跳跃时 address/port 仍填主端口，跳跃端口段在 quicParams.udpHop.ports。
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
        // pinSHA256（官方 URI 参数）→ pinnedPeerCertSha256：allowInsecure 移除后的替代，
        // xray 接受冒号分隔 hex（内部会去冒号解码，校验 32 字节）。原样透传。
        if let pin = p["pinSHA256"] ?? p["pinnedPeerCertSha256"], !pin.isEmpty {
            tls["pinnedPeerCertSha256"] = pin
        }
        // 注意：这里**没有**也不能有 allowInsecure —— 见文件头注释。

        // —— streamSettings.hysteriaSettings：HysteriaConfig（v26.6.27 里只剩 version/auth/
        //     udpIdleTimeout/masquerade；congestion/up/down/udphop 已迁走，别再往这写）——
        var hysteria: [String: Any] = [
            "version": 2,
            "auth": password
        ]
        // udpIdleTimeout 选填，xray 要求落在 2...600（否则 Build() 报错）；链接里几乎不会带，
        // 带了且合法才透传，非法值直接忽略让 xray 用默认 60。
        if let raw = p["udpIdleTimeout"], let t = Int(raw), (2...600).contains(t) {
            hysteria["udpIdleTimeout"] = t
        }

        var streamSettings: [String: Any] = [
            "network": "hysteria",
            "security": "tls",
            "tlsSettings": tls,
            "hysteriaSettings": hysteria
        ]

        if let finalmask = try buildFinalMask(p) {
            streamSettings["finalmask"] = finalmask
        }

        return [
            "protocol": "hysteria",
            "settings": settings,
            "streamSettings": streamSettings
        ]
    }

    // MARK: - finalmask（salamander obfs + quicParams：端口跳跃 / brutal 带宽 / 拥塞控制）

    /// 组 streamSettings.finalmask；没有任何相关参数时返回 nil（配置最小化，与旧节点兼容）。
    private static func buildFinalMask(_ p: [String: String]) throws -> [String: Any]? {
        var finalmask: [String: Any] = [:]

        // —— udp masks：salamander obfs ——
        if let obfs = p["obfs"], !obfs.isEmpty {
            guard obfs.lowercased() == "salamander" else {
                // hysteria2 只有 salamander 一种混淆；未知类型显式拒绝，别静默丢成假连接。
                throw NodeConverterError.unsupportedTransport("hysteria2 obfs=\(obfs)")
            }
            guard let obfsPwd = p["obfs-password"] ?? p["obfsPassword"], !obfsPwd.isEmpty else {
                throw NodeConverterError.missingObfsPassword
            }
            finalmask["udp"] = [[
                "type": "salamander",
                "settings": ["password": obfsPwd]
            ]]
        }

        // —— quicParams：端口跳跃 + brutal 带宽 + 拥塞控制 ——
        var quic: [String: Any] = [:]

        // 端口跳跃：mport 是合法端口列表才产出 udpHop（垃圾值整段丢弃）。
        if let mport = p["mport"], isValidPortList(mport) {
            var hop: [String: Any] = ["ports": mport]
            // hopInterval 秒：xray udphop 硬下限 5s（<5 会 panic），非法/越界只丢 interval。
            if let raw = p["hopInterval"] ?? p["hop-interval"], let s = Int(raw), s >= 5 {
                hop["interval"] = s
            }
            quic["udpHop"] = hop
        }

        // brutal 带宽：hysteria2 惯例裸数字按 Mbps；xray Bandwidth 裸数字当 bps（会 <65536 被拒），
        // 所以纯数字补 " mbps"，带单位的字符串小写透传。
        if let up = normalizeBandwidth(p["up"]) { quic["brutalUp"] = up }
        if let down = normalizeBandwidth(p["down"]) { quic["brutalDown"] = down }

        // 拥塞控制白名单（对齐 xray Build 的 switch）：reno / bbr / brutal / force-brutal。
        // force-brutal 需要 up，否则 xray 拒整个配置 → 无 up 时丢掉保配置可用；未知值忽略。
        if let cong = p["congestion"]?.lowercased(), !cong.isEmpty {
            switch cong {
            case "reno", "bbr", "brutal":
                quic["congestion"] = cong
            case "force-brutal":
                if quic["brutalUp"] != nil { quic["congestion"] = cong }
            default:
                break   // 未知拥塞控制忽略
            }
        }

        if !quic.isEmpty { finalmask["quicParams"] = quic }
        return finalmask.isEmpty ? nil : finalmask
    }

    /// 端口列表校验：逗号 + 区间混写，每段端口都在 1...65535。用于过滤垃圾 mport。
    private static func isValidPortList(_ spec: String) -> Bool {
        guard let first = spec.first, let last = spec.last,
              spec.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "," }),
              first.isNumber, last.isNumber
        else { return false }
        // 每个逗号段：单端口或 a-b 区间，端点合法
        for segment in spec.split(separator: ",") {
            let bounds = segment.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 1 || bounds.count == 2 else { return false }
            for b in bounds {
                guard let n = Int(b), (1...65535).contains(n) else { return false }
            }
            if bounds.count == 2,
               let lo = Int(bounds[0]), let hi = Int(bounds[1]), lo > hi { return false }
        }
        return true
    }

    /// brutal 带宽归一化：nil/空 → nil；纯数字 → "N mbps"；带单位 → 小写透传。
    private static func normalizeBandwidth(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.allSatisfy({ $0.isNumber || $0 == "." }) {
            return "\(trimmed) mbps"
        }
        return trimmed.lowercased()
    }
}
