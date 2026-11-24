import Foundation

/// 断网开关（Tools/qingzhou-guard）的 root 中继凭据。
///
/// 放在 QingzhouCore 而不是 App 里：隧道扩展也要用它（解 providerConfiguration 里的
/// `guardRelayJSON`），而扩展不依赖 QingzhouApp。读文件那半边在 App 侧（App Group 路径）。
public struct GuardRelayCredentials: Codable, Sendable, Equatable {
    public struct ControlCredentials: Sendable, Equatable {
        public let port: UInt16
        public let username: String
        public let password: String

        public init(port: UInt16, username: String, password: String) {
            self.port = port
            self.username = username
            self.password = password
        }
    }

    public var host: String
    public var port: UInt16
    public var username: String
    public var password: String
    public var controlPort: UInt16?
    public var controlUsername: String?
    public var controlPassword: String?

    public init(
        host: String = "127.0.0.1",
        port: UInt16,
        username: String,
        password: String,
        controlPort: UInt16? = nil,
        controlUsername: String? = nil,
        controlPassword: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.controlPort = controlPort
        self.controlUsername = controlUsername
        self.controlPassword = controlPassword
    }

    /// App Group 里的文件名（install.sh 写的也是这个名字）。
    public static let fileName = "guard-relay.json"

    /// 控制端口：中继以 root 执行 App 请求的动作（目前只有改系统时区）。
    /// 与转发的 10808 分开，避免指令流量混进代理流量。
    public static let controlPort: UInt16 = 10809

    /// 剥离控制凭据，仅保留转发凭据（供隧道扩展的 xray relay 出站使用）。
    public var forwardingOnly: GuardRelayCredentials {
        GuardRelayCredentials(host: host, port: port, username: username, password: password)
    }

    /// 校验并提取控制凭据：要求控制用户名/密码非空、控制端口有效、且与转发凭据分离（不相同）。
    public func validatedControlCredentials() -> ControlCredentials? {
        let resolvedPort = controlPort ?? Self.controlPort
        guard resolvedPort > 0,
              let cu = controlUsername, !cu.isEmpty,
              let cp = controlPassword, !cp.isEmpty,
              !(cu == username && cp == password) else {
            return nil
        }
        return ControlCredentials(port: resolvedPort, username: cu, password: cp)
    }

    public var hasValidControlCredentials: Bool {
        validatedControlCredentials() != nil
    }

    /// 序列化成 providerConfiguration 里的一段 JSON（plist 不接受任意 Codable）。
    public var jsonString: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 隧道扩展侧：从 providerConfiguration 的字符串还原。空串 / 坏数据 → nil。
    public static func decode(_ raw: String) -> GuardRelayCredentials? {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        let creds = try? JSONDecoder().decode(GuardRelayCredentials.self, from: data)
        guard let creds, !creds.host.isEmpty, !creds.username.isEmpty, !creds.password.isEmpty, creds.port > 0 else { return nil }
        return creds
    }
}
