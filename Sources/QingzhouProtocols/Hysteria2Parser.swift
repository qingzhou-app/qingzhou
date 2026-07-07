import Foundation
import QingzhouCore

/// 解析 `hysteria2://password@host:port?sni=...&insecure=1#name` 链接，
/// 同时兼容 `hy2://` 别名。
///
/// 参数集对齐 hysteria2 官方 URI 方案（apernet/hysteria discussions/716）：
/// auth（userinfo）/ sni / insecure / obfs / obfs-password / pinSHA256 …——
/// query 全部原样进 `parameters`，字段消费在 XrayConfig 的 Hysteria2Converter。
///
/// 端口跳跃（port hopping）两种写法都认：
///   1. 官方 authority 写法：`hysteria2://pwd@host:40000-50000?...`（区间/逗号混写）。
///      URLComponents 解析不了非数字端口 —— 先预处理：node.port 取首端口，
///      完整端口串挪进 `parameters["mport"]`。
///   2. v2rayN / Shadowrocket 惯用的 `?mport=443,5000-6000` 查询参数（generic 保留）。
enum Hysteria2Parser {
    static func parse(_ urlString: String) throws -> Node {
        var working = urlString
        var hopPorts: String?
        if let hop = try extractPortHopping(urlString) {
            working = hop.rewritten
            hopPorts = hop.spec
        }

        // URLComponents 对自定义 scheme 一般都能解析，hy2 也照样可以
        guard let comps = URLComponents(string: working) else {
            throw ProxyURLParseError.malformedURL
        }
        guard let host = comps.host, !host.isEmpty else { throw ProxyURLParseError.missingHost }
        guard let port = comps.port else { throw ProxyURLParseError.missingPort }
        // URLComponents 的 user / fragment 已 percent-decode，不再二次解码（见 TrojanParser 注释）。
        guard let password = comps.user, !password.isEmpty else {
            throw ProxyURLParseError.missingCredential
        }
        let name = comps.fragment ?? "\(host):\(port)"
        var params = Dictionary(
            (comps.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let v = item.value else { return nil }
                return (item.name, v)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // authority 里的跳跃端口串 → mport（query 里已显式给了 mport 就尊重 query）
        if let hopPorts, params["mport"] == nil { params["mport"] = hopPorts }
        return Node(
            name: name,
            protocolType: .hysteria2,
            host: host,
            port: port,
            password: password,
            parameters: params
        )
    }

    /// 从 authority 截出多端口串（`40000-50000` / `443,8443-8500`）。
    /// 返回 nil = 不是端口跳跃写法（单端口 / 没端口 / 形态对不上），走正常解析路径；
    /// 形态对但端口越界 → 显式抛 invalidPort（别让垃圾静默变 malformedURL）。
    private static func extractPortHopping(
        _ url: String
    ) throws -> (rewritten: String, spec: String)? {
        guard let schemeRange = url.range(of: "://") else { return nil }
        let afterScheme = url[schemeRange.upperBound...]
        let authorityEnd = afterScheme.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" }
            ?? afterScheme.endIndex
        let authority = afterScheme[..<authorityEnd]
        guard let lastColon = authority.lastIndex(of: ":") else { return nil }
        // IPv6 字面量（[...]）里的冒号属于地址本体，端口分隔符必须在 "]" 之后
        if let bracket = authority.lastIndex(of: "]"), lastColon < bracket { return nil }
        let spec = String(authority[authority.index(after: lastColon)...])
        // 单端口（纯数字）留给 URLComponents；含 - 或 , 才是跳跃写法
        guard spec.contains("-") || spec.contains(",") else { return nil }
        guard let first = spec.first, let last = spec.last,
              spec.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "," }),
              first.isNumber, last.isNumber
        else { return nil }
        let pieces = spec.split(whereSeparator: { $0 == "-" || $0 == "," })
        guard !pieces.isEmpty else { return nil }
        var firstPort: Int?
        for piece in pieces {
            guard let n = Int(piece), (1...65535).contains(n) else {
                throw ProxyURLParseError.invalidPort(spec)
            }
            if firstPort == nil { firstPort = n }
        }
        guard let firstPort else { return nil }
        let rewritten = String(url[..<authority.index(after: lastColon)])
            + String(firstPort)
            + String(url[authorityEnd...])
        return (rewritten, spec)
    }
}
