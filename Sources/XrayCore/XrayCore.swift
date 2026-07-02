// XrayCore：包装 libXray (xtlsapi / XTLS) 的 MIT 移动端 binding。
//
// libXray 的所有 API 都接受 / 返回 base64 编码的 JSON 字符串，封装一层让 Swift 一侧
// 拿到的是 typed 结构。
//
// 关键 API（来自 libXray xray_wrapper.go / nodep_wrapper.go）：
//   - XrayVersion() -> String
//   - SetTunFd(fd: Int32)
//   - RunXrayFromJSON(configJSON: String)
//   - StopXray()
//   - GetXrayState() -> Bool
//   - Ping(...) -> 测延迟
//   - ConvertShareLinksToXrayJson(links: String) -> 内置链接转 JSON

import Foundation
#if canImport(LibXray)
import LibXray
#endif

public enum XrayCore {

    /// xray-core 的版本号。
    public static var version: String {
        #if canImport(LibXray)
        return LibXrayXrayVersion()
        #else
        return "stub-no-libxray"
        #endif
    }

    /// 当前 xray-core 是否在跑。
    public static var isRunning: Bool {
        #if canImport(LibXray)
        return LibXrayGetXrayState()
        #else
        return false
        #endif
    }

    /// 把 NEPacketTunnelProvider 的 TUN file descriptor 交给 xray-core。
    /// **必须在 `run(...)` 之前调用**。
    public static func setTunFd(_ fd: Int32) {
        #if canImport(LibXray)
        LibXraySetTunFd(fd)
        #endif
    }

    /// 构建 mph 缓存 —— **可选优化，当前有意不用**（目前无调用点，留作以后加速
    /// rule 模式启动的入口）。
    ///
    /// rule 模式不需要它：`run(...)` 传空 `mphCachePath` 时 libXray 不设
    /// `xray.mph.cache` 环境变量，内核 router 走 `NewMphMatcherGroup` 在内存里
    /// 构建 matcher（见 PacketTunnelProvider 里 `mphCache = ""` 的说明）。
    /// 只有 env 指了路径而文件缺失才会报 "no such file"。
    ///
    /// 历史坑（真要启用缓存前先解决）：BuildMphCache 解析 `configPath` 配置**文件**，
    /// 与 RunXrayFromJSON 解析内联 JSON 产出的 matcher key 对不上，run 时报
    /// "matcher not found"（见 16b6f31 → 9dfb7bd 的演进）。
    ///
    /// BuildMphCache 读 `configPath` 指向的配置文件，解析其中引用的 geosite/geoip，
    /// 从 `geoDir` 的 .dat 构建 MPH 写到 `mphCachePath`。
    public static func buildMphCache(configPath: String, geoDir: String, mphCachePath: String) throws {
        #if canImport(LibXray)
        // LibXrayBuildMphCache 要 base64(JSON{datDir, mphCachePath, configPath})
        let reqPayload: [String: String] = [
            "datDir": geoDir,
            "mphCachePath": mphCachePath,
            "configPath": configPath
        ]
        let reqJSON = try JSONSerialization.data(withJSONObject: reqPayload)
        let respB64 = LibXrayBuildMphCache(reqJSON.base64EncodedString())
        try Self.throwIfError(respB64)
        #else
        throw XrayError.libXrayNotLinked
        #endif
    }

    /// 用 JSON 字符串配置启动 xray-core。
    /// - Returns: 成功返回 nil；失败返回 libXray 的错误消息。
    public static func run(configJSON: String, geoDir: String, mphCachePath: String) throws {
        #if canImport(LibXray)
        // libXray 的 RunXrayFromJSON 要求 base64(JSON{datDir, mphCachePath, configJSON})
        let reqPayload: [String: String] = [
            "datDir": geoDir,
            "mphCachePath": mphCachePath,
            "configJSON": configJSON
        ]
        let reqJSON = try JSONSerialization.data(withJSONObject: reqPayload)
        let reqB64 = reqJSON.base64EncodedString()

        let respB64 = LibXrayRunXrayFromJSON(reqB64)
        try Self.throwIfError(respB64)
        #else
        throw XrayError.libXrayNotLinked
        #endif
    }

    /// 停掉 xray-core 实例。
    @discardableResult
    public static func stop() -> String {
        #if canImport(LibXray)
        return LibXrayStopXray()
        #else
        return "stub-no-libxray"
        #endif
    }

