import Foundation
import QingzhouCore

extension AppState {
    // MARK: - 跟随出口地区

    /// 当前出口的地区画像（有节点出口信息时才非 nil）。
    public var exitRegion: ExitRegionProfile? { proxyIPInfo?.exitRegion }

    /// 是否正在"跟随出口地区"：开关打开 + 隧道在跑 + 拿到了出口地区 + 有可映射的语言/时区。
    ///
    /// 之所以只在**连接期间**生效：这是伪装的一部分，断开后就该回到本机设置。
    /// 也不改写 `settings.language` —— 用户存的语言偏好不该被一次连接悄悄改掉。
    /// iOS 无该开关 UI，即使 iCloud 同步了 macOS 的 `followExitRegion` 也必须忽略。
    public var isFollowingExitRegion: Bool {
        #if os(macOS)
        settings.followExitRegion && isVPNRunning && proxyIPInfo != nil
        #else
        false
        #endif
    }

    /// 界面实际使用的语言（可能被出口地区临时覆盖）。
    public var effectiveLanguage: AppLanguage {
        #if os(macOS)
        if isFollowingExitRegion, let lang = exitRegion?.suggestedLanguage { return lang }
        #endif
        return settings.language
    }

    /// 界面时间显示使用的时区：跟随出口时用出口时区，否则系统时区。
    public var displayTimeZone: TimeZone {
        #if os(macOS)
        if isFollowingExitRegion, let tz = exitRegion?.timeZone { return tz }
        #endif
        return .current
    }

    /// 请求 root 侧（中继的控制端口）改系统时区。传 nil = 还原到原时区。
    ///
    /// 为什么走 TCP 而不是 App Group 文件：
    /// App Group 受 TCC 保护，launchd 起的 guard 进程没有「完全磁盘访问权限」读不到
    /// （实测：guard-run.sh 在 FDA 列表里是灰的，无法授权）。网络连接不受 TCC 限制，
    /// 所以改用回环 TCP 控制端口，由 root 的中继直接执行 systemsetup。
    public func requestSystemTimeZone(_ timezoneID: String?) {
        #if os(macOS)
        guard let creds = GuardRelayCredentials.load(),
              creds.hasValidControlCredentials else { return }
        let command = timezoneID.map { "SET-TZ \($0)" } ?? "RESTORE"
        let log = self.logger
        Task.detached(priority: .utility) {
            do {
                try await Self.sendControlCommand(command, creds: creds)
            } catch {
                log.warn("时区指令发送失败：\(error.localizedDescription)", category: "region")
            }
        }
        #endif
    }

    /// 连控制端口 → 校验分离控制凭据 → AUTH → 发一条命令 → 严格要求单行响应为 "OK"。
    nonisolated static func sendControlCommand(_ command: String,
                                               creds: GuardRelayCredentials,
                                               port: UInt16? = nil,
                                               timeoutSeconds: TimeInterval = 3) async throws {
        if let cu = creds.controlUsername,
           cu.contains(where: { $0.isWhitespace || $0.isNewline || $0 == ":" }) {
            throw URLError(.badURL)
        }
        if let cp = creds.controlPassword,
           cp.contains(where: { $0.isWhitespace || $0.isNewline }) {
            throw URLError(.badURL)
        }
        guard let control = creds.validatedControlCredentials() else {
            throw URLError(.userAuthenticationRequired)
        }
        guard !command.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            throw URLError(.badURL)
        }
        let targetPort = port ?? control.port
        guard targetPort > 0 else { throw URLError(.cannotConnectToHost) }
        let host = creds.host.isEmpty ? "127.0.0.1" : creds.host
        let timeout = max(0.1, timeoutSeconds)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try Self.performControlCommandSync(
                        command,
                        host: host,
                        port: targetPort,
                        username: control.username,
                        password: control.password,
                        timeoutSeconds: timeout
                    )
                    cont.resume(returning: ())
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func performControlCommandSync(
        _ command: String,
        host: String,
        port: UInt16,
        username: String,
        password: String,
        timeoutSeconds: TimeInterval
    ) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        defer { Darwin.close(fd) }

        let totalTimeoutNs = UInt64(max(0.1, timeoutSeconds) * 1_000_000_000)
        let deadlineNs = DispatchTime.now().uptimeNanoseconds &+ totalTimeoutNs

        func remainingTimeval() throws -> timeval {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            guard nowNs < deadlineNs else { throw URLError(.timedOut) }
            let remainingUs = max(UInt64(1), (deadlineNs - nowNs) / 1_000)
            return timeval(
                tv_sec: Int(remainingUs / 1_000_000),
                tv_usec: Int32(remainingUs % 1_000_000)
            )
        }

        var tv = try remainingTimeval()
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            throw URLError(.cannotFindHost)
        }
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                Darwin.connect(fd, sap, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw URLError(.cannotConnectToHost) }

        func writeAll(_ s: String) throws {
            let data = Array((s + "\n").utf8)
            var offset = 0
            while offset < data.count {
                var sndTv = try remainingTimeval()
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sndTv, socklen_t(MemoryLayout<timeval>.size))
                let n = data.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                }
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    throw URLError(.timedOut)
                } else {
                    throw URLError(.cannotWriteToFile)
                }
            }
        }

        func readLine() throws -> String {
            var bytes: [UInt8] = []
            var one: UInt8 = 0
            while true {
                var rcvTv = try remainingTimeval()
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcvTv, socklen_t(MemoryLayout<timeval>.size))
                let n = Darwin.read(fd, &one, 1)
                if n == 1 {
                    if one == 0x0A { break }
                    if one != 0x0D { bytes.append(one) }
                    if bytes.count > 1024 { throw URLError(.badServerResponse) }
                } else if n == 0 {
                    throw bytes.isEmpty ? URLError(.zeroByteResource) : URLError(.networkConnectionLost)
                } else {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw URLError(.timedOut)
                    }
                    throw URLError(.cannotLoadFromNetwork)
                }
            }
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }

        try writeAll("AUTH \(username) \(password)")
        let authReply = try readLine()
        guard authReply == "OK" else { throw URLError(.userAuthenticationRequired) }

        try writeAll(command)
        let reply = try readLine()
        guard reply == "OK" else { throw URLError(.badServerResponse) }
    }
}
