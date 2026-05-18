// StreamSettingsBuilder
//
// 把 Node.parameters 里 transport / TLS / REALITY 相关的 key 抽出来，组装成 xray-core 的
// `streamSettings` 字典。trojan / vmess / vless 三种协议都依赖这个 helper —— 它们的传输层配置
// 在 xray-core 里是同一套。
//
// 支持的 transport：tcp / ws / grpc / h2 / kcp / quic（kcp/quic 比较少见，只做最小映射）。
// 支持的 security：none / tls / reality / xtls（xtls 已被 xtls-rprx-vision flow 取代，仅留 fallback）。
//
// share link 里这些字段在不同客户端的命名不完全统一，这里尽量覆盖常见别名：
//   - SNI: `sni` / `peer` / `host`
//   - allowInsecure: `allowInsecure` / `skip-cert-verify` / `insecure`
//   - WebSocket path: `path`
//   - WebSocket host header: `host`
//   - gRPC service name: `serviceName` / `path`
//   - ALPN: `alpn` 逗号分隔

import Foundation
import VPNCore

enum StreamSettingsBuilder {

    /// 拼装 streamSettings 字典。defaultSecurity 让每个协议指定"未声明 security 时的默认值"
    /// —— trojan 默认 tls，vmess/vless/ss 默认 none。
    static func build(node: Node, defaultSecurity: String) throws -> [String: Any] {
        let p = node.parameters

        let network = (p["type"] ?? p["net"] ?? "tcp").lowercased()
        let security = (p["security"] ?? p["tls"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultSecurity).lowercased()
        // 个别 vmess 链接里 tls 写的是 "tls"/"none"/"reality"，跟 security 字段语义一致 ——
        // 上面已经把 tls 当 security 的别名捡进来了。

        var stream: [String: Any] = [
            "network": normalizeNetwork(network),
            "security": security == "" ? "none" : security
        ]

        // —— TLS / REALITY 配置 ——
        if security == "tls" || security == "xtls" {
            stream["tlsSettings"] = buildTLSSettings(p, host: node.host)
        } else if security == "reality" {
            stream["realitySettings"] = buildREALITYSettings(p, host: node.host)
        }

        // —— transport-specific 块 ——
        switch normalizeNetwork(network) {
        case "ws":
            stream["wsSettings"] = buildWSSettings(p, host: node.host)
        case "grpc":
            stream["grpcSettings"] = buildGRPCSettings(p)
        case "h2":
            stream["httpSettings"] = buildHTTPSettings(p, host: node.host)
        case "kcp":
            stream["kcpSettings"] = buildKCPSettings(p)
        case "quic":
            stream["quicSettings"] = buildQUICSettings(p)
        case "tcp":
            // TCP + HTTP 伪装：只有 headerType=http 时才需要 tcpSettings
            if let header = p["headerType"]?.lowercased(), header == "http" {
                stream["tcpSettings"] = buildTCPHTTPSettings(p, host: node.host)
            }
        default:
            // 不识别的 transport：让 xray-core 自己报错，至少 streamSettings.network 已经透传
            break
        }

        return stream
    }

    // MARK: - helpers

    /// vmess 链接里 `net` 字段值有 "ws"/"tcp"/"http"/"grpc"/"kcp"/"quic"；
    /// "http" 是 h2 的 v2rayN 老叫法 —— 统一成 xray-core 的 "h2"。
    private static func normalizeNetwork(_ raw: String) -> String {
        switch raw {
        case "http":  return "h2"
        case "":      return "tcp"
        default:      return raw
        }
    }

    private static func buildTLSSettings(_ p: [String: String], host: String) -> [String: Any] {
        var tls: [String: Any] = [:]
        let sni = p["sni"] ?? p["peer"] ?? p["host"] ?? host
        tls["serverName"] = sni
        if let v = p["allowInsecure"] ?? p["skip-cert-verify"] ?? p["insecure"], boolish(v) {
            tls["allowInsecure"] = true
        }
        if let alpnStr = p["alpn"], !alpnStr.isEmpty {
            tls["alpn"] = alpnStr.split(separator: ",").map { String($0) }
        }
        if let fp = p["fp"], !fp.isEmpty {
            tls["fingerprint"] = fp
        }
        return tls
    }

    private static func buildREALITYSettings(_ p: [String: String], host: String) -> [String: Any] {
        var reality: [String: Any] = [:]
        reality["serverName"] = p["sni"] ?? p["peer"] ?? host
        if let pbk = p["pbk"] { reality["publicKey"] = pbk }
        if let sid = p["sid"] { reality["shortId"] = sid }
        if let spx = p["spx"] { reality["spiderX"] = spx }
        if let fp = p["fp"] { reality["fingerprint"] = fp }
        return reality
    }

    private static func buildWSSettings(_ p: [String: String], host: String) -> [String: Any] {
        var ws: [String: Any] = ["path": p["path"] ?? "/"]
        // WS 的 Host header：参数里 `host` 优先，没有就用节点 host
        if let h = p["host"], !h.isEmpty {
            ws["headers"] = ["Host": h]
        }
        return ws
    }

    private static func buildGRPCSettings(_ p: [String: String]) -> [String: Any] {
        var grpc: [String: Any] = [:]
        // gRPC 的 service name：通常 share link 里写在 `serviceName`，部分客户端用 `path`
        grpc["serviceName"] = p["serviceName"] ?? p["path"] ?? ""
        if let mode = p["mode"] { grpc["multiMode"] = (mode == "multi") }
        return grpc
    }

    private static func buildHTTPSettings(_ p: [String: String], host: String) -> [String: Any] {
        var http: [String: Any] = [:]
        http["path"] = p["path"] ?? "/"
        // h2 的 host：可以是逗号分隔的多个域名
        let hostsRaw = p["host"] ?? host
        http["host"] = hostsRaw.split(separator: ",").map { String($0) }
        return http
    }

    private static func buildKCPSettings(_ p: [String: String]) -> [String: Any] {
        var kcp: [String: Any] = [:]
        if let header = p["headerType"], header != "none" {
            kcp["header"] = ["type": header]
        }
        if let seed = p["seed"] { kcp["seed"] = seed }
        return kcp
    }

    private static func buildQUICSettings(_ p: [String: String]) -> [String: Any] {
        var quic: [String: Any] = [:]
        if let header = p["headerType"], header != "none" {
            quic["header"] = ["type": header]
        }
        if let security = p["quicSecurity"] ?? p["securityType"] {
            quic["security"] = security
        }
        if let key = p["key"] { quic["key"] = key }
        return quic
    }

    private static func buildTCPHTTPSettings(_ p: [String: String], host: String) -> [String: Any] {
        // headerType=http 的 TCP 伪装：只在主流模板里见过，最小覆盖即可
        var req: [String: Any] = ["version": "1.1"]
        if let path = p["path"] { req["path"] = [path] }
        if let h = p["host"] ?? Optional.some(host) {
            req["headers"] = ["Host": [h]]
        }
        return [
            "header": [
                "type": "http",
                "request": req
            ]
        ]
    }

    /// 容忍 "1" / "true" / "yes" 这种各种"是"的写法。
    private static func boolish(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower == "1" || lower == "true" || lower == "yes"
    }
}
