import XCTest
import Foundation
import Darwin
@testable import QingzhouGuardRelayCore

final class RelayDNSTests: XCTestCase {

    func testBuildQueryRejectsLongLabelsAndEmptyHost() {
        let label63 = String(repeating: "a", count: 63)
        XCTAssertNotNil(RelayDNS.buildQuery(host: "\(label63).example.com", id: 0x1234))

        let label64 = String(repeating: "a", count: 64)
        XCTAssertNil(RelayDNS.buildQuery(host: "\(label64).example.com", id: 0x1234))

        XCTAssertNil(RelayDNS.buildQuery(host: "", id: 1))
        XCTAssertNil(RelayDNS.buildQuery(host: "a..b.com", id: 1))

        let tooLongHost = Array(repeating: String(repeating: "b", count: 50), count: 6).joined(separator: ".")
        XCTAssertNil(RelayDNS.buildQuery(host: tooLongHost, id: 1))
    }

    func testParseResponseValidatesTXIDQRAndRCODE() {
        let valid = makeDNSResponse(txid: 0xABCD, isResponse: true, rcode: 0, ip: [1, 2, 3, 4])
        XCTAssertEqual(RelayDNS.parseResponse(valid, expectedID: 0xABCD), "1.2.3.4")

        // TXID 不匹配
        XCTAssertNil(RelayDNS.parseResponse(valid, expectedID: 0xABCE))

        // QR=0（请求报文伪装响应）
        let notResponse = makeDNSResponse(txid: 0xABCD, isResponse: false, rcode: 0, ip: [1, 2, 3, 4])
        XCTAssertNil(RelayDNS.parseResponse(notResponse, expectedID: 0xABCD))

        // RCODE != 0（NXDOMAIN）
        let nxdomain = makeDNSResponse(txid: 0xABCD, isResponse: true, rcode: 3, ip: [1, 2, 3, 4])
        XCTAssertNil(RelayDNS.parseResponse(nxdomain, expectedID: 0xABCD))

        // QDCOUNT > 16（显式拒绝而非静默截断）
        var tooManyQuestions = [UInt8](valid)
        tooManyQuestions[4] = 0x00
        tooManyQuestions[5] = 0x11 // 17
        XCTAssertNil(RelayDNS.parseResponse(Data(tooManyQuestions), expectedID: 0xABCD))
    }

    func testBoundedCacheEvictionSweepsExpiredThenOldest() {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            var now = Date(timeIntervalSince1970: 1_000)
            func get() -> Date { lock.lock(); defer { lock.unlock() }; return now }
            func advance(_ sec: TimeInterval) { lock.lock(); now = now.addingTimeInterval(sec); lock.unlock() }
        }
        let clock = Clock()
        let dns = RelayDNS(servers: [], ttl: 60, maxEntries: 3, nowProvider: { clock.get() })

        dns.storeCachedIP("1.1.1.1", for: "a.example")
        clock.advance(1)
        dns.storeCachedIP("2.2.2.2", for: "b.example")
        clock.advance(1)
        dns.storeCachedIP("3.3.3.3", for: "c.example")
        XCTAssertEqual(dns.cacheCount, 3)

        // 插入第 4 条（未过期）：淘汰最早的 a.example
        clock.advance(1)
        dns.storeCachedIP("4.4.4.4", for: "d.example")
        XCTAssertEqual(dns.cacheCount, 3)
        XCTAssertNil(dns.cachedIP(for: "a.example"))
        XCTAssertEqual(dns.cachedIP(for: "b.example"), "2.2.2.2")
        XCTAssertEqual(dns.cachedIP(for: "d.example"), "4.4.4.4")

