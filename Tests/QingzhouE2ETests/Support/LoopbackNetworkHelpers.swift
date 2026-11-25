import Foundation
import Darwin

enum LoopbackSocketError: Error, Equatable {
    case socketFailed
    case bindFailed
    case listenFailed
    case connectFailed
    case ioFailed
    case unexpectedEOF
    case invalidProtocolData
}

final class LoopbackTCPEchoServer: @unchecked Sendable {
    private let listenFD: Int32
    let port: UInt16
    private let lock = NSLock()
    private var stopped = false
    private var activeFDs: Set<Int32> = []

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LoopbackSocketError.socketFailed }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                Darwin.bind(fd, sap, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0, Darwin.listen(fd, 32) == 0 else {
            Darwin.close(fd)
            throw LoopbackSocketError.listenFailed
        }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                getsockname(fd, sap, &len)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                guard let self else { break }
                self.lock.lock()
                let isStopped = self.stopped
                self.lock.unlock()
                if isStopped { break }

                let client = Darwin.accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR {
                        self.lock.lock()
                        let isStopped = self.stopped
                        self.lock.unlock()
                        if !isStopped { continue }
                    }
                    break
                }
                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                self.lock.lock()
                if self.stopped {
                    self.lock.unlock()
                    Darwin.close(client)
                    break
                }
                self.activeFDs.insert(client)
                self.lock.unlock()

                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    defer {
                        var shouldClose = false
                        if let self {
                            self.lock.lock()
                            shouldClose = self.activeFDs.remove(client) != nil
                            self.lock.unlock()
                        }
                        if shouldClose {
                            Darwin.close(client)
                        }
                    }
                    var buf = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let n = buf.withUnsafeMutableBufferPointer { ptr in
                            Darwin.read(client, ptr.baseAddress, ptr.count)
                        }
                        if n == 0 {
                            Darwin.shutdown(client, SHUT_WR)
                            break
                        }
                        if n < 0 {
                            if errno == EINTR { continue }
                            break
                        }
                        var sent = 0
                        while sent < n {
                            let w = buf.withUnsafeBytes { raw in
                                Darwin.write(client, raw.baseAddress!.advanced(by: sent), n - sent)
                            }
                            if w > 0 {
                                sent += w
                            } else if w < 0 && errno == EINTR {
                                continue
                            } else {
                                return
                            }
                        }
                    }
                }
            }
        }
    }

    func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        let fds = activeFDs
        activeFDs.removeAll()
        lock.unlock()
        if !already {
            Darwin.close(listenFD)
        }
        for fd in fds {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    deinit {
        stop()
    }
}

final class LoopbackTCPFaultServer: @unchecked Sendable {
    private let listenFD: Int32
    let port: UInt16
    private let lock = NSLock()
    private var stopped = false

    init(handler: @escaping @Sendable (Int32) -> Void) throws {
        let sockFD = socket(AF_INET, SOCK_STREAM, 0)
        guard sockFD >= 0 else { throw LoopbackSocketError.socketFailed }
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
            throw LoopbackSocketError.listenFailed
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                getsockname(sockFD, sap, &len)
            }
        }
        self.port = UInt16(bigEndian: bound.sin_port)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                guard let self else { break }
                self.lock.lock()
                let done = self.stopped
                self.lock.unlock()
                if done { break }
                let client = Darwin.accept(sockFD, nil, nil)
                if client < 0 {
                    if errno == EINTR {
                        self.lock.lock()
                        let isStopped = self.stopped
                        self.lock.unlock()
                        if !isStopped { continue }
                    }
                    break
                }
                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                self.lock.lock()
                let stoppedNow = self.stopped
                self.lock.unlock()
                if stoppedNow {
                    Darwin.close(client)
                    break
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { Darwin.close(client) }
                    handler(client)
                }
            }
        }
    }

    func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        lock.unlock()
        if !already {
            Darwin.close(listenFD)
        }
    }

    deinit {
        stop()
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

final class LoopbackUDPStubDNS: @unchecked Sendable {
    private let fd: Int32
    let port: UInt16
    private let lock = NSLock()
    private var stopped = false
    private var _receivedCount = 0

    var receivedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _receivedCount
    }

    /// `responder` takes `(requestData, txid)` and returns ordered UDP datagrams to send back.
    init(responder: @escaping @Sendable (Data, UInt16) -> [Data]) throws {
        let sockFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard sockFD >= 0 else { throw LoopbackSocketError.socketFailed }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                Darwin.bind(sockFD, sap, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            Darwin.close(sockFD)
            throw LoopbackSocketError.bindFailed
        }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                getsockname(sockFD, sap, &len)
            }
        }
        self.fd = sockFD
        self.port = UInt16(bigEndian: bound.sin_port)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 1500)
            while true {
                guard let self else { break }
                self.lock.lock()
                let done = self.stopped
                self.lock.unlock()
                if done { break }

                var peer = sockaddr_storage()
                var peerLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = withUnsafeMutablePointer(to: &peer) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                        buf.withUnsafeMutableBufferPointer { bptr in
                            recvfrom(sockFD, bptr.baseAddress, bptr.count, 0, sap, &peerLen)
                        }
                    }
                }
                if n <= 0 {
                    if errno == EINTR { continue }
                    break
                }
                self.lock.lock()
                self._receivedCount += 1
                self.lock.unlock()

                let req = Data(buf[0..<n])
                let txid: UInt16 = n >= 2 ? (UInt16(buf[0]) << 8 | UInt16(buf[1])) : 0
                let replies = responder(req, txid)
                for reply in replies {
                    _ = withUnsafePointer(to: &peer) { p in
                        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                            reply.withUnsafeBytes { raw in
                                sendto(sockFD, raw.baseAddress, raw.count, 0, sap, peerLen)
                            }
                        }
                    }
                }
            }
        }
    }

    func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        lock.unlock()
        if !already {
            Darwin.close(fd)
        }
    }

    deinit {
        stop()
    }

    static func buildAResponse(
        for query: Data,
        txid: UInt16,
        ipOctets: [UInt8],
        qr: Bool = true,
        rcode: UInt8 = 0
    ) -> Data {
        var out = Data()
        let flagsHi: UInt8 = (qr ? 0x80 : 0x00) | 0x01
        let flagsLo: UInt8 = 0x80 | (rcode & 0x0F)
        out.append(contentsOf: [
            UInt8(txid >> 8), UInt8(txid & 0xFF),
            flagsHi, flagsLo,
            0x00, 0x01, // QDCOUNT=1
            0x00, 0x01, // ANCOUNT=1
            0x00, 0x00,
            0x00, 0x00
        ])
        if query.count > 12 {
            out.append(query.dropFirst(12))
        }
        // Answer section using pointer 0xC0 0x0C
        out.append(contentsOf: [
            0xC0, 0x0C,
            0x00, 0x01, // TYPE A
            0x00, 0x01, // CLASS IN
            0x00, 0x00, 0x00, 0x3C, // TTL 60s
            0x00, 0x04
        ])
        out.append(contentsOf: ipOctets.prefix(4))
        return out
    }
}

