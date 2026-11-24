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
}
