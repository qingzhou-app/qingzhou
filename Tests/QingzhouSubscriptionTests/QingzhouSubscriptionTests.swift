import XCTest
import QingzhouCore
@testable import QingzhouSubscription

final class QingzhouSubscriptionTests: XCTestCase {

    // MARK: - Userinfo header

    func testParseUserinfoHeaderFull() {
        let info = SubscriptionUserInfo.parse("upload=100; download=200; total=1000; expire=1730000000")
        XCTAssertEqual(info.upload, 100)
        XCTAssertEqual(info.download, 200)
        XCTAssertEqual(info.total, 1000)
        XCTAssertEqual(info.usedBytes, 300)
        XCTAssertEqual(info.expire, Date(timeIntervalSince1970: 1730000000))
    }

    func testParseUserinfoHeaderPartial() {
        let info = SubscriptionUserInfo.parse("upload=50, total=500")
        XCTAssertEqual(info.upload, 50)
        XCTAssertNil(info.download)
        XCTAssertEqual(info.total, 500)
        XCTAssertEqual(info.usedBytes, 50)
        XCTAssertNil(info.expire)
    }

    func testParseUserinfoHeaderIgnoresUnknown() {
        let info = SubscriptionUserInfo.parse("foo=bar; total=100; baz=qux")
        XCTAssertEqual(info.total, 100)
    }

    // MARK: - SubscriptionParser

    func testParsePlainLinks() {
        let body = """
        trojan://pw@a.com:443#A
        ss://YWVzLTEyOC1nY206cHc=@b.com:8388#B
        """
        let payload = SubscriptionParser.parse(body: body)
        XCTAssertEqual(payload.nodes.count, 2)
        XCTAssertEqual(payload.nodes[0].protocolType, .trojan)
        XCTAssertEqual(payload.nodes[1].protocolType, .shadowsocks)
    }

    func testParseBase64Encoded() {
        let inner = "trojan://pw@a.com:443#A\nhy2://pw@b.com:443#B"
        let b64 = Data(inner.utf8).base64EncodedString()
        let payload = SubscriptionParser.parse(body: b64)
        XCTAssertEqual(payload.nodes.count, 2)
    }

    func testParseBase64WithoutPadding() {
        // 模拟订阅源去掉 = padding
        let inner = "trojan://pw@a.com:443#A"
        var b64 = Data(inner.utf8).base64EncodedString()
        while b64.hasSuffix("=") { b64.removeLast() }
        let payload = SubscriptionParser.parse(body: b64)
        XCTAssertEqual(payload.nodes.count, 1)
    }

    func testParseWithUserinfoHeader() {
        let body = "trojan://pw@a.com:443#A"
        let payload = SubscriptionParser.parse(
            body: body,
            userInfoHeader: "upload=10; download=20; total=100"
        )
        XCTAssertEqual(payload.nodes.count, 1)
        XCTAssertEqual(payload.userInfo?.usedBytes, 30)
    }

    func testParseCollectsErrors() {
        let body = "trojan://pw@a.com:443#A\nblahblahblah"
        let payload = SubscriptionParser.parse(body: body)
        XCTAssertEqual(payload.nodes.count, 1)
        XCTAssertEqual(payload.failedLines.count, 1)
    }

    // MARK: - SIP008 JSON 订阅

    func testParseSIP008Standard() {
        let body = """
        {
          "version": 1,
          "servers": [
            {"id":"a","remarks":"香港01","server":"1.2.3.4","server_port":8388,"method":"aes-256-gcm","password":"pw1"},
            {"id":"b","remarks":"日本02","server":"5.6.7.8","server_port":443,"method":"chacha20-ietf-poly1305","password":"pw2"}
          ]
        }
        """
        let payload = SubscriptionParser.parse(body: body)
        XCTAssertEqual(payload.nodes.count, 2)
        XCTAssertTrue(payload.formatRecognized)
        XCTAssertTrue(payload.failedLines.isEmpty)

        let n0 = payload.nodes[0]
        XCTAssertEqual(n0.protocolType, .shadowsocks)
        XCTAssertEqual(n0.name, "香港01")
        XCTAssertEqual(n0.host, "1.2.3.4")
        XCTAssertEqual(n0.port, 8388)
        XCTAssertEqual(n0.cipher, "aes-256-gcm")
        XCTAssertEqual(n0.password, "pw1")

        XCTAssertEqual(payload.nodes[1].name, "日本02")
        XCTAssertEqual(payload.nodes[1].port, 443)
    }

    func testParseSIP008MissingFieldsAreToleratedPerServer() {
        // 第二个 server 缺 method、第三个缺 server → 都进 failedLines，好的照收
        let body = """
        {
          "servers": [
            {"remarks":"好节点","server":"1.2.3.4","server_port":8388,"method":"aes-256-gcm","password":"pw"},
            {"remarks":"缺method","server":"5.6.7.8","server_port":8388,"password":"pw"},
            {"remarks":"缺server","server_port":8388,"method":"aes-256-gcm","password":"pw"}
          ]
        }
        """
        let payload = SubscriptionParser.parse(body: body)
        XCTAssertEqual(payload.nodes.count, 1)
        XCTAssertEqual(payload.nodes[0].name, "好节点")
        XCTAssertEqual(payload.failedLines.count, 2)
        XCTAssertTrue(payload.formatRecognized)
    }

