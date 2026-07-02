// 主 App 和 PacketTunnel Extension 之间共享的最小存储。
//
// 设计：只共享 Extension **启动时必需**的东西 —— 当前节点对应的 xray JSON 配置。
// 主 App 在调用 NETunnelProviderManager.startVPNTunnel() 之前先把配置写进来；
// Extension 的 startTunnel(options:) 里读出来。
//
// 不依赖 QingzhouApp / QingzhouCore 任何业务类型，纯 String/Data 跨进程。XrayCore 是
// Extension target 唯一需要的 SPM 依赖，把这个 helper 也塞进来正合适。

import Foundation

public enum TunnelAppGroup {
    /// App Group 标识符。和 entitlements 里的 `com.apple.security.application-groups` 必须一致。
    /// 如果你 fork 项目改了 group id，这里和 entitlements 都要改。
    public static let groupIdentifier: String = "group.com.sbraveyoung.qingzhou"

    /// AppGroup 容器根目录。entitlement 未配置或 sandbox 拒绝时为 nil。
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    // MARK: - xray JSON 配置

    private static var configURL: URL? {
        containerURL?.appendingPathComponent("xray-config.json")
    }

    /// 主 App 调：把当前生效的 xray JSON 写到共享容器。
    /// - Returns: true 表示写入成功；entitlement 不全或写入失败返回 false。
    @discardableResult
    public static func writeXrayConfig(_ json: String) -> Bool {
        guard let url = configURL else { return false }
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Extension 调：读出当前应启动的 xray JSON 配置。
    public static func readXrayConfig() -> String? {
        guard let url = configURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - xray 工作目录（geo 文件、mph cache 等）

    /// xray 内部用的工作目录。geosite.dat / geoip.dat / mph.cache 都放在这。
    /// Extension 启动时调，目录不存在时自动创建。
    public static func ensureWorkingDirectory() -> URL? {
        guard let base = containerURL else { return nil }
        let dir = base.appendingPathComponent("xray-data", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Mph cache 文件路径（xray-core 用于规则匹配加速）。
    public static func mphCachePath() -> String? {
        ensureWorkingDirectory()?.appendingPathComponent("mph.cache").path
    }

    // MARK: - 流量统计上报（Extension 写、主 App 轮询读）

    /// 共享文件名。主 App 侧用 AppGroupStorage.read(from: "traffic-stats") 同名读取。
    public static let trafficStatsName = "traffic-stats"

    private static var trafficStatsURL: URL? {
        containerURL?.appendingPathComponent(trafficStatsName).appendingPathExtension("json")
    }

    /// Extension 调：把当前流量统计快照（已 encode 成 JSON 串）写进共享容器。
    /// 主 App 每秒读一次画波形 / 显示实时速率。entitlement 不全时静默失败返回 false。
    @discardableResult
    public static func writeTrafficStats(_ json: String) -> Bool {
        guard let url = trafficStatsURL else { return false }
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // MARK: - access log（xray 写、主 App 增量读解析成真实连接）

    public static let accessLogName = "access.log"

    private static var accessLogURL: URL? {
        containerURL?.appendingPathComponent(accessLogName)
    }

    /// xray 的 `log.access` 要指向这个路径。返回前 createFile 覆盖式建一个空文件 ——
    /// 既清掉上次会话的旧日志，又**验证容器可写**：成功才返回路径（并给 xray 留好空文件去 append）；
    /// 失败（容器 nil / 不可写）返回 nil，compose 就不写 access 段，xray 照常启动 ——
    /// **绝不让 access log 拖垮 VPN**。
    public static func accessLogPath() -> String? {
        guard let url = accessLogURL else { return nil }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        return url.path
    }

    // MARK: - 隧道会话标记（Extension 写、主 App 读）—— 定时自动关闭的倒计时/自停标记

    /// 主 App 侧用 AppGroupStorage.read(TunnelSessionInfo.self, from: "tunnel-session") 同名读取。
    public static let tunnelSessionName = "tunnel-session"

    private static var tunnelSessionURL: URL? {
        containerURL?.appendingPathComponent(tunnelSessionName).appendingPathExtension("json")
    }

    /// Extension 调：把本次会话信息（TunnelSessionInfo 已 encode 成 JSON 串，ISO8601 日期）
    /// 写进共享容器。主 App 用它推算「定时关闭」剩余时间、识别「已按定时自停」。
    @discardableResult
    public static func writeTunnelSession(_ json: String) -> Bool {
        guard let url = tunnelSessionURL else { return false }
        return (try? json.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    // MARK: - 扩展内存统计（Extension 写、主 App 读；Extension 启动时也读 —— 接续历史峰值）

    /// 主 App 侧用 AppGroupStorage.read(TunnelMemoryStats.self, from: "memory-stats") 同名读取。
    public static let memoryStatsName = "memory-stats"

    private static var memoryStatsURL: URL? {
        containerURL?.appendingPathComponent(memoryStatsName).appendingPathExtension("json")
    }

    /// Extension 调：把内存快照（TunnelMemoryStats 已 encode 成 JSON 串）写进共享容器。
    /// 随流量统计每秒一次。entitlement 不全时静默失败 —— 观测缺席不影响 VPN。
    @discardableResult
    public static func writeMemoryStats(_ json: String) -> Bool {
        guard let url = memoryStatsURL else { return false }
        return (try? json.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    /// Extension 启动时调：读上次落盘的内存统计（取 allTimePeakBytes 接着累计）。
    public static func readMemoryStatsJSON() -> String? {
        guard let url = memoryStatsURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - FakeDNS 映射（Extension 写、主 App 读）

    /// 主 App 侧用 AppGroupStorage.read(from: "fakedns-map") 同名读取。
    public static let fakeDNSMapName = "fakedns-map"

    private static var fakeDNSMapURL: URL? {
        containerURL?.appendingPathComponent(fakeDNSMapName).appendingPathExtension("json")
    }

    /// Extension 调：把「假 IP → 域名」映射（已 encode 成 JSON 串）写进共享容器。
    /// 主 App 用它把 access log 里的 198.18.x.x 假 IP 翻译回真域名。
    @discardableResult
    public static func writeFakeDNSMap(_ json: String) -> Bool {
        guard let url = fakeDNSMapURL else { return false }
        return (try? json.write(to: url, atomically: true, encoding: .utf8)) != nil
    }
}