        // 前进超过 TTL 让 b/c/d 全部过期，再新增两条，应先清理过期条目
        clock.advance(70)
        dns.storeCachedIP("5.5.5.5", for: "e.example")
        XCTAssertLessThanOrEqual(dns.cacheCount, 3)
        XCTAssertEqual(dns.cachedIP(for: "e.example"), "5.5.5.5")
        XCTAssertNil(dns.cachedIP(for: "b.example"))
    }

    func testCacheLookupAndStoreAreCaseInsensitive() {
        let dns = RelayDNS(servers: [], ttl: 60, maxEntries: 8)
        dns.storeCachedIP("1.2.3.4", for: "Example.COM")
        XCTAssertEqual(dns.cachedIP(for: "example.com"), "1.2.3.4")
        XCTAssertEqual(dns.cachedIP(for: "EXAMPLE.COM"), "1.2.3.4")
        dns.storeCachedIP("5.6.7.8", for: "example.com")
        XCTAssertEqual(dns.cacheCount, 1)
        XCTAssertEqual(dns.cachedIP(for: "Example.Com"), "5.6.7.8")
    }

    func testLoopbackUDPRejectsMismatchedTXIDAndAcceptsValidTXID() throws {
        // 先起一个返回错误 TXID 的本地 UDP 桩，再起一个返回正确 TXID 的本地 UDP 桩
        let badServer = try LoopbackUDPStub { query in
            guard query.count >= 12 else { return nil }
            let qID = UInt16(query[0]) << 8 | UInt16(query[1])
            return Self.makeDNSResponseStatic(txid: qID ^ 0x00FF, isResponse: true, rcode: 0, ip: [9, 9, 9, 9])
        }
        defer { badServer.close() }

        let goodServer = try LoopbackUDPStub { query in
            guard query.count >= 12 else { return nil }
            let qID = UInt16(query[0]) << 8 | UInt16(query[1])
            return Self.makeDNSResponseStatic(txid: qID, isResponse: true, rcode: 0, ip: [93, 184, 216, 34])
        }
        defer { goodServer.close() }

        // 仅配 badServer：应拒绝错误 TXID 返回 nil
        let dnsBadOnly = RelayDNS(
            servers: [RelayDNS.Server(host: "127.0.0.1", port: badServer.port)],
            timeoutSeconds: 1
        )
        XCTAssertNil(dnsBadOnly.resolveSync("example.com", interface: nil))

        // 先 badServer 再 goodServer：跳过 badServer 并采用 goodServer 的有效响应
        let dnsFallback = RelayDNS(
            servers: [
                RelayDNS.Server(host: "127.0.0.1", port: badServer.port),
                RelayDNS.Server(host: "127.0.0.1", port: goodServer.port)
            ],
            timeoutSeconds: 1
        )
        let exp = expectation(description: "async dns resolves")
        let callbackQ = DispatchQueue(label: "test.dns.callback")
        nonisolated(unsafe) var resolved: String?
        dnsFallback.resolveAsync("example.com", interface: nil, callbackQueue: callbackQ) { ip in
            dispatchPrecondition(condition: .onQueue(callbackQ))
            resolved = ip
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3.0)
        XCTAssertEqual(resolved, "93.184.216.34")
    }

    func testLoopbackUDPOnSinglePortDiscardsWrongTXIDAndQREchoBeforeValidResponse() throws {
        let server = try LoopbackUDPStub(multiHandler: { query, sendPacket in
            guard query.count >= 12 else { return }
            let qID = UInt16(query[0]) << 8 | UInt16(query[1])
            // 1. 先发送错误 TXID 报文
            sendPacket(Self.makeDNSResponseStatic(txid: qID ^ 0xFFFF, isResponse: true, rcode: 0, ip: [9, 9, 9, 9]))
            // 2. 再发送 QR=0 的回显报文
            sendPacket(Self.makeDNSResponseStatic(txid: qID, isResponse: false, rcode: 0, ip: [8, 8, 8, 8]))
            // 3. 2 ms 后发送合法 TXID 且 QR=1 的真实响应 1.2.3.4
            Thread.sleep(forTimeInterval: 0.002)
            sendPacket(Self.makeDNSResponseStatic(txid: qID, isResponse: true, rcode: 0, ip: [1, 2, 3, 4]))
        })
        defer { server.close() }

        let dns = RelayDNS(
            servers: [RelayDNS.Server(host: "127.0.0.1", port: server.port)],
            timeoutSeconds: 2
        )
        XCTAssertEqual(dns.resolveSync("example.com", interface: nil), "1.2.3.4")
    }

    func testLoopbackUDPReturnsImmediatelyOnNXDOMAINAndNODATAWithoutWaitingTimeout() throws {
        // 1. NXDOMAIN (RCODE=3, ANCOUNT=0) across 2 servers with timeoutSeconds=3 -> < 1.0s
        let nxServer1 = try LoopbackUDPStub { query in
            guard query.count >= 12 else { return nil }
            let qID = UInt16(query[0]) << 8 | UInt16(query[1])
            return Self.makeNegativeDNSResponse(txid: qID, rcode: 3)
        }
        defer { nxServer1.close() }
        let nxServer2 = try LoopbackUDPStub { query in
            guard query.count >= 12 else { return nil }
            let qID = UInt16(query[0]) << 8 | UInt16(query[1])
            return Self.makeNegativeDNSResponse(txid: qID, rcode: 3)
        }
        defer { nxServer2.close() }

        let nxDNS = RelayDNS(
            servers: [
                RelayDNS.Server(host: "127.0.0.1", port: nxServer1.port),
                RelayDNS.Server(host: "127.0.0.1", port: nxServer2.port)
            ],
            timeoutSeconds: 3
        )
        let nxStart = Date()
        XCTAssertNil(nxDNS.resolveSync("nxdomain.example", interface: nil))
        let nxElapsed = Date().timeIntervalSince(nxStart)
        XCTAssertLessThan(nxElapsed, 1.0, "NXDOMAIN stalled for \(nxElapsed)s instead of returning immediately")

        // 2. NODATA: server 1 returns ANCOUNT=0 (RCODE=0), server 2 returns AAAA-only (RCODE=0, ANCOUNT=1, no A)
        let nodataEmpty = try LoopbackUDPStub { query in
            guard query.count >= 12 else { return nil }
            let qID = UInt16(query[0]) << 8 | UInt16(query[1])
            return Self.makeNegativeDNSResponse(txid: qID, rcode: 0)
        }
        defer { nodataEmpty.close() }
        let nodataAAAA = try LoopbackUDPStub { query in
            guard query.count >= 12 else { return nil }
            let qID = UInt16(query[0]) << 8 | UInt16(query[1])
            return Self.makeAAAAOnlyDNSResponse(txid: qID)
        }
        defer { nodataAAAA.close() }

        let nodataDNS = RelayDNS(
            servers: [
                RelayDNS.Server(host: "127.0.0.1", port: nodataEmpty.port),
                RelayDNS.Server(host: "127.0.0.1", port: nodataAAAA.port)
            ],
            timeoutSeconds: 3
        )
        let nodataStart = Date()
        XCTAssertNil(nodataDNS.resolveSync("nodata.example", interface: nil))
        let nodataElapsed = Date().timeIntervalSince(nodataStart)
        XCTAssertLessThan(nodataElapsed, 1.0, "NODATA stalled for \(nodataElapsed)s instead of returning immediately")
    }

    func testLoopbackUDPFallsBackImmediatelyOnSERVFAILToSecondaryServer() throws {
        let servfailServer = try LoopbackUDPStub { query in
            guard query.count >= 12 else { return nil }
            let qID = UInt16(query[0]) << 8 | UInt16(query[1])
            return Self.makeNegativeDNSResponse(txid: qID, rcode: 2) // SERVFAIL
        }
        defer { servfailServer.close() }

        let goodServer = try LoopbackUDPStub { query in
            guard query.count >= 12 else { return nil }
            let qID = UInt16(query[0]) << 8 | UInt16(query[1])
            return Self.makeDNSResponseStatic(txid: qID, isResponse: true, rcode: 0, ip: [1, 2, 3, 4])
        }
        defer { goodServer.close() }

        let dns = RelayDNS(
            servers: [
                RelayDNS.Server(host: "127.0.0.1", port: servfailServer.port),
                RelayDNS.Server(host: "127.0.0.1", port: goodServer.port)
            ],
            timeoutSeconds: 3
        )
        let start = Date()
        XCTAssertEqual(dns.resolveSync("example.com", interface: nil), "1.2.3.4")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0, "SERVFAIL fallback stalled for \(elapsed)s")
    }

    func testSinglePortDiscardsTruncatedPacketBeforeValidResponse() throws {
        // Direct unit check on parseResponseOutcome for truncated vs valid/negative
        let fullValid = Self.makeDNSResponseStatic(txid: 0x2222, isResponse: true, rcode: 0, ip: [1, 2, 3, 4])
        let truncatedQuestion = fullValid.prefix(16) // matching TXID & QR=1, truncated inside Question
        let truncatedAnswer = fullValid.prefix(fullValid.count - 2) // matching TXID & QR=1, truncated inside Answer RDATA
        XCTAssertEqual(RelayDNS.parseResponseOutcome(Data(truncatedQuestion), expectedID: 0x2222), .ignore)
        XCTAssertEqual(RelayDNS.parseResponseOutcome(Data(truncatedAnswer), expectedID: 0x2222), .ignore)
        XCTAssertEqual(RelayDNS.parseResponseOutcome(Self.makeNegativeDNSResponse(txid: 0x2222, rcode: 3), expectedID: 0x2222), .negative(rcode: 3))
        XCTAssertEqual(RelayDNS.parseResponseOutcome(fullValid, expectedID: 0x2222), .address("1.2.3.4"))

        // Header-only 12-byte SERVFAIL with QDCOUNT=0 is valid negative; QDCOUNT=1 with 12 bytes is truncated (.ignore)
        let headerOnlyServfail = Data([0x22, 0x22, 0x81, 0x82, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(RelayDNS.parseResponseOutcome(headerOnlyServfail, expectedID: 0x2222), .negative(rcode: 2))
        let headerTruncatedQuestion = Data([0x22, 0x22, 0x81, 0x82, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(RelayDNS.parseResponseOutcome(headerTruncatedQuestion, expectedID: 0x2222), .ignore)

        let server = try LoopbackUDPStub(multiHandler: { query, sendPacket in
            guard query.count >= 12 else { return }
            let qID = UInt16(query[0]) << 8 | UInt16(query[1])
            let valid = Self.makeDNSResponseStatic(txid: qID, isResponse: true, rcode: 0, ip: [1, 2, 3, 4])
            // 1. Truncated Question with matching TXID & QR=1 -> must be ignored
            sendPacket(Data(valid.prefix(16)))
            // 2. Truncated Answer with matching TXID & QR=1 -> must be ignored
            sendPacket(Data(valid.prefix(valid.count - 2)))
            // 3. 2 ms later send valid A response
            Thread.sleep(forTimeInterval: 0.002)
            sendPacket(valid)
        })
        defer { server.close() }

        let dns = RelayDNS(
            servers: [RelayDNS.Server(host: "127.0.0.1", port: server.port)],
            timeoutSeconds: 2
        )
        XCTAssertEqual(dns.resolveSync("example.com", interface: nil), "1.2.3.4")
    }

    private static func makeNegativeDNSResponse(txid: UInt16, rcode: UInt8) -> Data {
        var d = Data()
        d.append(contentsOf: [
            UInt8(txid >> 8), UInt8(txid & 0xFF),
            0x81, 0x80 | (rcode & 0x0F),
            0x00, 0x01, // QDCOUNT=1
            0x00, 0x00, // ANCOUNT=0
            0x00, 0x00,
            0x00, 0x00
        ])
        d.append(contentsOf: [7])
        d.append(contentsOf: "example".utf8)
        d.append(contentsOf: [3])
        d.append(contentsOf: "com".utf8)
        d.append(contentsOf: [0, 0, 1, 0, 1])
        return d
    }

    private static func makeAAAAOnlyDNSResponse(txid: UInt16) -> Data {
        var d = Data()
        d.append(contentsOf: [
            UInt8(txid >> 8), UInt8(txid & 0xFF),
            0x81, 0x80,
            0x00, 0x01, // QDCOUNT=1
            0x00, 0x01, // ANCOUNT=1
            0x00, 0x00,
            0x00, 0x00
        ])
        d.append(contentsOf: [7])
        d.append(contentsOf: "example".utf8)
        d.append(contentsOf: [3])
        d.append(contentsOf: "com".utf8)
        d.append(contentsOf: [0, 0, 1, 0, 1])
        // Answer: pointer to offset 12, TYPE AAAA (28), CLASS IN (1), TTL 60, RDLEN 16
        d.append(contentsOf: [0xC0, 0x0C, 0x00, 0x1C, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x10])
        d.append(contentsOf: [0x20, 0x01, 0x0d, 0xb8] + Array(repeating: UInt8(0), count: 12))
        return d
    }

    private func makeDNSResponse(txid: UInt16, isResponse: Bool, rcode: UInt8, ip: [UInt8]) -> Data {
        Self.makeDNSResponseStatic(txid: txid, isResponse: isResponse, rcode: rcode, ip: ip)
    }

    private static func makeDNSResponseStatic(txid: UInt16, isResponse: Bool, rcode: UInt8, ip: [UInt8]) -> Data {
        var d = Data()
        let f1: UInt8 = isResponse ? 0x81 : 0x01
        let f2: UInt8 = 0x80 | (rcode & 0x0F)
        d.append(contentsOf: [
            UInt8(txid >> 8), UInt8(txid & 0xFF),
            f1, f2,
            0x00, 0x01, // QDCOUNT=1
            0x00, 0x01, // ANCOUNT=1
            0x00, 0x00,
            0x00, 0x00
        ])
        // Question: example.com A IN
        d.append(contentsOf: [7])
        d.append(contentsOf: "example".utf8)
        d.append(contentsOf: [3])
        d.append(contentsOf: "com".utf8)
        d.append(contentsOf: [0, 0, 1, 0, 1])
        // Answer: pointer to offset 12 (0xC0 0x0C), TYPE A, CLASS IN, TTL 60, RDLEN 4
        d.append(contentsOf: [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04])
        d.append(contentsOf: ip)
        return d
    }
}

private final class LoopbackUDPStub: @unchecked Sendable {
    private let fd: Int32
    let port: UInt16
    private let queue = DispatchQueue(label: "test.udp.stub")
    private let lock = NSLock()
    private var stopped = false

    convenience init(handler: @escaping @Sendable (Data) -> Data?) throws {
        try self.init(multiHandler: { query, sendPacket in
            if let resp = handler(query) {
                sendPacket(resp)
            }
        })
    }

    init(multiHandler: @escaping @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void) throws {
        let sockFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard sockFD >= 0 else { throw URLError(.cannotOpenFile) }
        self.fd = sockFD

        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(sockFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                Darwin.bind(sockFD, sap, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(sockFD)
            throw URLError(.cannotOpenFile)
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                getsockname(sockFD, sap, &len)
            }
        }
        self.port = UInt16(bigEndian: boundAddr.sin_port)

        let sock = sockFD
        queue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 1500)
            while true {
                guard let self else { break }
                self.lock.lock()
                let isStopped = self.stopped
                self.lock.unlock()
                if isStopped { break }

                var peer = sockaddr_storage()
                var peerLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = withUnsafeMutablePointer(to: &peer) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                        buf.withUnsafeMutableBufferPointer { bp in
                            recvfrom(sock, bp.baseAddress, bp.count, 0, sap, &peerLen)
                        }
                    }
                }
                if n > 0 {
                    let query = Data(buf[0..<n])
                    let peerCopy = peer
                    let peerLenCopy = peerLen
                    multiHandler(query) { resp in
                        var targetPeer = peerCopy
                        _ = resp.withUnsafeBytes { raw in
                            withUnsafePointer(to: &targetPeer) { p in
                                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                                    sendto(sock, raw.baseAddress, raw.count, 0, sap, peerLenCopy)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func close() {
        lock.lock()
        stopped = true
        lock.unlock()
        Darwin.close(fd)
    }
}
