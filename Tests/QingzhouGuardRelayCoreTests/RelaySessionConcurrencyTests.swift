import XCTest
import Foundation
import Darwin
import Network
@testable import QingzhouGuardRelayCore

private final class StubTZProvider: TimeZoneProviding, @unchecked Sendable {
    private let lock = NSLock()
    var current = "Asia/Shanghai"

    func currentTimeZone() -> String {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func setSystemTimeZone(_ identifier: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        current = identifier
        return true
    }

    func isValidTimeZone(_ identifier: String) -> Bool {
        ["Asia/Shanghai", "America/New_York", "UTC"].contains(identifier)
    }
}

final class RelaySessionConcurrencyTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-conc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testControlSessionRejectsOversizedLineAndEnforcesControlCredsOnly() throws {
        let creds = try XCTUnwrap(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_u", pass: "fwd_p"),
            control: CredentialPair(user: "ctrl_u", pass: "ctrl_p")
        ))
        let tz = StubTZProvider()
        let cfg = RelayConfig(
            port: 0,
            controlPort: 0,
            authFile: tempDir.appendingPathComponent("auth").path,
            logPath: tempDir.appendingPathComponent("relay.log").path,
            tzOrigPath: tempDir.appendingPathComponent("tz-orig").path
        )
        let server = RelayServer(
            config: cfg,
            creds: creds,
            logger: RelayLogger(logPath: cfg.logPath),
            timeZoneProvider: tz,
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        defer { server.stop() }
        let controlPort = try XCTUnwrap(ports.controlPort)

        // 1. 拿转发凭据尝试连控制端口 → 必须被拒绝
        do {
            let fd = try connectLoopback(port: controlPort)
            defer { Darwin.close(fd) }
            try sendAll(fd, "AUTH fwd_u fwd_p\n")
            XCTAssertEqual(try readLine(fd), "ERR auth")
        }

        // 2. 拿控制凭据认证并切换时区再切回原时区
        do {
            let fd = try connectLoopback(port: controlPort)
            defer { Darwin.close(fd) }
            try sendAll(fd, "AUTH ctrl_u ctrl_p\n")
            XCTAssertEqual(try readLine(fd), "OK")
            try sendAll(fd, "SET-TZ America/New_York\n")
            XCTAssertEqual(try readLine(fd), "OK")
            try sendAll(fd, "GET-TZ\n")
            XCTAssertEqual(try readLine(fd), "America/New_York")
            try sendAll(fd, "SET-TZ Asia/Shanghai\n")
            XCTAssertEqual(try readLine(fd), "OK")
            try sendAll(fd, "GET-TZ\n")
            XCTAssertEqual(try readLine(fd), "Asia/Shanghai")
        }

        // 3. 超长未换行行缓冲 (> 1024 字节) → 必须回 ERR too-long 并断开
        do {
            let fd = try connectLoopback(port: controlPort)
            defer { Darwin.close(fd) }
            let oversized = String(repeating: "A", count: 1200)
            try sendAll(fd, oversized)
            XCTAssertEqual(try readLine(fd), "ERR too-long")
        }
    }

    func testClientSessionSOCKS5ForwardingAndCredentialSeparation() throws {
        let creds = try XCTUnwrap(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_u", pass: "fwd_p"),
            control: CredentialPair(user: "ctrl_u", pass: "ctrl_p")
        ))
        let cfg = RelayConfig(
            port: 0,
            controlPort: 0,
            authFile: tempDir.appendingPathComponent("auth").path,
            logPath: tempDir.appendingPathComponent("relay.log").path,
            tzOrigPath: tempDir.appendingPathComponent("tz-orig").path
        )
        let server = RelayServer(
            config: cfg,
            creds: creds,
            logger: RelayLogger(logPath: cfg.logPath),
            timeZoneProvider: StubTZProvider(),
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        defer { server.stop() }

        let echo = try LoopbackTCPEchoServer()
        defer { echo.stop() }

        // 1. 拿控制凭据连转发端口 → 必须认证失败
        do {
            let fd = try connectLoopback(port: ports.forwardPort)
            defer { Darwin.close(fd) }
            try sendBytes(fd, [0x05, 0x01, 0x02])
            XCTAssertEqual(try readExact(fd, count: 2), [0x05, 0x02])
            let auth = makeAuthPacket(user: "ctrl_u", pass: "ctrl_p")
            try sendBytes(fd, auth)
            XCTAssertEqual(try readExact(fd, count: 2), [0x01, 0x01])
        }

        // 2. 拿转发凭据正常 CONNECT 到本地回环 echo 服务
        do {
            let fd = try connectLoopback(port: ports.forwardPort)
            defer { Darwin.close(fd) }
            try sendBytes(fd, [0x05, 0x01, 0x02])
            XCTAssertEqual(try readExact(fd, count: 2), [0x05, 0x02])
            try sendBytes(fd, makeAuthPacket(user: "fwd_u", pass: "fwd_p"))
            XCTAssertEqual(try readExact(fd, count: 2), [0x01, 0x00])

            let pHi = UInt8(echo.port >> 8)
            let pLo = UInt8(echo.port & 0xFF)
            try sendBytes(fd, [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, pHi, pLo])
            let reply = try readExact(fd, count: 10)
            XCTAssertEqual(reply[0], 0x05)
            XCTAssertEqual(reply[1], 0x00)

            let payload = Array("hello-relay".utf8)
            try sendBytes(fd, payload)
            XCTAssertEqual(try readExact(fd, count: payload.count), payload)
        }
    }

