import Foundation
import QingzhouCore

/// 解析 `vmess://base64(json)` 链接。
///
/// JSON 字段参考 v2rayN 规范：
/// ```
/// { "v":"2", "ps":"name", "add":"host", "port":443 | "443",
///   "id":"uuid", "aid":0, "scy":"auto",
///   "net":"tcp|ws|grpc|h2|kcp|quic",
///   "type":"none", "host":"...", "path":"/...",
///   "tls":"tls"|"", "sni":"...", "alpn":"...", "fp":"..." }
/// ```
enum VMessParser {
    static func parse(_ urlString: String) throws -> Node {
        guard urlString.hasPrefix("vmess://") else { throw ProxyURLParseError.malformedURL }
        let payload = String(urlString.dropFirst("vmess://".count))
        // 有些客户端会带 fragment / query，先去掉
        let cleaned = payload.split(whereSeparator: { $0 == "#" || $0 == "?" }).first.map(String.init) ?? payload
        guard let decoded = String.fromPermissiveBase64(cleaned),
              let jsonData = decoded.data(using: .utf8) else {
            throw ProxyURLParseError.invalidBase64
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: jsonData, options: [])
        } catch {
            throw ProxyURLParseError.invalidJSON(error.localizedDescription)
        }
        guard let obj = json as? [String: Any] else {
            throw ProxyURLParseError.invalidJSON("root not an object")
        }

        guard let host = stringValue(obj["add"]), !host.isEmpty else {
            throw ProxyURLParseError.missingHost
        }
        guard let port = intValue(obj["port"]) else {
            throw ProxyURLParseError.missingPort
        }
        guard let uuid = stringValue(obj["id"]), !uuid.isEmpty else {
            throw ProxyURLParseError.missingCredential
        }

        let alterId = intValue(obj["aid"]) ?? 0
        let scy = stringValue(obj["scy"]) ?? "auto"
        let name = stringValue(obj["ps"]) ?? "\(host):\(port)"

        // "v"（链接格式版本号）不进 parameters —— 它是 vmess:// 编码格式的元数据，
        // 不是节点属性；NodeEncoder 导出时固定写 "v":"2"，两边约定一致 round-trip 才干净。
        var params: [String: String] = [:]
        for key in ["net", "type", "host", "path", "tls", "sni", "alpn", "fp"] {
            if let v = stringValue(obj[key]), !v.isEmpty {
                params[key] = v
            }
        }

        return Node(
            name: name,
            protocolType: .vmess,
            host: host,
            port: port,
            uuid: uuid,
            cipher: scy,
            alterId: alterId,
            parameters: params
        )
    }

    // MARK: - 鲁棒的类型转换：JSON 里同一字段可能是 String 或 Number

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