    /// 把分享链接（trojan:// / vmess:// / vless:// / ss:// / Clash YAML / v2rayN）转 xray JSON。
    /// 返回的字符串是 xray 配置 JSON。
    public static func convertShareLinks(_ links: String) throws -> String {
        #if canImport(LibXray)
        let b64 = Data(links.utf8).base64EncodedString()
        let respB64 = LibXrayConvertShareLinksToXrayJson(b64)
        // ConvertShareLinksToXrayJson 的 data 是 xray *conf.Config 对象，re-serialize 成 JSON 字符串
        return try Self.decodeResponseJSON(respB64)
        #else
        throw XrayError.libXrayNotLinked
        #endif
    }

    /// libXray Ping 的错误哨兵值（nodep.PingDelayError / PingDelayTimeout）：
    /// Ping 失败时 delay 字段是 10000/11000 而不是真实毫秒数。
    public static let pingDelayError = 10_000
    public static let pingDelayTimeout = 11_000

    /// 「经代理延迟」：对一份 **临时 xray 配置**（socks inbound + 节点 outbound）起一个
    /// 独立的短命 xray 实例，真实通过该节点发一次 HTTP HEAD，返回全链路延迟毫秒数。
    ///
    /// 实现细节（都是 libXray Ping 的硬约束）：
    /// - libXray 的 pingRequest 只认 `configPath`（配置**文件**），不接受内联 JSON ——
    ///   所以这里把 configJSON 落到临时文件，测完即删；
    /// - `proxy` 参数是 Go http client 的本地代理地址，必须与配置里 socks inbound 的端口一致；
    /// - Ping 内部 `StartXray` 用的是**局部**实例变量，不碰全局 coreServer —— 与正在跑的
    ///   隧道实例互不影响（已读 libXray 源码确认）；扩展进程自身的出站流量被 NE 排除在
    ///   TUN 之外，测到的是「本机 → 节点 → 目标」的真实代理链路延迟，不会串进当前隧道。
    /// - 内存：短命实例约几 MB 且用完即释放，但调用方必须**串行**发起（NE 50MB 上限）。
    public static func ping(
        configJSON: String,
        socksPort: Int,
        url: String = "https://www.google.com/generate_204",
        timeoutSeconds: Int = 5,
        datDir: String = ""
    ) throws -> Int {
        #if canImport(LibXray)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xray-ping-\(UUID().uuidString).json")
        try configJSON.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let req: [String: Any] = [
            "datDir": datDir,
            "configPath": tmpURL.path,
            "timeout": timeoutSeconds,
            "url": url,
            "proxy": "socks5://127.0.0.1:\(socksPort)"
        ]
        let reqData = try JSONSerialization.data(withJSONObject: req)
        let respB64 = LibXrayPing(reqData.base64EncodedString())
        // Ping 的 data 是 int64（毫秒）。失败时 error 非空 + data 是哨兵值。
        let obj = try parseResponse(respB64)
        guard let ms = (obj["data"] as? NSNumber)?.intValue else {
            throw XrayError.invalidResponse("ping data is not a number")
        }
        if ms >= Self.pingDelayError {
            throw XrayError.libXrayError(ms == Self.pingDelayTimeout ? "ping 超时" : "ping 失败")
        }
        return ms
        #else
        throw XrayError.libXrayNotLinked
        #endif
    }

    /// 配置预检（TestXray）：完整走一遍 xray 的配置解析 + 组件构建（不 Start、不监听端口），
    /// 失败抛出 xray-core 原生的可读错误。同样只认配置文件路径，内部落临时文件。
    public static func testConfig(configJSON: String, datDir: String) throws {
        #if canImport(LibXray)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xray-test-\(UUID().uuidString).json")
        try configJSON.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let req: [String: String] = [
            "datDir": datDir,
            "configPath": tmpURL.path
        ]
        let reqData = try JSONSerialization.data(withJSONObject: req)
        let respB64 = LibXrayTestXray(reqData.base64EncodedString())
        try Self.throwIfError(respB64)
        #else
        throw XrayError.libXrayNotLinked
        #endif
    }

    /// 向内核要 n 个当前空闲的 TCP 端口（bind :0 再放掉）。给 metrics inbound /
    /// ping 的临时 socks inbound 用，避免写死端口被占导致 xray 起不来。
    public static func getFreePorts(_ count: Int) throws -> [Int] {
        #if canImport(LibXray)
        let obj = try parseResponse(LibXrayGetFreePorts(count))
        guard let data = obj["data"] as? [String: Any],
              let ports = data["ports"] as? [Any] else {
            throw XrayError.invalidResponse("getFreePorts: no ports field")
        }
        return ports.compactMap { ($0 as? NSNumber)?.intValue }
        #else
        throw XrayError.libXrayNotLinked
        #endif
    }

