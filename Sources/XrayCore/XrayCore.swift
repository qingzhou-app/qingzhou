// XrayCore：包装 libXray (XTLS/libXray) 的 gomobile binding。
//
// libXray 自 #132 起收敛为**单一入口** `LibXrayInvoke(requestJSON) -> responseJSON`：
//   请求 {apiVersion, method, env, payload}，响应 {success, data, error}，纯 JSON 不再 base64。
//   TUN fd / geo 资产目录等都改为随请求的 env 传入（内部落 os.Setenv，进程级生效）。
// 本文件把它封成 typed Swift API；唯一的额外符号是我们本地 patch 导出的
// LibXraySwitchOutbound（scripts/patches/libxray/，响应信封与 Invoke 相同）。
//
// ⚠️ 升级 libXray 时先对 invoke_model.go 核对 method 名与 payload 字段 —— 这里的
// 字符串都是照它抄的，对不上就是静默 "unknown method"。

import Foundation
#if canImport(LibXray)
import LibXray
#endif

public enum XrayCore {

    /// 待注入的 TUN fd（新 API 没有全局 setter，改为随 run 请求的 env 传入）。
    /// **必须在 `run(...)` 之前调用** setTunFd —— 语义与旧版保持一致。
    private nonisolated(unsafe) static var pendingTunFd: Int32?

    /// xray-core 的版本号。
    public static var version: String {
        #if canImport(LibXray)
        guard let obj = try? invoke(method: "xrayVersion"),
              let data = obj["data"] as? [String: Any],
              let v = data["version"] as? String else { return "unknown" }
        return v
        #else
        return "stub-no-libxray"
        #endif
    }

    /// 当前 xray-core 是否在跑。
    public static var isRunning: Bool {
        #if canImport(LibXray)
        guard let obj = try? invoke(method: "getXrayState"),
              let data = obj["data"] as? [String: Any],
              let running = data["running"] as? Bool else { return false }
        return running
        #else
        return false
        #endif
    }

    /// 记下 NEPacketTunnelProvider 的 TUN file descriptor，`run(...)` 时经 env
    /// （"xray.tun.fd"）交给 xray-core 的 tun inbound。**必须在 `run(...)` 之前调用**。
    public static func setTunFd(_ fd: Int32) {
        pendingTunFd = fd
    }

    /// 用 JSON 字符串配置启动 xray-core。geoDir 经 env（"xray.location.asset"）传入，
    /// 供配置里的 geosite/geoip 引用解析。
    /// （旧版还有 mphCachePath 参数 —— 新 libXray 已移除 mph 缓存支持，本来也没在用。）
    public static func run(configJSON: String, geoDir: String) throws {
        #if canImport(LibXray)
        var env: [String: String] = [:]
        if !geoDir.isEmpty { env["xray.location.asset"] = geoDir }
        if let fd = pendingTunFd { env["xray.tun.fd"] = String(fd) }
        _ = try invoke(method: "runXrayFromJson", env: env, payload: ["configJSON": configJSON])
        #else
        throw XrayError.libXrayNotLinked
        #endif
    }

    /// 原地替换运行中 xray 实例的 outbound handler（轻舟对 libXray 的本地扩展，
    /// 见 scripts/patches/libxray/qingzhou_switch*.go —— 上游没有这个导出，
    /// 框架必须用 scripts/build-libxray.sh 重新构建后才有符号）。
    ///
    /// `outboundJSON` 是 xray 配置 outbounds 数组的**单个元素**（必须带 tag，
    /// 且与路由规则指向的 tag 一致，本项目约定 "proxy"）。换 handler 不动
    /// 隧道 / 路由 / DNS —— 换节点零断流。失败抛错，调用方应回退到全量重启。
    public static func switchOutbound(outboundJSON: String) throws {
        #if canImport(LibXray)
        let req = try JSONSerialization.data(withJSONObject: ["outboundJson": outboundJSON])
        let resp = LibXraySwitchOutbound(String(data: req, encoding: .utf8) ?? "")
        _ = try parseEnvelope(resp)
        #else
        throw XrayError.libXrayNotLinked
        #endif
    }

    /// 停掉 xray-core 实例。
    @discardableResult
    public static func stop() -> String {
        #if canImport(LibXray)
        do {
            _ = try invoke(method: "stopXray")
            return ""
        } catch {
            return "\(error)"
        }
        #else
        return "stub-no-libxray"
        #endif
    }

    /// 把分享链接（trojan:// / vmess:// / vless:// / ss:// / Clash YAML / v2rayN）转 xray JSON。
    /// 返回的字符串是 xray 配置 JSON。
    public static func convertShareLinks(_ links: String) throws -> String {
        #if canImport(LibXray)
        let obj = try invoke(method: "convertShareLinksToXrayJson", payload: ["text": links])
        guard let dataValue = obj["data"] else {
            throw XrayError.invalidResponse("no data field")
        }
        if let str = dataValue as? String { return str }
        let reserialized = try JSONSerialization.data(withJSONObject: dataValue, options: [])
        return String(data: reserialized, encoding: .utf8) ?? ""
        #else
        throw XrayError.libXrayNotLinked
        #endif
    }

