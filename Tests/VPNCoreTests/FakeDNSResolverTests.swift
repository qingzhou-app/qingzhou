import XCTest
@testable import VPNCore

final class FakeDNSResolverTests: XCTestCase {

    // header: id, flags(0x8180 响应), qd=1, an=..., ns=0, ar=0
    private func header(answers: Int) -> [UInt8] {
        [0x12, 0x34, 0x81, 0x80, 0x00, 0x01,
         UInt8(answers >> 8), UInt8(answers & 0xFF), 0x00, 0x00, 0x00, 0x00]
    }
    // qname www.google.com + qtype A + qclass IN
    private let question: [UInt8] = [
        3,119,119,119, 6,103,111,111,103,108,101, 3,99,111,109, 0,
        0x00,0x01, 0x00,0x01
    ]
    // 一条 A 记录 answer（name 用压缩指针指向 qname）
    private func aRecord(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> [UInt8] {
        [0xC0,0x0C, 0x00,0x01, 0x00,0x01, 0x00,0x00,0x01,0x2C, 0x00,0x04, a,b,c,d]
    }

    func testParsesSingleARecord() {
        let bytes = header(answers: 1) + question + aRecord(198,18,11,144)
        let r = FakeDNSResolver.parseResponse(bytes)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.ip, "198.18.11.144")
        XCTAssertEqual(r.first?.domain, "www.google.com")
    }

    func testParsesMultipleARecords() {
        let bytes = header(answers: 2) + question + aRecord(198,18,0,1) + aRecord(198,18,0,2)
        let r = FakeDNSResolver.parseResponse(bytes)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(Set(r.map(\.ip)), ["198.18.0.1", "198.18.0.2"])
        XCTAssertTrue(r.allSatisfy { $0.domain == "www.google.com" })
    }

    func testSkipsNonARecord() {
        // 一条 CNAME（type 5, rdlength 2）应被跳过，不产出 IP
        let cname: [UInt8] = [0xC0,0x0C, 0x00,0x05, 0x00,0x01, 0x00,0x00,0x01,0x2C, 0x00,0x02, 0xC0,0x0C]
        let bytes = header(answers: 1) + question + cname
        XCTAssertTrue(FakeDNSResolver.parseResponse(bytes).isEmpty)
    }

    func testMalformedReturnsEmpty() {
        XCTAssertTrue(FakeDNSResolver.parseResponse([0x00, 0x01]).isEmpty)       // 太短
        XCTAssertTrue(FakeDNSResolver.parseResponse([]).isEmpty)
        XCTAssertTrue(FakeDNSResolver.parseResponse(header(answers: 0)).isEmpty) // 没 question
    }

    func testExtractsMappingFromFullIPPacket() {
        // IPv4 头(20)：0x45=IPv4/IHL5，protocol=17(UDP)，src IP 8.8.8.8
        let ip: [UInt8] = [0x45,0x00, 0x00,0x00, 0x00,0x00, 0x00,0x00, 0x40, 17, 0x00,0x00,
                           8,8,8,8, 10,0,10,1]
        let udp: [UInt8] = [0x00,0x35, 0xC0,0x00, 0x00,0x00, 0x00,0x00]  // 源端口 53
        let packet = ip + udp + header(answers: 1) + question + aRecord(198,18,11,144)
        let maps = FakeDNSResolver.mappingsFromIPPacket(packet)
        XCTAssertEqual(maps.first?.ip, "198.18.11.144")
        XCTAssertEqual(maps.first?.domain, "www.google.com")
        // 源端口不是 53（比如 443）→ 不是 DNS 响应，返回空
        var notDNS = packet; notDNS[20] = 0x01; notDNS[21] = 0xBB
        XCTAssertTrue(FakeDNSResolver.mappingsFromIPPacket(notDNS).isEmpty)
    }
}
