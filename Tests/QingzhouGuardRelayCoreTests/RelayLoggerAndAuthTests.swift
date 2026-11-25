import XCTest
import Foundation
@testable import QingzhouGuardRelayCore

final class RelayLoggerAndAuthTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-log-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testLogRotationPreserves0600PermissionsAndHandlesConcurrency() throws {
        let logURL = tempDir.appendingPathComponent("relay.log")
        let backupURL = tempDir.appendingPathComponent("relay.log.1")
        let logger = RelayLogger(logPath: logURL.path, maxBytes: 512)

        let group = DispatchGroup()
        for t in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<20 {
                    logger.log("worker=\(t) seq=\(i) payload=abcdefghij0123456789")
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)

        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        let mainAttrs = try FileManager.default.attributesOfItem(atPath: logURL.path)
        let backupAttrs = try FileManager.default.attributesOfItem(atPath: backupURL.path)
        XCTAssertEqual((mainAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((backupAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let mainSize = (mainAttrs[.size] as? NSNumber)?.uint64Value ?? 0
        XCTAssertLessThanOrEqual(mainSize, 512)
    }

    func testRelayAuthCredentialsSeparationAndFailClosed() {
        // 合法分离凭据
        let valid = """
        # comment
        forward:fwdUser:fwdPass:withColon
        control:ctrlUser:ctrlPass
        """
        let parsed = RelayAuthCredentials.parse(valid)
        XCTAssertEqual(parsed?.forwarding, CredentialPair(user: "fwdUser", pass: "fwdPass:withColon"))
        XCTAssertEqual(parsed?.control, CredentialPair(user: "ctrlUser", pass: "ctrlPass"))

        // 缺少控制凭据 → nil
        XCTAssertNil(RelayAuthCredentials.parse("forward:u:p\n"))
        // 缺少转发凭据 → nil
        XCTAssertNil(RelayAuthCredentials.parse("control:u:p\n"))
        // 旧版单行无前缀 → nil（fail closed）
        XCTAssertNil(RelayAuthCredentials.parse("legacyUser:legacyPass\n"))
        // 空密码 / 空用户名 → nil
        XCTAssertNil(RelayAuthCredentials.parse("forward:u:\ncontrol:cu:cp\n"))
        XCTAssertNil(RelayAuthCredentials.parse("forward:u:p\ncontrol::cp\n"))
        // 转发与控制凭据相同 → nil（fail closed）
        XCTAssertNil(RelayAuthCredentials.parse("forward:same:secret\ncontrol:same:secret\n"))

        // 含特殊符号的合法密码应允许
        XCTAssertNotNil(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_u", pass: "fwd!@#$%:pass"),
            control: CredentialPair(user: "ctrl_u", pass: "ctrl!@#$%")
        ))

        // user 含空白 / CR / LF / 冒号 → nil
        XCTAssertNil(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd user", pass: "fp"),
            control: CredentialPair(user: "ctrl_u", pass: "cp")
        ))
        XCTAssertNil(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_u", pass: "fp"),
            control: CredentialPair(user: "ctrl\tuser", pass: "cp")
        ))
        XCTAssertNil(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd:user", pass: "fp"),
            control: CredentialPair(user: "ctrl_u", pass: "cp")
        ))
        XCTAssertNil(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd\nuser", pass: "fp"),
            control: CredentialPair(user: "ctrl_u", pass: "cp")
        ))

        // pass 含 CR / LF → nil；control pass 含空白 → nil
        XCTAssertNil(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_u", pass: "fp\nRESTORE"),
            control: CredentialPair(user: "ctrl_u", pass: "cp")
        ))
        XCTAssertNil(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_u", pass: "fp\r"),
            control: CredentialPair(user: "ctrl_u", pass: "cp")
        ))
        XCTAssertNil(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_u", pass: "fp"),
            control: CredentialPair(user: "ctrl_u", pass: "cp\nRESTORE")
        ))
        XCTAssertNil(RelayAuthCredentials(
            forwarding: CredentialPair(user: "fwd_u", pass: "fp"),
            control: CredentialPair(user: "ctrl_u", pass: "cp pass")
        ))
        XCTAssertNil(RelayAuthCredentials.parse("forward:fwd u:fp\ncontrol:ctrl_u:cp\n"))
        XCTAssertNil(RelayAuthCredentials.parse("forward:fwd_u:fp\ncontrol:ctrl_u:cp pass\n"))
    }
}
