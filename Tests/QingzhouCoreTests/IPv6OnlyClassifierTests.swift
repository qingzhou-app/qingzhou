import XCTest
@testable import QingzhouCore

/// IPv6OnlyClassifier：DoH dns-json 应答 → 「仅 IPv6」判定。
/// fixture 按 dns.google / AliDNS 的 /resolve JSON 真实结构构造。
final class IPv6OnlyClassifierTests: XCTestCase {

    private func doh(status: Int, answers: [(type: Int, data: String)] = []) -> Data {
        var obj: [String: Any] = ["Status": status]
        if !answers.isEmpty {
            obj["Answer"] = answers.map { ["name": "x.example.", "type": $0.type, "TTL": 60, "data": $0.data] }
        }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    func testDualStackAndV4OnlyAreHasIPv4() {
        // 双栈：A 有记录 → hasIPv4（不管 AAAA）
        XCTAssertEqual(IPv6OnlyClassifier.classify(
            aResponse: doh(status: 0, answers: [(1, "1.2.3.4")]),
            aaaaResponse: doh(status: 0, answers: [(28, "2001:db8::1")])), .hasIPv4)
        // 纯 IPv4：A 有、AAAA 空（NODATA）→ hasIPv4（cbs-u.sports.cctv.com 形态）
        XCTAssertEqual(IPv6OnlyClassifier.classify(
            aResponse: doh(status: 0, answers: [(1, "1.2.3.4")]),
            aaaaResponse: doh(status: 0)), .hasIPv4)
    }

    func testAAAAOnlyIsIPv6Only() {
        // 仅 IPv6：A NODATA + AAAA 有 → ipv6Only（thiswebsiteisipv6only.com 形态）
        XCTAssertEqual(IPv6OnlyClassifier.classify(
            aResponse: doh(status: 0),
            aaaaResponse: doh(status: 0, answers: [(28, "2a0d:f302::1")])), .ipv6Only)
    }

    func testCNAMEWithoutAddressDoesNotCountAsA() {
        // A 应答只有 CNAME（type=5）没有最终地址 → 不算有 A；AAAA 有 → ipv6Only
        XCTAssertEqual(IPv6OnlyClassifier.classify(
            aResponse: doh(status: 0, answers: [(5, "cdn.example.")]),
            aaaaResponse: doh(status: 0, answers: [(5, "cdn.example."), (28, "2001:db8::2")])), .ipv6Only)
    }

    func testNXDOMAINAndGarbageAreUnresolvable() {
        // NXDOMAIN（Status=3）→ 不是 IPv6 问题
        XCTAssertEqual(IPv6OnlyClassifier.classify(
            aResponse: doh(status: 3), aaaaResponse: doh(status: 3)), .unresolvable)
        // 应答不是合法 JSON → unresolvable，不崩
        XCTAssertEqual(IPv6OnlyClassifier.classify(
            aResponse: Data("not json".utf8), aaaaResponse: Data()), .unresolvable)
    }
}
