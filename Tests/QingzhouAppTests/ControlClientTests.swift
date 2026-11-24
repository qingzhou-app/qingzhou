import XCTest
import Foundation
import Darwin
import QingzhouCore
@testable import QingzhouApp

final class ControlClientTests: XCTestCase {

    func testSendControlCommandSucceedsOnOK() async throws {
        let server = try ControlStubServer { fd in
            let auth = ControlStubServer.readLine(fd)
            XCTAssertEqual(auth, "AUTH ctrl_u ctrl_p")
            ControlStubServer.writeLine(fd, "OK")
            let cmd = ControlStubServer.readLine(fd)
            XCTAssertEqual(cmd, "SET-TZ Asia/Tokyo")
            ControlStubServer.writeLine(fd, "OK")
        }
        defer { server.stop() }

        let creds = GuardRelayCredentials(
            port: 10808,
            username: "fwd_u",
            password: "fwd_p",
            controlPort: server.port,
            controlUsername: "ctrl_u",
            controlPassword: "ctrl_p"
        )
        try await AppState.sendControlCommand("SET-TZ Asia/Tokyo", creds: creds)
    }

    func testSendControlCommandThrowsOnErrorReply() async throws {
        let server = try ControlStubServer { fd in
            _ = ControlStubServer.readLine(fd)
            ControlStubServer.writeLine(fd, "OK")
            _ = ControlStubServer.readLine(fd)
            ControlStubServer.writeLine(fd, "ERR zone")
        }
        defer { server.stop() }

        let creds = GuardRelayCredentials(
            port: 10808,
            username: "fwd_u",
            password: "fwd_p",
            controlPort: server.port,
            controlUsername: "ctrl_u",
            controlPassword: "ctrl_p"
        )
        do {
            try await AppState.sendControlCommand("SET-TZ Bad/Zone", creds: creds)
            XCTFail("Expected error on ERR reply")
        } catch {
            // expected
        }
    }

    func testSendControlCommandThrowsOnEOFEmptyReply() async throws {
        let server = try ControlStubServer { fd in
            _ = ControlStubServer.readLine(fd)
            ControlStubServer.writeLine(fd, "OK")
            _ = ControlStubServer.readLine(fd)
            // 直接关闭连接，不返回 "OK\n"（模拟 EOF / 空响应）
        }
        defer { server.stop() }

        let creds = GuardRelayCredentials(
            port: 10808,
            username: "fwd_u",
            password: "fwd_p",
            controlPort: server.port,
            controlUsername: "ctrl_u",
            controlPassword: "ctrl_p"
        )
        do {
            try await AppState.sendControlCommand("RESTORE", creds: creds)
            XCTFail("Expected error on EOF without OK")
        } catch {
            // expected
        }
    }

    func testSendControlCommandThrowsOnTimeout() async throws {
        let server = try ControlStubServer { fd in
            _ = ControlStubServer.readLine(fd)
            ControlStubServer.writeLine(fd, "OK")
            _ = ControlStubServer.readLine(fd)
            Thread.sleep(forTimeInterval: 2.2)
        }
        defer { server.stop() }

        let creds = GuardRelayCredentials(
            port: 10808,
            username: "fwd_u",
            password: "fwd_p",
            controlPort: server.port,
            controlUsername: "ctrl_u",
            controlPassword: "ctrl_p"
        )
        do {
            try await AppState.sendControlCommand("RESTORE", creds: creds, timeoutSeconds: 1)
            XCTFail("Expected timeout error")
        } catch {
            // expected
        }
    }

    func testSendControlCommandThrowsTimeoutOnDripByteSlowloris() async throws {
        let server = try ControlStubServer { fd in
            _ = ControlStubServer.readLine(fd)
            ControlStubServer.writeLine(fd, "OK")
            _ = ControlStubServer.readLine(fd)
            // 每 0.35s 滴答发送 1 字节，总时长 ~2.1s；客户端 timeoutSeconds=1.0 必须在 <1.5s 内总超时
            for byte in Array("ERR x\n".utf8) {
                Thread.sleep(forTimeInterval: 0.35)
                var b = byte
                let written = Darwin.write(fd, &b, 1)
                if written <= 0 { break }
            }
        }
        defer { server.stop() }

        let creds = GuardRelayCredentials(
            port: 10808,
            username: "fwd_u",
            password: "fwd_p",
            controlPort: server.port,
            controlUsername: "ctrl_u",
            controlPassword: "ctrl_p"
        )
        let startNs = DispatchTime.now().uptimeNanoseconds
        do {
            try await AppState.sendControlCommand("RESTORE", creds: creds, timeoutSeconds: 1.0)
            XCTFail("Expected timeout error on drip-byte slowloris response")
        } catch let urlError as URLError {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000_000
            XCTAssertEqual(urlError.code, .timedOut)
            XCTAssertLessThan(elapsed, 1.5)
        }
    }

    func testSendControlCommandRejectsMissingOrIdenticalControlCreds() async {
        let missing = GuardRelayCredentials(port: 10808, username: "fwd_u", password: "fwd_p")
        do {
            try await AppState.sendControlCommand("RESTORE", creds: missing)
            XCTFail("Expected error when control credentials missing")
        } catch {
            // expected
        }

        let identical = GuardRelayCredentials(
            port: 10808,
            username: "same_u",
            password: "same_p",
            controlPort: 10809,
            controlUsername: "same_u",
            controlPassword: "same_p"
        )
        do {
            try await AppState.sendControlCommand("RESTORE", creds: identical)
            XCTFail("Expected error when control credentials match forwarding credentials")
        } catch {
            // expected
        }
    }
}

private final class ControlStubServer: @unchecked Sendable {
    private let listenFD: Int32
    let port: UInt16
    private let lock = NSLock()
    private var stopped = false

    init(handler: @escaping @Sendable (Int32) -> Void) throws {
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
                    handler(client)
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

    static func readLine(_ fd: Int32) -> String {
        var bytes: [UInt8] = []
        var b: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &b, 1)
            if n == 1 {
                if b == 0x0A { break }
                if b != 0x0D { bytes.append(b) }
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func writeLine(_ fd: Int32, _ text: String) {
        let data = Array((text + "\n").utf8)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
    }
}
