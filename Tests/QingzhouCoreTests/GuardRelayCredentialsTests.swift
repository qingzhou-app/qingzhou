import XCTest
@testable import QingzhouCore

final class GuardRelayCredentialsTests: XCTestCase {

    func testBackwardCompatibleDecodeWithoutControlFields() throws {
        let legacyJSON = #"{"host":"127.0.0.1","port":10808,"username":"fwd_u","password":"fwd_p"}"#
        let creds = try XCTUnwrap(GuardRelayCredentials.decode(legacyJSON))
        XCTAssertEqual(creds.host, "127.0.0.1")
        XCTAssertEqual(creds.port, 10808)
        XCTAssertEqual(creds.username, "fwd_u")
        XCTAssertEqual(creds.password, "fwd_p")
        XCTAssertNil(creds.controlPort)
        XCTAssertNil(creds.controlUsername)
        XCTAssertNil(creds.controlPassword)
        XCTAssertFalse(creds.hasValidControlCredentials)
        XCTAssertNil(creds.validatedControlCredentials())
    }

    func testRoundTripWithSeparatedControlFields() throws {
        let creds = GuardRelayCredentials(
            port: 10808,
            username: "fwd_u",
            password: "fwd_p",
            controlPort: 10819,
            controlUsername: "ctrl_u",
            controlPassword: "ctrl_p"
        )
        let decoded = try XCTUnwrap(GuardRelayCredentials.decode(creds.jsonString))
        XCTAssertEqual(decoded, creds)
        XCTAssertTrue(decoded.hasValidControlCredentials)
        let ctrl = try XCTUnwrap(decoded.validatedControlCredentials())
        XCTAssertEqual(ctrl.port, 10819)
        XCTAssertEqual(ctrl.username, "ctrl_u")
        XCTAssertEqual(ctrl.password, "ctrl_p")

        let stripped = decoded.forwardingOnly
        XCTAssertEqual(stripped.username, "fwd_u")
        XCTAssertEqual(stripped.password, "fwd_p")
        XCTAssertNil(stripped.controlUsername)
        XCTAssertNil(stripped.controlPassword)
        XCTAssertNil(stripped.controlPort)
        XCTAssertFalse(stripped.hasValidControlCredentials)
    }

    func testValidationRejectsEmptyAndIdenticalControlCredentials() {
        let emptyUser = GuardRelayCredentials(
            port: 10808, username: "fwd_u", password: "fwd_p",
            controlPort: 10809, controlUsername: "", controlPassword: "ctrl_p"
        )
        XCTAssertFalse(emptyUser.hasValidControlCredentials)

        let emptyPass = GuardRelayCredentials(
            port: 10808, username: "fwd_u", password: "fwd_p",
            controlPort: 10809, controlUsername: "ctrl_u", controlPassword: ""
        )
        XCTAssertFalse(emptyPass.hasValidControlCredentials)

        let zeroPort = GuardRelayCredentials(
            port: 10808, username: "fwd_u", password: "fwd_p",
            controlPort: 0, controlUsername: "ctrl_u", controlPassword: "ctrl_p"
        )
        XCTAssertFalse(zeroPort.hasValidControlCredentials)

        let identical = GuardRelayCredentials(
            port: 10808, username: "same_u", password: "same_p",
            controlPort: 10809, controlUsername: "same_u", controlPassword: "same_p"
        )
        XCTAssertFalse(identical.hasValidControlCredentials)
        XCTAssertNil(identical.validatedControlCredentials())

        // controlPort 为 nil 时回退默认 10809
        let defaultPort = GuardRelayCredentials(
            port: 10808, username: "fwd_u", password: "fwd_p",
            controlPort: nil, controlUsername: "ctrl_u", controlPassword: "ctrl_p"
        )
        XCTAssertEqual(defaultPort.validatedControlCredentials()?.port, GuardRelayCredentials.controlPort)
    }

    func testRejectsWhitespaceNewlinesAndColonsInCredentials() {
        // 含合法标点的密码仍应通过
        let validPunct = GuardRelayCredentials(
            port: 10808, username: "fwd_u", password: "f!@#$%p",
            controlPort: 10809, controlUsername: "ctrl_u", controlPassword: "c!@#$%p"
        )
        XCTAssertTrue(validPunct.hasValidControlCredentials)
        XCTAssertNotNil(GuardRelayCredentials.decode(validPunct.jsonString))

        // controlUsername / controlPassword 含空白 / CR / LF / 冒号 → 拒绝
        let spaceCtrlUser = GuardRelayCredentials(
            port: 10808, username: "fwd_u", password: "fwd_p",
            controlPort: 10809, controlUsername: "ctrl user", controlPassword: "cp"
        )
        XCTAssertFalse(spaceCtrlUser.hasValidControlCredentials)
        XCTAssertNil(spaceCtrlUser.validatedControlCredentials())

        let colonCtrlUser = GuardRelayCredentials(
            port: 10808, username: "fwd_u", password: "fwd_p",
            controlPort: 10809, controlUsername: "ctrl:user", controlPassword: "cp"
        )
        XCTAssertFalse(colonCtrlUser.hasValidControlCredentials)

        let newlineCtrlPass = GuardRelayCredentials(
            port: 10808, username: "fwd_u", password: "fwd_p",
            controlPort: 10809, controlUsername: "ctrl_u", controlPassword: "cp\nRESTORE"
        )
        XCTAssertFalse(newlineCtrlPass.hasValidControlCredentials)

        let crCtrlPass = GuardRelayCredentials(
            port: 10808, username: "fwd_u", password: "fwd_p",
            controlPort: 10809, controlUsername: "ctrl_u", controlPassword: "cp\r"
        )
        XCTAssertFalse(crCtrlPass.hasValidControlCredentials)

        let spaceCtrlPass = GuardRelayCredentials(
            port: 10808, username: "fwd_u", password: "fwd_p",
            controlPort: 10809, controlUsername: "ctrl_u", controlPassword: "cp pass"
        )
        XCTAssertFalse(spaceCtrlPass.hasValidControlCredentials)

        // decode 拒绝 username 空白/冒号/换行、password 换行
        let badFwdUser = GuardRelayCredentials(port: 10808, username: "fwd user", password: "fp")
        XCTAssertNil(GuardRelayCredentials.decode(badFwdUser.jsonString))

        let badFwdUserColon = GuardRelayCredentials(port: 10808, username: "fwd:user", password: "fp")
        XCTAssertNil(GuardRelayCredentials.decode(badFwdUserColon.jsonString))

        let badFwdPassNewline = GuardRelayCredentials(port: 10808, username: "fwd_u", password: "fp\nbad")
        XCTAssertNil(GuardRelayCredentials.decode(badFwdPassNewline.jsonString))
    }
}
