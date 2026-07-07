import Foundation
// 只 import `load(yaml:)`，避免 Yams 里的 `Node` 类型和 QingzhouCore.Node 冲突。
import func Yams.load
import QingzhouCore

/// Clash / Mihomo / Stash 配置 YAML 解析器。
///
/// 这些工具的配置都遵循同一套 `proxies:` schema，字段命名差不多，差异在边角字段上。
/// 我们只解 `proxies:` 段 —— `rules:` 段交给 QingzhouRules 单独处理。
///
/// 典型结构：
/// ```yaml
/// proxies:
///   - name: "HK"
///     type: trojan
///     server: example.com
///     port: 443
///     password: pw
///     sni: example.com
///     network: ws
///     ws-opts:
///       path: /
/// ```
public enum ClashConfigParser {

    public enum Error: Swift.Error, Sendable {
        case notClashConfig
        case yamlParse(String)
    }

    /// 启发式判断：内容是否像 Clash YAML（含 `proxies:` 顶层 key）。
    public static func isClashConfig(_ text: String) -> Bool {
        // 简单字符串匹配，避免每次都解 YAML。
        // 用换行 + key 出现在行首做信号。
        let lines = text.split(whereSeparator: { $0.isNewline })
        for line in lines.prefix(200) {   // 看前 200 行足够
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("proxies:") { return true }
            // proxies-providers 也算（订阅形式）
            if trimmed.hasPrefix("proxy-providers:") { return true }
        }
        return false
    }

    /// 解析 Clash 配置。失败 / 不识别的节点会被收集到 `errors`，不致命。
    public static func parse(_ text: String) throws -> (nodes: [Node], errors: [(name: String, reason: String)]) {
        let root: Any
        do {
            root = try load(yaml: text) ?? [:]
        } catch {
            throw Error.yamlParse("\(error)")
        }
        guard let dict = root as? [String: Any] else {
            throw Error.notClashConfig
        }
        guard let proxies = dict["proxies"] as? [[String: Any]] else {
            // 也尝试 proxies-providers 里 inline 的 payload
            if let providers = dict["proxy-providers"] as? [String: [String: Any]],
               let first = providers.values.first,
               let payload = first["payload"] as? [[String: Any]] {
                return convert(payload)
            }
            throw Error.notClashConfig
        }
        return convert(proxies)
    }

    // MARK: - 把 YAML 字典转成 Node

    static func convert(_ proxies: [[String: Any]]) -> (nodes: [Node], errors: [(name: String, reason: String)]) {
        var nodes: [Node] = []
        var errors: [(name: String, reason: String)] = []
        for raw in proxies {
            let name = (raw["name"] as? String) ?? "<unnamed>"
            do {
                if let node = try convertOne(raw) {
                    nodes.append(node)
                }
            } catch let e as Error {
                errors.append((name, "\(e)"))
            } catch {
                errors.append((name, "\(error)"))
            }
        }
        return (nodes, errors)
    }