    func testParseSIP008EmptyServersIsRecognizedButEmpty() {
        let body = #"{"version":1,"servers":[]}"#
        let payload = SubscriptionParser.parse(body: body)
        XCTAssertTrue(payload.nodes.isEmpty)
        XCTAssertTrue(payload.formatRecognized, "空 servers 是已识别但为空，不该判成格式无法识别")
    }

    func testParseSIP008WithPluginPassthrough() {
        let body = """
        {
          "servers": [
            {"remarks":"带插件","server":"1.2.3.4","server_port":8388,"method":"aes-256-gcm","password":"pw",
             "plugin":"obfs-local","plugin_opts":"obfs=http;obfs-host=www.bing.com"}
          ]
        }
        """
        let payload = SubscriptionParser.parse(body: body)
        XCTAssertEqual(payload.nodes.count, 1)
        XCTAssertEqual(payload.nodes[0].parameters["plugin"], "obfs-local")
        XCTAssertEqual(payload.nodes[0].parameters["plugin-opts"], "obfs=http;obfs-host=www.bing.com")
    }

    func testParseSIP008RemarksFallbackAndTagAlias() {
        // 无 remarks 退化成 host:port；tag 作为 remarks 的别名
        let body = """
        {
          "servers": [
            {"server":"1.2.3.4","server_port":8388,"method":"aes-256-gcm","password":"pw"},
            {"tag":"用tag命名","server":"5.6.7.8","server_port":9999,"method":"aes-256-gcm","password":"pw"}
          ]
        }
        """
        let payload = SubscriptionParser.parse(body: body)
        XCTAssertEqual(payload.nodes.count, 2)
        XCTAssertEqual(payload.nodes[0].name, "1.2.3.4:8388")
        XCTAssertEqual(payload.nodes[1].name, "用tag命名")
    }

    func testParseSIP008PortAsStringAccepted() {
        // 个别机场把 server_port 给成字符串
        let body = #"{"servers":[{"remarks":"x","server":"1.2.3.4","server_port":"8388","method":"aes-256-gcm","password":"pw"}]}"#
        let payload = SubscriptionParser.parse(body: body)
        XCTAssertEqual(payload.nodes.count, 1)
        XCTAssertEqual(payload.nodes[0].port, 8388)
    }

    // MARK: - 零节点：格式已识别 vs 无法识别

    func testFormatRecognizedForPlainLinks() {
        let payload = SubscriptionParser.parse(body: "trojan://pw@a.com:443#A")
        XCTAssertTrue(payload.formatRecognized)
    }

    func testFormatRecognizedForBase64() {
        let b64 = Data("trojan://pw@a.com:443#A".utf8).base64EncodedString()
        let payload = SubscriptionParser.parse(body: b64)
        XCTAssertTrue(payload.formatRecognized)
    }

    func testUnrecognizedGarbageBody() {
        // 乱码、没有任何已知格式特征、不含 ://
        let payload = SubscriptionParser.parse(body: "这是一段随便乱写的东西 not a subscription at all")
        XCTAssertTrue(payload.nodes.isEmpty)
        XCTAssertFalse(payload.formatRecognized, "无法识别的格式应标记 formatRecognized=false")
    }

    func testUnrecognizedHTMLLoginPage() {
        // 订阅链接填错/过期常返回 HTML 页面
        let payload = SubscriptionParser.parse(body: "<html><body>Please login</body></html>")
        XCTAssertTrue(payload.nodes.isEmpty)
        XCTAssertFalse(payload.formatRecognized)
    }

    func testLinkListWithOnlyBadLinksStillRecognized() {
        // 含 :// 就算是链接列表（只是链接坏了），算已识别，不该报「格式无法识别」
        let payload = SubscriptionParser.parse(body: "ssd://somethingunsupported")
        XCTAssertTrue(payload.nodes.isEmpty)
        XCTAssertTrue(payload.formatRecognized)
        XCTAssertFalse(payload.failedLines.isEmpty)
    }

    // MARK: - SubscriptionFetcher with mock HTTPClient

    struct MockHTTPClient: HTTPClient {
        let body: String
        let headers: [String: String]
        func get(_ url: URL) async throws -> (Data, [String: String]) {
            (Data(body.utf8), headers)
        }
    }

    func testFetcherUpdatesSubscriptionMeta() async throws {
        let body = "trojan://pw@a.com:443#A\ntrojan://pw@b.com:443#B"
        let client = MockHTTPClient(
            body: body,
            headers: ["subscription-userinfo": "upload=1; download=2; total=100; expire=1730000000"]
        )
        let fetcher = SubscriptionFetcher(client: client)
        let sub = Subscription(name: "S", url: URL(string: "https://example.com/sub")!)
        let (updated, payload) = try await fetcher.refresh(sub)
        XCTAssertEqual(updated.nodeCount, 2)
        XCTAssertNotNil(updated.lastUpdatedAt)
        XCTAssertEqual(updated.usedBytes, 3)
        XCTAssertEqual(updated.totalBytes, 100)
        XCTAssertEqual(payload.nodes.count, 2)
        // 节点应该被打上订阅 id
        XCTAssertEqual(payload.nodes[0].subscriptionId, updated.id)
        XCTAssertEqual(payload.nodes[1].subscriptionId, updated.id)
    }
}
