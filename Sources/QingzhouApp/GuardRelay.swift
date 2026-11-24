import Foundation
import QingzhouCore

/// App 侧：从 App Group 读取中继凭据。
///
/// 为什么不读 `/Library/Application Support/qingzhou-guard/relay-auth`：那份是 600 root 只读，
/// App 读不到。install.sh 会把同一份凭据另写一份到 App Group 容器（属主=当前用户），
/// 这个扩展只负责把它读出来。
extension GuardRelayCredentials {
    public static func load() -> GuardRelayCredentials? {
        guard let url = AppGroupStorage.containerURL?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(String(decoding: data, as: UTF8.self))
    }
}