enum LoopbackIO {
    static func connectLoopback(port: UInt16, timeoutSeconds: TimeInterval = 3) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LoopbackSocketError.socketFailed }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(
            tv_sec: Int(timeoutSeconds),
            tv_usec: Int32((timeoutSeconds - floor(timeoutSeconds)) * 1_000_000)
        )
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
            throw LoopbackSocketError.connectFailed
        }
        return fd
    }

    static func writeAll(_ fd: Int32, bytes: [UInt8]) throws {
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
                throw LoopbackSocketError.ioFailed
            }
        }
    }

    static func writeLine(_ fd: Int32, _ line: String) throws {
        try writeAll(fd, bytes: Array((line + "\n").utf8))
    }

    static func readExact(_ fd: Int32, count: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        var buf = [UInt8](repeating: 0, count: count)
        while out.count < count {
            let need = count - out.count
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(fd, ptr.baseAddress, need)
            }
            if n > 0 {
                out.append(contentsOf: buf[0..<n])
            } else if n == 0 {
                throw LoopbackSocketError.unexpectedEOF
            } else if errno == EINTR {
                continue
            } else {
                throw LoopbackSocketError.ioFailed
            }
        }
        return out
    }

    static func readLine(_ fd: Int32) throws -> String {
        var bytes: [UInt8] = []
        var b: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &b, 1)
            if n == 1 {
                if b == 0x0A { break }
                if b != 0x0D { bytes.append(b) }
            } else if n == 0 {
                if bytes.isEmpty { throw LoopbackSocketError.unexpectedEOF }
                break
            } else if errno == EINTR {
                continue
            } else {
                throw LoopbackSocketError.ioFailed
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func readAllUntilEOF(_ fd: Int32) throws -> [UInt8] {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                out.append(contentsOf: buf[0..<n])
            } else if n == 0 {
                return out
            } else if errno == EINTR {
                continue
            } else {
                throw LoopbackSocketError.ioFailed
            }
        }
    }

    /// Performs SOCKS5 greeting + username/password auth + request, returning `(authReply, connectReply)`.
    static func socks5Handshake(
        fd: Int32,
        user: String,
        pass: String,
        cmd: UInt8 = 0x01,
        targetHost: String,
        targetPort: UInt16
    ) throws -> (authStatus: UInt8, connectReply: UInt8) {
        // Greeting: version 5, 1 method: 0x02 (username/password)
        try writeAll(fd, bytes: [0x05, 0x01, 0x02])
        let greeting = try readExact(fd, count: 2)
        guard greeting == [0x05, 0x02] else {
            throw LoopbackSocketError.invalidProtocolData
        }

        // Auth: subver 0x01
        let uBytes = Array(user.utf8)
        let pBytes = Array(pass.utf8)
        var authReq: [UInt8] = [0x01, UInt8(uBytes.count)]
        authReq.append(contentsOf: uBytes)
        authReq.append(UInt8(pBytes.count))
        authReq.append(contentsOf: pBytes)
        try writeAll(fd, bytes: authReq)
        let authResp = try readExact(fd, count: 2)
        guard authResp.count == 2 else { throw LoopbackSocketError.invalidProtocolData }
        if authResp[1] != 0x00 {
            return (authResp[1], 0xFF)
        }

        // Request
        var req: [UInt8] = [0x05, cmd, 0x00]
        var v4 = in_addr()
        if inet_pton(AF_INET, targetHost, &v4) == 1 {
            req.append(0x01)
            withUnsafeBytes(of: &v4) { req.append(contentsOf: $0) }
        } else {
            let hostBytes = Array(targetHost.utf8)
            req.append(0x03)
            req.append(UInt8(hostBytes.count))
            req.append(contentsOf: hostBytes)
        }
        req.append(UInt8(targetPort >> 8))
        req.append(UInt8(targetPort & 0xFF))
        try writeAll(fd, bytes: req)

        let head = try readExact(fd, count: 4)
        let rep = head[1]
        let atyp = head[3]
        switch atyp {
        case 0x01:
            _ = try readExact(fd, count: 4 + 2)
        case 0x03:
            let len = try readExact(fd, count: 1)[0]
            _ = try readExact(fd, count: Int(len) + 2)
        case 0x04:
            _ = try readExact(fd, count: 16 + 2)
        default:
            throw LoopbackSocketError.invalidProtocolData
        }
        return (0x00, rep)
    }
}