    func testConcurrentClientAndControlConnectCloseStressForTSan() throws {
        let creds = try XCTUnwrap(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_u", pass: "fwd_p"),
            control: CredentialPair(user: "ctrl_u", pass: "ctrl_p")
        ))
        let cfg = RelayConfig(
            port: 0,
            controlPort: 0,
            authFile: tempDir.appendingPathComponent("auth").path,
            logPath: tempDir.appendingPathComponent("relay.log").path,
            tzOrigPath: tempDir.appendingPathComponent("tz-orig").path
        )
        let server = RelayServer(
            config: cfg,
            creds: creds,
            logger: RelayLogger(logPath: cfg.logPath),
            timeZoneProvider: StubTZProvider(),
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        defer { server.stop() }
        let controlPort = try XCTUnwrap(ports.controlPort)

        let echo = try LoopbackTCPEchoServer()
        defer { echo.stop() }

        let forwardPort = ports.forwardPort
        let echoPort = echo.port
        let group = DispatchGroup()
        for i in 0..<24 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                if i % 2 == 0 {
                    // 并发 SOCKS5 半开 / 正常转发后立即关闭
                    guard let fd = try? Self.connectLoopback(port: forwardPort) else { return }
                    defer { Darwin.close(fd) }
                    _ = try? Self.sendBytes(fd, [0x05, 0x01, 0x02])
                    _ = try? Self.readExact(fd, count: 2)
                    if i % 4 == 0 {
                        _ = try? Self.sendBytes(fd, Self.makeAuthPacket(user: "fwd_u", pass: "fwd_p"))
                        _ = try? Self.readExact(fd, count: 2)
                        let pHi = UInt8(echoPort >> 8)
                        let pLo = UInt8(echoPort & 0xFF)
                        _ = try? Self.sendBytes(fd, [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, pHi, pLo])
                        _ = try? Self.readExact(fd, count: 10)
                        _ = try? Self.sendBytes(fd, Array("ping".utf8))
                    }
                } else {
                    // 并发控制连接：部分直接断开、部分认证后切时区
                    guard let fd = try? Self.connectLoopback(port: controlPort) else { return }
                    defer { Darwin.close(fd) }
                    if i % 3 == 0 {
                        _ = try? Self.sendAll(fd, "AUTH ctrl_u ctrl_p\nGET-TZ\n")
                        _ = try? Self.readLine(fd)
                    } else {
                        _ = try? Self.sendAll(fd, "AUTH bad bad\n")
                    }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
    }

    func testClientSessionSupportsTCPHalfCloseShutdownWriteAndDeliversDelayedResponse() throws {
        let creds = try XCTUnwrap(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_u", pass: "fwd_p"),
            control: CredentialPair(user: "ctrl_u", pass: "ctrl_p")
        ))
        let cfg = RelayConfig(
            port: 0,
            controlPort: 0,
            authFile: tempDir.appendingPathComponent("auth").path,
            logPath: tempDir.appendingPathComponent("relay.log").path,
            tzOrigPath: tempDir.appendingPathComponent("tz-orig").path
        )
        let server = RelayServer(
            config: cfg,
            creds: creds,
            logger: RelayLogger(logPath: cfg.logPath),
            timeZoneProvider: StubTZProvider(),
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        defer { server.stop() }

        let expectedResponse = "HTTP/1.0 200 OK\r\n\r\nBODY"
        let httpServer = try LoopbackDelayedHTTPServer(delay: 0.05, response: expectedResponse)
        defer { httpServer.stop() }

        let fd = try connectLoopback(port: ports.forwardPort)
        defer { Darwin.close(fd) }

        try sendBytes(fd, [0x05, 0x01, 0x02])
        XCTAssertEqual(try readExact(fd, count: 2), [0x05, 0x02])
        try sendBytes(fd, makeAuthPacket(user: "fwd_u", pass: "fwd_p"))
        XCTAssertEqual(try readExact(fd, count: 2), [0x01, 0x00])

        let pHi = UInt8(httpServer.port >> 8)
        let pLo = UInt8(httpServer.port & 0xFF)
        try sendBytes(fd, [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, pHi, pLo])
        let reply = try readExact(fd, count: 10)
        XCTAssertEqual(reply[0], 0x05)
        XCTAssertEqual(reply[1], 0x00)

        try sendAll(fd, "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")
        XCTAssertEqual(Darwin.shutdown(fd, SHUT_WR), 0)

        let body = try Self.readToEOF(fd)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), expectedResponse)
    }

    func testControlSessionCRLF1024ByteBoundary() throws {
        let creds = try XCTUnwrap(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_u", pass: "fwd_p"),
            control: CredentialPair(user: "ctrl_u", pass: "ctrl_p")
        ))
        let cfg = RelayConfig(
            port: 0,
            controlPort: 0,
            authFile: tempDir.appendingPathComponent("auth").path,
            logPath: tempDir.appendingPathComponent("relay.log").path,
            tzOrigPath: tempDir.appendingPathComponent("tz-orig").path
        )
        let server = RelayServer(
            config: cfg,
            creds: creds,
            logger: RelayLogger(logPath: cfg.logPath),
            timeZoneProvider: StubTZProvider(),
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        defer { server.stop() }
        let controlPort = try XCTUnwrap(ports.controlPort)

        // 1. 1024 字节 + "\r\n"：剥离 \r 后恰好 1024 字节，正常处理（未认证故回 ERR auth，而非 ERR too-long）
        do {
            let fd = try connectLoopback(port: controlPort)
            defer { Darwin.close(fd) }
            let exactLine = String(repeating: "A", count: 1024) + "\r\n"
            try sendAll(fd, exactLine)
            XCTAssertEqual(try readLine(fd), "ERR auth")
        }

        // 2. 分片发送 1024 字节 + "\r"，再补 "\n"：依然正常处理而非误判 ERR too-long
        do {
            let fd = try connectLoopback(port: controlPort)
            defer { Darwin.close(fd) }
            try sendAll(fd, String(repeating: "A", count: 1024) + "\r")
            Thread.sleep(forTimeInterval: 0.02)
            try sendAll(fd, "\n")
            XCTAssertEqual(try readLine(fd), "ERR auth")
        }

        // 3. 1025 字节 + "\r\n"：超过 maxLineBytes，必须回 ERR too-long
        do {
            let fd = try connectLoopback(port: controlPort)
            defer { Darwin.close(fd) }
            let overLine = String(repeating: "A", count: 1025) + "\r\n"
            try sendAll(fd, overLine)
            XCTAssertEqual(try readLine(fd), "ERR too-long")
        }

        // 4. 1025 字节 + "\n"：超过 maxLineBytes，必须回 ERR too-long
        do {
            let fd = try connectLoopback(port: controlPort)
            defer { Darwin.close(fd) }
            let overLine = String(repeating: "A", count: 1025) + "\n"
            try sendAll(fd, overLine)
            XCTAssertEqual(try readLine(fd), "ERR too-long")
        }
    }

    // MARK: - Socket Helpers

    private func connectLoopback(port: UInt16) throws -> Int32 {
        try Self.connectLoopback(port: port)
    }

    private func sendAll(_ fd: Int32, _ text: String) throws {
        try Self.sendAll(fd, text)
    }

    private func sendBytes(_ fd: Int32, _ bytes: [UInt8]) throws {
        try Self.sendBytes(fd, bytes)
    }

    private func readLine(_ fd: Int32) throws -> String {
        try Self.readLine(fd)
    }

    private func readExact(_ fd: Int32, count: Int) throws -> [UInt8] {
        try Self.readExact(fd, count: count)
    }

    private func makeAuthPacket(user: String, pass: String) -> [UInt8] {
        Self.makeAuthPacket(user: user, pass: pass)
    }

    private static func connectLoopback(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                Darwin.connect(fd, sap, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            Darwin.close(fd)
            throw URLError(.cannotConnectToHost)
        }
        return fd
    }

    private static func sendAll(_ fd: Int32, _ text: String) throws {
        try sendBytes(fd, Array(text.utf8))
    }

    private static func sendBytes(_ fd: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if n > 0 { offset += n }
            else if n < 0 && errno == EINTR { continue }
            else { throw URLError(.cannotWriteToFile) }
        }
    }

    private static func readLine(_ fd: Int32) throws -> String {
        var out: [UInt8] = []
        var b: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &b, 1)
            if n == 1 {
                if b == 0x0A { break }
                if b != 0x0D { out.append(b) }
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func readExact(_ fd: Int32, count: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: count)
        while out.count < count {
            let rem = count - out.count
            let n = buf.withUnsafeMutableBufferPointer { bp in
                Darwin.read(fd, bp.baseAddress, rem)
            }
            if n > 0 {
                out.append(contentsOf: buf[0..<n])
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                throw URLError(.networkConnectionLost)
            }
        }
        return out
    }

    private static func makeAuthPacket(user: String, pass: String) -> [UInt8] {
        let u = Array(user.utf8)
        let p = Array(pass.utf8)
        return [0x01, UInt8(u.count)] + u + [UInt8(p.count)] + p
    }

    private static func readToEOF(_ fd: Int32) throws -> [UInt8] {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { bp in
                Darwin.read(fd, bp.baseAddress, bp.count)
            }
            if n > 0 {
                out.append(contentsOf: buf[0..<n])
            } else if n == 0 {
                return out
            } else if errno == EINTR {
                continue
            } else {
                throw URLError(.networkConnectionLost)
            }
        }
    }
}