    /// libXray Ping 的错误哨兵值（nodep.PingDelayError / PingDelayTimeout）：
    /// Ping 失败时 delay 是 10000/11000 而不是真实毫秒数（新版同时还带 error，双保险）。
    public static let pingDelayError = 10_000
    public static let pingDelayTimeout = 11_000

    /// 「经代理延迟」：对一份 **临时 xray 配置**（socks inbound + 节点 outbound）起一个
    /// 独立的短命 xray 实例，真实通过该节点发一次 HTTP HEAD，返回全链路延迟毫秒数。
    ///
    /// 实现细节（都是 libXray Ping 的硬约束）：
    /// - pingRequest 只认 `configPath`（配置**文件**），不接受内联 JSON ——
    ///   所以这里把 configJSON 落到临时文件，测完即删；
    /// - `proxy` 参数是 Go http client 的本地代理地址，必须与配置里 socks inbound 的端口一致；
    /// - Ping 内部 `StartXray` 用的是**局部**实例变量，不碰全局 coreServer —— 与正在跑的
    ///   隧道实例互不影响；扩展进程自身的出站流量被 NE 排除在 TUN 之外，测到的是
    ///   「本机 → 节点 → 目标」的真实代理链路延迟，不会串进当前隧道。
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

        var env: [String: String] = [:]
        if !datDir.isEmpty { env["xray.location.asset"] = datDir }
        let obj = try invoke(method: "ping", env: env, payload: [
            "configPath": tmpURL.path,
            "timeout": timeoutSeconds,
            "url": url,
            "proxy": "socks5://127.0.0.1:\(socksPort)",
        ])
        guard let data = obj["data"] as? [String: Any],
              let ms = (data["delay"] as? NSNumber)?.intValue else {
            throw XrayError.invalidResponse("ping data has no delay")
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

        var env: [String: String] = [:]
        if !datDir.isEmpty { env["xray.location.asset"] = datDir }
        _ = try invoke(method: "testXray", env: env, payload: ["configPath": tmpURL.path])
        #else
        throw XrayError.libXrayNotLinked
        #endif
    }

    /// 向内核要 n 个当前空闲的 TCP 端口（bind :0 再放掉）。给 metrics inbound /
    /// ping 的临时 socks inbound 用，避免写死端口被占导致 xray 起不来。
    public static func getFreePorts(_ count: Int) throws -> [Int] {
        #if canImport(LibXray)
        let obj = try invoke(method: "getFreePorts", payload: ["count": count])
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
    /// 新版 libXray 删掉了 QueryStats 导出 —— 本来就是一次 loopback HTTP GET，
    /// 这里直接用 Foundation 实现，少一层依赖（阻塞式，调用方在轮询队列里跑）。
    public static func queryStats(metricsPort: Int) throws -> String {
        guard let url = URL(string: "http://127.0.0.1:\(metricsPort)/debug/vars") else {
            throw XrayError.invalidResponse("bad metrics port")
        }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                throw XrayError.invalidResponse("metrics response not utf8")
            }
            return text
        } catch let error as XrayError {
            throw error
        } catch {
            throw XrayError.libXrayError("queryStats: \(error.localizedDescription)")
        }
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

    // MARK: - Invoke 封装

    #if canImport(LibXray)
    /// 组装 {apiVersion, method, env, payload} → LibXrayInvoke → 解析 {success, data, error}。
    @discardableResult
    private static func invoke(
        method: String,
        env: [String: String] = [:],
        payload: [String: Any] = [:]
    ) throws -> [String: Any] {
        var request: [String: Any] = ["apiVersion": 1, "method": method]
        if !env.isEmpty { request["env"] = env }
        if !payload.isEmpty { request["payload"] = payload }
        let reqData = try JSONSerialization.data(withJSONObject: request)
        let resp = LibXrayInvoke(String(data: reqData, encoding: .utf8) ?? "")
        return try parseEnvelope(resp)
    }

    /// 解析 {success, data, error} 信封；success=false 或 error 非空 → 抛错。
    private static func parseEnvelope(_ responseJSON: String) throws -> [String: Any] {
        guard let data = responseJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XrayError.invalidResponse(responseJSON)
        }
        let success = (obj["success"] as? Bool) ?? false
        if let errMsg = obj["error"] as? String, !errMsg.isEmpty {
            throw XrayError.libXrayError(errMsg)
        }
        if !success {
            throw XrayError.libXrayError("libXray invoke failed without error message")
        }
        return obj
    }
    #endif
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
