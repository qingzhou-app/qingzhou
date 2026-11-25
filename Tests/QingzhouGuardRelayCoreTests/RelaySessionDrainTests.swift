import XCTest
import Foundation
import Darwin
import Network
@testable import QingzhouGuardRelayCore

private final class DrainStubTZProvider: TimeZoneProviding, @unchecked Sendable {
    func currentTimeZone() -> String { "UTC" }
    func setSystemTimeZone(_ identifier: String) -> Bool { true }
    func isValidTimeZone(_ identifier: String) -> Bool { true }
}

final class RelaySessionDrainTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-drain-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testHighConcurrencyImmediateUpstreamCloseAfterSendPreservesPayload() throws {
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
            timeZoneProvider: DrainStubTZProvider(),
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        defer { server.stop() }

        let payloadSize = 16 * 1024
        let upstream = try LoopbackImmediateWriteAndCloseServer { reqLine in
            let idxString = reqLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let idx = Int(idxString) ?? -1
            return Self.makeDeterministicPayload(tag: idx, size: payloadSize)
        }
        defer { upstream.stop() }

        let taskCount = 48
        let forwardPort = ports.forwardPort
        let upstreamPort = upstream.port
        let lock = NSLock()
        nonisolated(unsafe) var failures: [String] = []
        let group = DispatchGroup()