private final class LoopbackDelayedHTTPServer: @unchecked Sendable {
    private let listenFD: Int32
    let port: UInt16
    private let lock = NSLock()
    private var stopped = false

    init(delay: TimeInterval, response: String) throws {
        let sockFD = socket(AF_INET, SOCK_STREAM, 0)
        guard sockFD >= 0 else { throw URLError(.cannotOpenFile) }
        self.listenFD = sockFD
        var yes: Int32 = 1
        setsockopt(sockFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                Darwin.bind(sockFD, sap, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0, Darwin.listen(sockFD, 8) == 0 else {
            Darwin.close(sockFD)
            throw URLError(.cannotOpenFile)
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                getsockname(sockFD, sap, &len)
            }
        }
        self.port = UInt16(bigEndian: bound.sin_port)

        let fd = sockFD
        DispatchQueue.global().async { [weak self] in
            while true {
                guard let self else { break }
                self.lock.lock()
                let done = self.stopped
                self.lock.unlock()
                if done { break }
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { break }
                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.global().async {
                    defer { Darwin.close(client) }
                    var buf = [UInt8](repeating: 0, count: 1024)
                    while true {
                        let n = buf.withUnsafeMutableBufferPointer { Darwin.read(client, $0.baseAddress, $0.count) }
                        if n == 0 { break }
                        if n < 0 {
                            if errno == EINTR { continue }
                            return
                        }
                    }
                    Thread.sleep(forTimeInterval: delay)
                    let payload = Array(response.utf8)
                    _ = payload.withUnsafeBytes { Darwin.write(client, $0.baseAddress, payload.count) }
                }
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        Darwin.close(listenFD)
    }
}

private final class LoopbackTCPEchoServer: @unchecked Sendable {
    private let listenFD: Int32
    let port: UInt16
    private let lock = NSLock()
    private var stopped = false

    init() throws {
        let sockFD = socket(AF_INET, SOCK_STREAM, 0)
        guard sockFD >= 0 else { throw URLError(.cannotOpenFile) }
        self.listenFD = sockFD
        var yes: Int32 = 1
        setsockopt(sockFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                Darwin.bind(sockFD, sap, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0, Darwin.listen(sockFD, 16) == 0 else {
            Darwin.close(sockFD)
            throw URLError(.cannotOpenFile)
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                getsockname(sockFD, sap, &len)
            }
        }
        self.port = UInt16(bigEndian: bound.sin_port)

        let fd = sockFD
        DispatchQueue.global().async { [weak self] in
            while true {
                guard let self else { break }
                self.lock.lock()
                let done = self.stopped
                self.lock.unlock()
                if done { break }
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { break }
                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.global().async {
                    defer { Darwin.close(client) }
                    var buf = [UInt8](repeating: 0, count: 1024)
                    while true {
                        let n = buf.withUnsafeMutableBufferPointer { Darwin.read(client, $0.baseAddress, $0.count) }
                        if n <= 0 { break }
                        _ = buf.withUnsafeBytes { Darwin.write(client, $0.baseAddress, n) }
                    }
                }
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        Darwin.close(listenFD)
    }
}
