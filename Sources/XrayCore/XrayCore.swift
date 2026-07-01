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

    /// 构建 mph 缓存。**必须在 `run(...)` 之前调用**（rule 模式用 geosite/geoip，
    /// xray router 启动时会去「加载」这个缓存文件 —— 没有就报
    /// "failed to load file: xray-mph.cache: no such file or directory"）。
    ///
    /// BuildMphCache 读 `configPath` 指向的配置文件，解析其中引用的 geosite/geoip，
    /// 从 `geoDir` 的 .dat 构建 MPH 写到 `mphCachePath`。所以调用前要先把配置写成文件。
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

    /// 对一个 xray 配置发起 ping，返回延迟毫秒数。
    public static func ping(configJSON: String, url: String = "https://www.google.com/generate_204", timeoutSeconds: Int = 5) throws -> Int {
        #if canImport(LibXray)
        let req: [String: Any] = [
            "configPath": "",
            "configJSON": configJSON,
            "url": url,
            "timeout": timeoutSeconds,
            "datDir": "",
            "proxy": ""
        ]
        let reqData = try JSONSerialization.data(withJSONObject: req)
        let reqB64 = reqData.base64EncodedString()
        let respB64 = LibXrayPing(reqB64)
        let respStr = try Self.decodeResponseString(respB64)
        guard let ms = Int(respStr) else {
            throw XrayError.invalidResponse("ping returned non-int: \(respStr)")
        }
        return ms
        #else
        throw XrayError.libXrayNotLinked
        #endif
    }

    // MARK: - 配置校验 / 节点导出 / 流量统计（libXray 已导出但之前没接的能力）

    /// 校验一份 xray 配置文件是否合法（连接前预检，坏配置提前给清晰错误）。
    /// libXray 的 TestXray 只吃**文件路径** + geo 目录（解析 routing 里的 geosite/geoip 需要）。
    /// - Throws: 配置非法时抛 `XrayError.libXrayError`，消息即 xray 的解析错误。
    public static func testConfig(configPath: String, geoDir: String) throws {
        #if canImport(LibXray)
        let req: [String: String] = ["datDir": geoDir, "configPath": configPath]
        let reqJSON = try JSONSerialization.data(withJSONObject: req)
        let respB64 = LibXrayTestXray(reqJSON.base64EncodedString())
        try Self.throwIfError(respB64)
        #else
        throw XrayError.libXrayNotLinked
        #endif
    }

    /// 校验 xray 配置 JSON 字符串：写到临时文件再 TestXray。
    /// geoDir 为空时只能校验不含 geosite/geoip 规则的配置（否则 xray 会因找不到 geo 报错）。
    public static func validate(configJSON: String, geoDir: String = "") throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("xray-validate-\(abs(configJSON.hashValue)).json")
        try Data(configJSON.utf8).write(to: tmp, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tmp) }
        try testConfig(configPath: tmp.path, geoDir: geoDir)
    }

    /// 把一份 xray 配置 JSON 反向转成分享链接（每行一条，vmess 出 VMessAEAD）。
    /// 用于「导出/分享节点」：节点 → 完整配置 → 分享链接 / 二维码。
    public static func convertJSONToShareLinks(_ xrayJSON: String) throws -> String {
        #if canImport(LibXray)
        let b64 = Data(xrayJSON.utf8).base64EncodedString()
        let respB64 = LibXrayConvertXrayJsonToShareLinks(b64)
        return try Self.decodeResponseString(respB64)
        #else
        throw XrayError.libXrayNotLinked
        #endif
    }

    /// 拉取 xray 的实时统计（打它的 metrics/expvar 端点）。
    /// - Parameter metricsURL: 形如 `http://127.0.0.1:49227/debug/vars`（配置里要开
    ///   `stats` + `metrics`(带 tag 的本地 inbound) + `policy.system.stats*`）。
    /// - Returns: expvar 的原始 JSON 字符串，含 `outbound>>>tag>>>traffic>>>uplink/downlink` 等累计计数。
    public static func queryStats(metricsURL: String) throws -> String {
        #if canImport(LibXray)
        let b64 = Data(metricsURL.utf8).base64EncodedString()
        let respB64 = LibXrayQueryStats(b64)
        return try Self.decodeResponseString(respB64)
        #else
        throw XrayError.libXrayNotLinked
        #endif
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