        for i in 0..<taskCount {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let fd = try Self.connectLoopback(port: forwardPort)
                    defer { Darwin.close(fd) }

                    try Self.performSOCKS5Connect(
                        fd: fd,
                        user: "fwd_u",
                        pass: "fwd_p",
                        targetPort: upstreamPort
                    )
                    try Self.sendAll(fd, "\(i)\n")
                    XCTAssertEqual(Darwin.shutdown(fd, SHUT_WR), 0)

                    let received = try Self.readToEOF(fd)
                    let expected = Self.makeDeterministicPayload(tag: i, size: payloadSize)
                    if received != expected {
                        lock.lock()
                        failures.append("task \(i): expected \(expected.count) bytes, got \(received.count) bytes")
                        lock.unlock()
                    }
                } catch {
                    lock.lock()
                    failures.append("task \(i): threw \(error)")
                    lock.unlock()
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testClientToUpstreamImmediateCloseAfterWritePreservesPayload() throws {
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
            timeZoneProvider: DrainStubTZProvider(),
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        defer { server.stop() }

        let taskCount = 24
        let payloadSize = 16 * 1024
        let sink = try LoopbackSinkServer(expectedConnections: taskCount)
        defer { sink.stop() }

        let forwardPort = ports.forwardPort
        let sinkPort = sink.port
        let lock = NSLock()
        nonisolated(unsafe) var clientErrors: [String] = []
        let group = DispatchGroup()

        for i in 0..<taskCount {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let fd = try Self.connectLoopback(port: forwardPort)
                    var closed = false
                    defer { if !closed { Darwin.close(fd) } }

                    try Self.performSOCKS5Connect(
                        fd: fd,
                        user: "fwd_u",
                        pass: "fwd_p",
                        targetPort: sinkPort
                    )
                    let payload = Self.makeDeterministicPayload(tag: i, size: payloadSize)
                    try Self.sendBytes(fd, payload)
                    _ = Darwin.shutdown(fd, SHUT_WR)
                    Darwin.close(fd)
                    closed = true
                } catch {
                    lock.lock()
                    clientErrors.append("task \(i): threw \(error)")
                    lock.unlock()
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertTrue(clientErrors.isEmpty, clientErrors.joined(separator: "\n"))
        XCTAssertTrue(sink.waitForAll(timeout: 10), "Timed out waiting for all \(taskCount) upstream connections to reach EOF")

        let receivedPayloads = sink.snapshotPayloads()
        XCTAssertEqual(receivedPayloads.count, taskCount)
        let expectedSet = Set((0..<taskCount).map { Data(Self.makeDeterministicPayload(tag: $0, size: payloadSize)) })
        let actualSet = Set(receivedPayloads)
        XCTAssertEqual(actualSet.count, taskCount)
        XCTAssertEqual(actualSet, expectedSet)
    }

    func testStalledClientDrainTimeoutUnregistersSession() throws {
        let creds = CredentialPair(user: "fwd_u", pass: "fwd_p")
        let registry = SessionRegistry<ClientSession>()
        let (listener, listenerPort) = try Self.startSessionListener(
            creds: creds,
            registry: registry,
            drainTimeout: 0.15
        )
        defer { listener.cancel() }

        // Upstream writes 2 MiB to fill client/relay socket buffers while client stops reading
        let chunk = [UInt8](repeating: 0x5A, count: 64 * 1024)
        let upstream = try LoopbackLargeWriteAndCloseServer(totalBytes: 2 * 1024 * 1024, chunk: chunk)
        defer { upstream.stop() }

        let fd = try Self.connectLoopback(port: listenerPort, receiveBufferBytes: 4096)
        defer { Darwin.close(fd) }

        try Self.performSOCKS5Connect(
            fd: fd,
            user: "fwd_u",
            pass: "fwd_p",
            targetPort: upstream.port
        )
        XCTAssertEqual(registry.count, 1)

        // Trigger upstream bulk write and half-close without calling read() on fd
        try Self.sendAll(fd, "GO\n")
        XCTAssertEqual(Darwin.shutdown(fd, SHUT_WR), 0)

        let deadline = Date().addingTimeInterval(1.5)
        while registry.count > 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(registry.count, 0, "Stalled client session must unregister within drainTimeout")
    }

    func testHandshakeRejectionUnregistersSession() throws {
        let creds = CredentialPair(user: "fwd_u", pass: "fwd_p")
        let registry = SessionRegistry<ClientSession>()
        let (listener, listenerPort) = try Self.startSessionListener(
            creds: creds,
            registry: registry,
            drainTimeout: 0.5
        )
        defer { listener.cancel() }

        // 1. Unsupported auth method
        do {
            let fd = try Self.connectLoopback(port: listenerPort)
            defer { Darwin.close(fd) }
            try Self.sendBytes(fd, [0x05, 0x01, 0x00])
            XCTAssertEqual(try Self.readExact(fd, count: 2), [0x05, 0xFF])
            XCTAssertEqual(try Self.readToEOF(fd), [])
        }
        XCTAssertTrue(Self.waitUntil(timeout: 1.0) { registry.count == 0 }, "Session leaked on unsupported auth method")

        // 2. Bad auth sub-version
        do {
            let fd = try Self.connectLoopback(port: listenerPort)
            defer { Darwin.close(fd) }
            try Self.sendBytes(fd, [0x05, 0x01, 0x02])
            XCTAssertEqual(try Self.readExact(fd, count: 2), [0x05, 0x02])
            try Self.sendBytes(fd, [0x02, 0x01, 0x61, 0x01, 0x62])
            XCTAssertEqual(try Self.readExact(fd, count: 2), [0x01, 0x01])
            XCTAssertEqual(try Self.readToEOF(fd), [])
        }
        XCTAssertTrue(Self.waitUntil(timeout: 1.0) { registry.count == 0 }, "Session leaked on bad auth sub-version")

        // 3. Invalid credentials
        do {
            let fd = try Self.connectLoopback(port: listenerPort)
            defer { Darwin.close(fd) }
            try Self.sendBytes(fd, [0x05, 0x01, 0x02])
            XCTAssertEqual(try Self.readExact(fd, count: 2), [0x05, 0x02])
            try Self.sendBytes(fd, Self.makeAuthPacket(user: "wrong", pass: "creds"))
            XCTAssertEqual(try Self.readExact(fd, count: 2), [0x01, 0x01])
            XCTAssertEqual(try Self.readToEOF(fd), [])
        }
        XCTAssertTrue(Self.waitUntil(timeout: 1.0) { registry.count == 0 }, "Session leaked on invalid credentials")
    }

    func testControlSessionPipelinedBatchWithHalfClosePreservesAllReplies() throws {
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
            timeZoneProvider: DrainStubTZProvider(),
            requirePhysicalInterface: false
        )
        let ports = try server.start()
        defer { server.stop() }
        let controlPort = try XCTUnwrap(ports.controlPort)

        let fd = try Self.connectLoopback(port: controlPort, receiveBufferBytes: 1024)
        defer { Darwin.close(fd) }

        let batchCount = 5000
        var payload = "AUTH ctrl_u ctrl_p\n"
        payload.reserveCapacity(payload.count + batchCount * 7)
        for _ in 0..<batchCount {
            payload += "GET-TZ\n"
        }
        try Self.sendAll(fd, payload)
        XCTAssertEqual(Darwin.shutdown(fd, SHUT_WR), 0)

        let raw = try Self.readToEOF(fd)
        let text = String(decoding: raw, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
        XCTAssertEqual(lines.count, batchCount + 1, "Expected 5001 control reply lines, got \(lines.count)")
        XCTAssertEqual(lines.first, "OK")
        XCTAssertTrue(lines.dropFirst().allSatisfy { $0 == "UTC" })
    }

    // MARK: - Helpers

    private static func makeDeterministicPayload(tag: Int, size: Int) -> [UInt8] {
        let header = Array("TAG-\(tag):".utf8)
        var out = [UInt8]()
        out.reserveCapacity(size)
        out.append(contentsOf: header)
        var byteVal = UInt8(truncatingIfNeeded: tag)
        while out.count < size {
            out.append(byteVal)
            byteVal &+= 1
        }
        if out.count > size {
            out.removeLast(out.count - size)
        }
        return out
    }

    private static func startSessionListener(
        creds: CredentialPair,
        registry: SessionRegistry<ClientSession>,
        drainTimeout: TimeInterval
    ) throws -> (NWListener, UInt16) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "test.drain.listener.\(UUID().uuidString)")
        let dns = RelayDNS(servers: [])

        final class ReadyBox: @unchecked Sendable {
            let sem = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var port: UInt16 = 0
            var error: Error?
            var done = false
        }
        let box = ReadyBox()

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.lock.lock()
                box.port = listener.port?.rawValue ?? 0
                let shouldSignal = !box.done
                box.done = true
                box.lock.unlock()
                if shouldSignal { box.sem.signal() }
            case .failed(let err):
                box.lock.lock()
                box.error = err
                let shouldSignal = !box.done
                box.done = true
                box.lock.unlock()
                if shouldSignal { box.sem.signal() }
            default:
                break
            }
        }
        listener.newConnectionHandler = { conn in
            ClientSession(
                conn,
                creds: creds,
                registry: registry,
                dns: dns,
                egressProvider: { nil },
                requirePhysicalInterface: false,
                logger: nil,
                drainTimeout: drainTimeout
            ).start()
        }
        listener.start(queue: queue)
        _ = box.sem.wait(timeout: .now() + 5)

        box.lock.lock()
        let err = box.error
        let port = box.port
        box.lock.unlock()
        if let err {
            listener.cancel()
            throw err
        }
        guard port > 0 else {
            listener.cancel()
            throw URLError(.cannotOpenFile)
        }
        return (listener, port)
    }

    private static func waitUntil(timeout: TimeInterval, predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return predicate()
    }

    private static func connectLoopback(port: UInt16, receiveBufferBytes: Int32? = nil) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        if var rcvBuf = receiveBufferBytes {
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))
        }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
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

    private static func performSOCKS5Connect(fd: Int32, user: String, pass: String, targetPort: UInt16) throws {
        try sendBytes(fd, [0x05, 0x01, 0x02])
        XCTAssertEqual(try readExact(fd, count: 2), [0x05, 0x02])
        try sendBytes(fd, makeAuthPacket(user: user, pass: pass))
        XCTAssertEqual(try readExact(fd, count: 2), [0x01, 0x00])
        let pHi = UInt8(targetPort >> 8)
        let pLo = UInt8(targetPort & 0xFF)
        try sendBytes(fd, [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, pHi, pLo])
        let reply = try readExact(fd, count: 10)
        XCTAssertEqual(reply[0], 0x05)
        XCTAssertEqual(reply[1], 0x00)
    }

    private static func makeAuthPacket(user: String, pass: String) -> [UInt8] {
        let u = Array(user.utf8)
        let p = Array(pass.utf8)
        return [0x01, UInt8(u.count)] + u + [UInt8(p.count)] + p
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
            if n > 0 {
                offset += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                throw URLError(.cannotWriteToFile)
            }
        }
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