    static func convertOne(_ raw: [String: Any]) throws -> Node? {
        guard let typeStr = (raw["type"] as? String)?.lowercased() else {
            throw Error.yamlParse("missing type")
        }
        guard let name = raw["name"] as? String, !name.isEmpty else {
            throw Error.yamlParse("missing name")
        }
        guard let server = (raw["server"] as? String), !server.isEmpty else {
            throw Error.yamlParse("missing server")
        }
        guard let port = intValue(raw["port"]), port > 0, port < 65536 else {
            throw Error.yamlParse("missing/invalid port")
        }

        // 把 Clash 字段名映射到 ProxyProtocol。
        // 其他 Clash 特有协议（vmess-snell, ssr, http, socks5...）暂不支持，跳过。
        let proto: ProxyProtocol
        switch typeStr {
        case "trojan":            proto = .trojan
        case "ss", "shadowsocks": proto = .shadowsocks
        case "vmess":             proto = .vmess
        case "vless":             proto = .vless
        case "hysteria2", "hy2":  proto = .hysteria2
        default:                  return nil   // 不支持的类型不报错，静默跳过
        }

        var node = Node(name: name, protocolType: proto, host: server, port: port)
        node.parameters = extractTransportParameters(raw)
        // 倍率元数据：部分机场在 Clash 节点里带非标字段（rate / 倍率 / multiplier）。
        // 有就存进 parameters["rate"]（Node.effectiveRate 优先读它，无则从节点名识别）。
        for key in ["rate", "倍率", "multiplier", "ratio"] {
            if let v = raw[key], let d = NodeRateParser.parse(String(describing: v)) {
                node.parameters["rate"] = String(d)
                break
            }
        }

        switch proto {
        case .trojan:
            node.password = raw["password"] as? String
            if let sni = raw["sni"] as? String { node.parameters["sni"] = sni }
            if (raw["skip-cert-verify"] as? Bool) == true { node.parameters["allowInsecure"] = "1" }

        case .hysteria2:
            node.password = raw["password"] as? String
            if let sni = raw["sni"] as? String { node.parameters["sni"] = sni }
            if (raw["skip-cert-verify"] as? Bool) == true { node.parameters["allowInsecure"] = "1" }
            // Clash.Meta hysteria2 扩展字段 → converter 认的 parameters 键。
            // 不映射 obfs = 带混淆的 hy2 节点走 Clash 订阅时握手必失败（机场兼容审计）。
            if let obfs = raw["obfs"] as? String, !obfs.isEmpty { node.parameters["obfs"] = obfs }
            if let obfsPwd = raw["obfs-password"] as? String, !obfsPwd.isEmpty {
                node.parameters["obfs-password"] = obfsPwd
            }
            // 端口跳跃：Clash 的 ports（"443,5000-6000"）统一到 mport 键（对齐 share link）。
            if let ports = stringValue(raw["ports"]), !ports.isEmpty { node.parameters["mport"] = ports }
            // brutal 带宽：up/down 可能是数字或带单位字符串，都转成字符串透传给 converter 归一化。
            if let up = stringValue(raw["up"]), !up.isEmpty { node.parameters["up"] = up }
            if let down = stringValue(raw["down"]), !down.isEmpty { node.parameters["down"] = down }
            if let cong = raw["congestion-controller"] as? String, !cong.isEmpty {
                node.parameters["congestion"] = cong
            }

        case .shadowsocks:
            node.cipher = raw["cipher"] as? String
            node.password = raw["password"] as? String

        case .vmess:
            node.uuid = raw["uuid"] as? String
            node.alterId = intValue(raw["alterId"]) ?? 0
            node.cipher = (raw["cipher"] as? String) ?? "auto"
            if (raw["tls"] as? Bool) == true { node.parameters["tls"] = "tls" }
            if let sni = raw["servername"] as? String { node.parameters["sni"] = sni }

        case .vless:
            node.uuid = raw["uuid"] as? String
            if (raw["tls"] as? Bool) == true { node.parameters["security"] = "tls" }
            if let sni = raw["servername"] as? String { node.parameters["sni"] = sni }
            if let flow = raw["flow"] as? String, !flow.isEmpty { node.parameters["flow"] = flow }
            applyRealityOpts(raw, into: &node)   // 放最后：reality 覆盖上面的 security=tls
        }

        // trojan 也可能走 reality（Clash.Meta 支持）
        if proto == .trojan { applyRealityOpts(raw, into: &node) }

        return node
    }

    /// 把 Clash 的 `reality-opts`（public-key / short-id）+ client-fingerprint 映射到
    /// converter 认的参数键（pbk / sid / fp / security=reality）。
    /// **不映射 reality 参数 = vless+reality 节点走 Clash 订阅时 xray 起不来、连不上**
    /// （分享链接路径全 query 透传所以没这问题；机场兼容审计 P1）。reality 现在极普遍。
    static func applyRealityOpts(_ raw: [String: Any], into node: inout Node) {
        guard let reality = raw["reality-opts"] as? [String: Any] else { return }
        node.parameters["security"] = "reality"
        if let pbk = reality["public-key"] as? String { node.parameters["pbk"] = pbk }
        if let sid = reality["short-id"] as? String { node.parameters["sid"] = sid }
    }

    /// 提取 transport 层（network=ws/grpc/h2/tcp/...）参数。
    static func extractTransportParameters(_ raw: [String: Any]) -> [String: String] {
        var params: [String: String] = [:]
        if let net = raw["network"] as? String { params["net"] = net }
        // alpn（数组）+ client-fingerprint —— 各协议通用，reality/tls 都要用（审计 P1）
        if let alpn = raw["alpn"] as? [String], !alpn.isEmpty { params["alpn"] = alpn.joined(separator: ",") }
        if let fp = raw["client-fingerprint"] as? String, !fp.isEmpty { params["fp"] = fp }

        if let ws = raw["ws-opts"] as? [String: Any] {
            if let path = ws["path"] as? String { params["path"] = path }
            if let headers = ws["headers"] as? [String: Any],
               let host = headers["Host"] as? String { params["host"] = host }
        }
        if let grpc = raw["grpc-opts"] as? [String: Any] {
            if let svc = grpc["grpc-service-name"] as? String { params["serviceName"] = svc }
        }
        if let h2 = raw["h2-opts"] as? [String: Any] {
            if let path = h2["path"] as? String { params["path"] = path }
            if let hosts = h2["host"] as? [String] {
                params["host"] = hosts.joined(separator: ",")
            }
        }
        return params
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let i = any as? Int { return i }
        if let s = any as? String { return Int(s) }
        return nil
    }

    /// 数字/字符串统一取字符串（YAML 里 `up: 100` 是数字、`down: 500 Mbps` 是字符串）。
    /// 整数不带小数点（`100`，不是 `100.0`），避免 converter 归一化时误判。
    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber {
            // 判断是不是整型：整数就不带小数点
            if CFNumberIsFloatType(n) {
                return "\(n.doubleValue)"
            }
            return "\(n.intValue)"
        }
        if let i = any as? Int { return "\(i)" }
        return nil
    }
}
