import XCTest
import QingzhouCore

/// 中继凭据在主 App 与隧道扩展之间的序列化契约。
///
/// 这条链路一旦解不出来，扩展会静默退化为"不经中继"，而用户以为在经中继出网 ——
/// 接着一开 pf 就整机断网。所以解码的严格性要测。
final class GuardRelayCredentialsTests: XCTestCase {

    func testRoundTrip() {
        let creds = GuardRelayCredentials(port: 10808, username: "u", password: "p")
        let json = creds.jsonString
        XCTAssertFalse(json.isEmpty)
        XCTAssertEqual(GuardRelayCredentials.decode(json), creds)
    }

    func testRejectsEmptyAndGarbage() {
        XCTAssertNil(GuardRelayCredentials.decode(""))
        XCTAssertNil(GuardRelayCredentials.decode("not json"))
        XCTAssertNil(GuardRelayCredentials.decode("{}"))
    }

    /// 空密码 / 0 端口都不算有效凭据（中继是强制认证的，空密码等于连不上）
    func testRejectsIncompleteCredentials() {
        XCTAssertNil(GuardRelayCredentials.decode(#"{"host":"127.0.0.1","port":10808,"username":"u","password":""}"#))
        XCTAssertNil(GuardRelayCredentials.decode(#"{"host":"127.0.0.1","port":0,"username":"u","password":"p"}"#))
    }
}
