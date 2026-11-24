import Foundation

public struct RelayConfig: Sendable, Equatable {
    public var port: UInt16
    /// 控制端口：App（沙箱、无 root）通过它请求 root 侧动作（目前只有改时区）。
    public var controlPort: UInt16
    public var authFile: String
    public var logPath: String
    public var tzOrigPath: String

    public init(
        port: UInt16 = 10808,
        controlPort: UInt16 = 10809,
        authFile: String = "/Library/Application Support/qingzhou-guard/relay-auth",
        logPath: String = "/var/log/qingzhou-relay.log",
        tzOrigPath: String = "/Library/Application Support/qingzhou-guard/timezone-orig"
    ) {
        self.port = port
        self.controlPort = controlPort
        self.authFile = authFile
        self.logPath = logPath
        self.tzOrigPath = tzOrigPath
    }

    public static func parseArgs(_ arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> RelayConfig {
        var cfg = RelayConfig()
        var args = arguments
        while let key = args.first {
            args.removeFirst()
            func next() -> String? { args.isEmpty ? nil : args.removeFirst() }
            switch key {
            case "--port":
                if let v = next(), let p = UInt16(v) { cfg.port = p }
            case "--control-port":
                if let v = next(), let p = UInt16(v) { cfg.controlPort = p }
            case "--auth-file":
                if let v = next() { cfg.authFile = v }
            case "--log":
                if let v = next() { cfg.logPath = v }
            case "--tz-orig":
                if let v = next() { cfg.tzOrigPath = v }
            default:
                break
            }
        }
        return cfg
    }
}
