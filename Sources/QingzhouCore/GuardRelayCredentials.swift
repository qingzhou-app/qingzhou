import Foundation

/// 断网开关（Tools/qingzhou-guard）的 root 中继凭据。
///
/// 放在 QingzhouCore 而不是 App 里：隧道扩展也要用它（解 providerConfiguration 里的
/// `guardRelayJSON`），而扩展不依赖 QingzhouApp。读文件那半边在 App 侧（App Group 路径）。
public struct GuardRelayCredentials: Codable, Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var username: String
    public var password: String

    public init(host: String = "127.0.0.1", port: UInt16, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    /// App Group 里的文件名（install.sh 写的也是这个名字）。
    public static let fileName = "guard-relay.json"

    /// 控制端口：中继以 root 执行 App 请求的动作（目前只有改系统时区）。
    /// 与转发的 10808 分开，避免指令流量混进代理流量。
    public static let controlPort: UInt16 = 10809

    /// 序列化成 providerConfiguration 里的一段 JSON（plist 不接受任意 Codable）。
    public var jsonString: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 隧道扩展侧：从 providerConfiguration 的字符串还原。空串 / 坏数据 → nil。
    public static func decode(_ raw: String) -> GuardRelayCredentials? {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        let creds = try? JSONDecoder().decode(GuardRelayCredentials.self, from: data)
        guard let creds, !creds.username.isEmpty, !creds.password.isEmpty, creds.port > 0 else { return nil }
        return creds
    }
}
