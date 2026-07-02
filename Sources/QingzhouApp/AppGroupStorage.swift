import Foundation
import QingzhouCore

/// 主 App 和 PacketTunnel Extension 之间共享的存储。
///
/// 设计：
/// - 用 AppGroup 容器内的 JSON 文件做 IPC，简单可靠（不用走 XPC）；
/// - 主 App 写、Extension 读 —— 同一个 group id 双方都能访问；
/// - 容器路径在 Sandbox 内，App / Extension 都自动有写权限。
///
/// 没有 App Group entitlement 时（比如阶段 1.5 build），`containerURL` 返回 nil，
/// 所有读写操作变 no-op，整个 app 仍能正常跑（只是 Extension 拿不到配置）。
public enum AppGroupStorage {

    /// App Group 标识符。和 entitlements 里的值必须一致。
    public static let groupIdentifier = "group.com.sbraveyoung.qingzhou"

    /// 共享容器根目录。entitlement 未配置时返回 nil。
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    /// 共享文件 URL。`name` 不含扩展名。
    public static func fileURL(_ name: String) -> URL? {
        containerURL?.appendingPathComponent(name).appendingPathExtension("json")
    }

    /// xray 写的 access log 文件（主 App 增量读解析成真实连接）。
    /// 文件名须与 XrayCore.TunnelAppGroup.accessLogName 一致（两模块互不依赖）。
    public static var accessLogURL: URL? {
        containerURL?.appendingPathComponent("access.log")
    }

    /// xray 工作目录（完整版 geo 数据等）。目录名须与
    /// XrayCore.TunnelAppGroup.ensureWorkingDirectory 一致（两模块互不依赖）：
    /// 主 App（GeoDataManager）把下载好的 geoip.dat 放这里，扩展启动时优先加载。
    public static var xrayDataDirectoryURL: URL? {
        containerURL?.appendingPathComponent("xray-data", isDirectory: true)
    }

    /// 把可编码值写到共享容器；entitlement 未配置时静默失败返回 false。
    @discardableResult
    public static func write<T: Encodable>(_ value: T, to name: String) -> Bool {
        guard let url = fileURL(name) else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// 从共享容器读可解码值。
    public static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let url = fileURL(name), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    // MARK: - 业务级 API

    /// 当前生效的 Tunnel 配置 —— Extension 启动时读这个。
    public struct TunnelConfig: Codable, Sendable {
        public var currentNode: Node
        public var customRules: [Rule]
        public var remoteRules: [Rule]
        public var proxyMode: ProxyMode

        public init(currentNode: Node, customRules: [Rule], remoteRules: [Rule], proxyMode: ProxyMode) {
            self.currentNode = currentNode
            self.customRules = customRules
            self.remoteRules = remoteRules
            self.proxyMode = proxyMode
        }
    }

    public static func writeTunnelConfig(_ config: TunnelConfig) -> Bool {
        write(config, to: "tunnel-config")
    }

    public static func readTunnelConfig() -> TunnelConfig? {
        read(TunnelConfig.self, from: "tunnel-config")
    }
}