private final class LoopbackImmediateWriteAndCloseServer: @unchecked Sendable {
    private let listenFD: Int32
    let port: UInt16
    private let lock = NSLock()
    private var stopped = false

    init(payloadBuilder: @escaping @Sendable (String) -> [UInt8]) throws {
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
        guard rc == 0, Darwin.listen(sockFD, 64) == 0 else {
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
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

                DispatchQueue.global().async {
                    var lineBytes: [UInt8] = []
                    var byte: UInt8 = 0
                    while true {
                        let n = Darwin.read(client, &byte, 1)
                        if n == 1 {
                            if byte == 0x0A { break }
                            lineBytes.append(byte)
                        } else if n < 0 && errno == EINTR {
                            continue
                        } else {
                            break
                        }
                    }

                    let reqLine = String(decoding: lineBytes, as: UTF8.self)
                    let payload = payloadBuilder(reqLine)
                    var offset = 0
                    while offset < payload.count {
                        let written = payload.withUnsafeBytes { raw in
                            Darwin.write(client, raw.baseAddress!.advanced(by: offset), payload.count - offset)
                        }
                        if written > 0 {
                            offset += written
                        } else if written < 0 && errno == EINTR {
                            continue
                        } else {
                            break
                        }
                    }
                    _ = Darwin.shutdown(client, SHUT_WR)
                    Darwin.close(client)
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

private final class LoopbackSinkServer: @unchecked Sendable {
    private let listenFD: Int32
    let port: UInt16
    private let lock = NSLock()
    private var stopped = false
    private var payloads: [Data] = []
    private let expectedConnections: Int
    private let allDone = DispatchSemaphore(value: 0)
    private var completedConnections = 0

    init(expectedConnections: Int) throws {
        self.expectedConnections = expectedConnections
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
        guard rc == 0, Darwin.listen(sockFD, 64) == 0 else {
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
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

                DispatchQueue.global().async { [weak self] in
                    defer { Darwin.close(client) }
                    var received = Data()
                    var buf = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let n = buf.withUnsafeMutableBufferPointer { bp in
                            Darwin.read(client, bp.baseAddress, bp.count)
                        }
                        if n > 0 {
                            received.append(contentsOf: buf[0..<n])
                        } else if n == 0 {
                            break
                        } else if errno == EINTR {
                            continue
                        } else {
                            break
                        }
                    }
                    guard let self else { return }
                    self.lock.lock()
                    self.payloads.append(received)
                    self.completedConnections += 1
                    let reachedTarget = self.completedConnections == self.expectedConnections
                    self.lock.unlock()
                    if reachedTarget {
                        self.allDone.signal()
                    }
                }
            }
        }
    }

    func waitForAll(timeout: TimeInterval) -> Bool {
        allDone.wait(timeout: .now() + timeout) == .success
    }

    func snapshotPayloads() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return payloads
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        Darwin.close(listenFD)
    }
}

private final class LoopbackLargeWriteAndCloseServer: @unchecked Sendable {
    private let listenFD: Int32
    let port: UInt16
    private let lock = NSLock()
    private var stopped = false

    init(totalBytes: Int, chunk: [UInt8]) throws {
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
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                var sndTv = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sndTv, socklen_t(MemoryLayout<timeval>.size))

                DispatchQueue.global().async {
                    defer { Darwin.close(client) }
                    var buf = [UInt8](repeating: 0, count: 64)
                    while true {
                        let n = buf.withUnsafeMutableBufferPointer { Darwin.read(client, $0.baseAddress, $0.count) }
                        if n <= 0 {
                            if n < 0 && errno == EINTR { continue }
                            break
                        }
                    }

                    var remaining = totalBytes
                    while remaining > 0 {
                        let toWrite = min(remaining, chunk.count)
                        var offset = 0
                        var writeFailed = false
                        while offset < toWrite {
                            let w = chunk.withUnsafeBytes { raw in
                                Darwin.write(client, raw.baseAddress!.advanced(by: offset), toWrite - offset)
                            }
                            if w > 0 {
                                offset += w
                            } else if w < 0 && errno == EINTR {
                                continue
                            } else {
                                writeFailed = true
                                break
                            }
                        }
                        if writeFailed { break }
                        remaining -= toWrite
                    }
                    _ = Darwin.shutdown(client, SHUT_WR)
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