    /// 查询 xray 内置流量统计：GET http://127.0.0.1:port/debug/vars（metrics expvar），
    /// 返回原始 JSON 字符串。需要配置里开了 stats + metrics（见 XrayConfigComposer
    /// 的 metricsPort 参数）。解析用 `parseOutboundStats`。
    public static func queryStats(metricsPort: Int) throws -> String {
        #if canImport(LibXray)
        let server = "http://127.0.0.1:\(metricsPort)/debug/vars"
        let b64 = Data(server.utf8).base64EncodedString()
        return try decodeResponseString(LibXrayQueryStats(b64))
        #else
        throw XrayError.libXrayNotLinked
        #endif
    }

    /// 把 /debug/vars 的 expvar JSON 解析成 per-outbound 计数。
    /// expvar 结构：{"stats": {"outbound": {"proxy": {"uplink": n, "downlink": n}, ...}}, ...}
    /// 纯解析、不碰 LibXray —— 单测可直接覆盖。
    public static func parseOutboundStats(_ expvarJSON: String) -> [String: (uplink: Int64, downlink: Int64)] {
        guard let data = expvarJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stats = root["stats"] as? [String: Any],
              let outbound = stats["outbound"] as? [String: Any] else {
            return [:]
        }
        var result: [String: (uplink: Int64, downlink: Int64)] = [:]
        for (tag, value) in outbound {
            guard let counters = value as? [String: Any] else { continue }
            let up = (counters["uplink"] as? NSNumber)?.int64Value ?? 0
            let down = (counters["downlink"] as? NSNumber)?.int64Value ?? 0
            result[tag] = (uplink: up, downlink: down)
        }
        return result
    }

    // MARK: - 错误响应解析

    /// libXray 返回的 base64(JSON{success: bool, data: T, error: string}) 通用解码。
    private static func throwIfError(_ base64Response: String) throws {
        guard let data = Data(base64Encoded: base64Response),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XrayError.invalidResponse(base64Response)
        }
        if let errMsg = obj["error"] as? String, !errMsg.isEmpty {
            throw XrayError.libXrayError(errMsg)
        }
    }

    /// 解出 `data` 字段的字符串内容；错误时抛 XrayError。
    /// 适用于 libXray 中 data 类型本身就是 string 的接口（XrayVersion / Ping / StopXray 等）。
    private static func decodeResponseString(_ base64Response: String) throws -> String {
        let obj = try parseResponse(base64Response)
        if let dataString = obj["data"] as? String {
            return dataString
        }
        throw XrayError.invalidResponse("data field is not a string")
    }

    /// 解出 `data` 字段，无论它是 string / object / array，都重新序列化为 JSON 字符串。
    /// 适用于 libXray 中 data 是对象的接口（ConvertShareLinksToXrayJson 等）。
    private static func decodeResponseJSON(_ base64Response: String) throws -> String {
        let obj = try parseResponse(base64Response)
        guard let dataValue = obj["data"] else {
            throw XrayError.invalidResponse("no data field")
        }
        if let str = dataValue as? String { return str }
        let reserialized = try JSONSerialization.data(withJSONObject: dataValue, options: [])
        return String(data: reserialized, encoding: .utf8) ?? ""
    }

    /// base64 → JSON object，并把 error / err 字段抽出来抛错。
    private static func parseResponse(_ base64Response: String) throws -> [String: Any] {
        guard let data = Data(base64Encoded: base64Response),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XrayError.invalidResponse(base64Response)
        }
        // 历史版本字段名可能是 error 或 err，都兜住
        if let errMsg = (obj["error"] as? String) ?? (obj["err"] as? String), !errMsg.isEmpty {
            throw XrayError.libXrayError(errMsg)
        }
        return obj
    }
}

public enum XrayError: Error, LocalizedError {
    case libXrayNotLinked
    case libXrayError(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .libXrayNotLinked:
            return "LibXray.xcframework not linked. Run scripts/build-libxray.sh first."
        case .libXrayError(let msg):
            return "xray-core: \(msg)"
        case .invalidResponse(let raw):
            return "Unexpected response from libXray: \(raw)"
        }
    }
}
