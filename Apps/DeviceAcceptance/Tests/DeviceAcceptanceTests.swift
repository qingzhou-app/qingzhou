import XCTest
import Network

/// Runs against the installed app and its real ledger. No demo flags or replacement config.
/// Prerequisites: Chinese UI, connected VPN, distinct physical and node egress addresses.
@MainActor
final class DeviceAcceptanceTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.sbraveyoung.qingzhou.ios")
    private var mustRestoreWiFi = false
    private var resolvedAddresses: [String] = []

    override func setUp() async throws {
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.alerts["发现 iCloud 备份"].exists)
        app.tabBars.buttons["首页"].tap()
    }

    override func tearDown() async throws {
        if mustRestoreWiFi { restoreWiFiConnection() }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Real device final screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if (testRun?.failureCount ?? 0) > 0 {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Real device accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
    }

    func testPublicIPRefreshShowsSeparateEgresses() {
        reveal(app.staticTexts["直连（不走节点）"])
        XCTAssertTrue(app.staticTexts["节点出口"].exists)
        let refresh = app.buttons["刷新"].firstMatch
        reveal(refresh)
        refresh.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        resolvedAddresses = []
        let resolved = NSPredicate { _, _ in
            MainActor.assumeIsolated {
                guard refresh.isEnabled else { return false }
                let addresses = self.displayedIPAddresses()
                guard addresses.count == 2 else { return false }
                self.resolvedAddresses = addresses
                return true
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: resolved, object: nil)], timeout: 35), .completed)
        XCTAssertEqual(Set(resolvedAddresses).count, 2,
                       "The connected test fixture must display two distinct egress addresses")
        XCTAssertFalse(app.staticTexts["查询失败，请重试"].exists)
    }

    private func displayedIPAddresses() -> [String] {
        // One AX snapshot: separate count/label queries race with startup adoption
        // clearing IP results, and can read different generations of the screen.
        let snapshot = app.debugDescription
        let expression = try! NSRegularExpression(pattern:
            "StaticText[^\\n]*label: '((?:[0-9]{1,3}\\.){3}[0-9]{1,3}|[0-9A-Fa-f]*:[0-9A-Fa-f:]*)'")
        return expression.matches(in: snapshot, range: NSRange(snapshot.startIndex..., in: snapshot)).compactMap {
            guard let range = Range($0.range(at: 1), in: snapshot) else { return nil }
            let value = String(snapshot[range])
            return IPv4Address(value) != nil || IPv6Address(value) != nil ? value : nil
        }
    }

    func testMonthlyTrafficRoutesSearchAndDismiss() {
        let entry = app.buttons["域名流量分析"]
        reveal(entry)
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["域名流量分析"].waitForExistence(timeout: 10))
        app.buttons["月度"].tap()
        app.buttons["代理"].tap()
        let route = app.segmentedControls.firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 10))
        XCTAssertTrue(route.buttons["代理"].isSelected)
        for label in ["直连", "全部", "代理"] {
            route.buttons[label].tap()
            XCTAssertTrue(route.buttons[label].isSelected)
        }
        let search = app.textFields["搜索域名"]
        reveal(search)
        XCTAssertFalse(app.staticTexts["这个月还没有流量记录"].exists,
                       "Acceptance requires the device's existing real monthly ledger")
        let totalBefore = totalRowText()
        search.tap()
        search.typeText("qingzhou-no-match.invalid")
        XCTAssertEqual(search.value as? String, "qingzhou-no-match.invalid",
                       "The complete search term must reach the device")
        XCTAssertTrue(app.staticTexts["没有匹配的域名。"].waitForExistence(timeout: 5))
        XCTAssertEqual(totalRowText(), totalBefore, "Filtering the ranking must preserve the total")
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                               count: "qingzhou-no-match.invalid".count))
        XCTAssertTrue((search.value as? String ?? "").isEmpty || search.value as? String == "搜索域名")
        XCTAssertFalse(app.staticTexts["没有匹配的域名。"].exists)
        app.navigationBars["域名流量分析"].buttons["完成"].tap()
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["域名流量分析"].exists)
    }

    func testManualCloudRestoreCanBeOpenedAndCancelled() {
        app.tabBars.buttons["设置"].tap()
        let restore = app.buttons["立即恢复 iCloud 数据"]
        reveal(restore)
        restore.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let sheet = app.navigationBars["选择要恢复的版本"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["云端当前版本"].firstMatch.waitForExistence(timeout: 30),
                      "The version list must finish loading, not merely present a loading sheet")
        let versions = XCTAttachment(screenshot: app.screenshot())
        versions.name = "Manual cloud versions before cancellation"
        versions.lifetime = .keepAlways
        add(versions)
        let cancel = sheet.buttons["取消"]
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.alerts["发现 iCloud 备份"].exists)
        app.tabBars.buttons["首页"].tap()
        XCTAssertTrue(app.tabBars.buttons["首页"].isSelected)
    }

    private func totalRowText() -> String {
        let row = app.cells.containing(.staticText, identifier: "总流量").firstMatch
        XCTAssertTrue(row.exists, "The real monthly total row must be available")
        let text = row.staticTexts.allElementsBoundByIndex.map {
            $0.label + "|" + ($0.value as? String ?? "")
        }.joined(separator: ";")
        XCTAssertNotNil(text.range(of: #"\d+(?:\.\d+)? (?:B|KB|MB|GB|TB|PB)"#, options: .regularExpression),
                        "The total assertion must include a byte value, not just its label")
        return text
    }

    private func recordSurface(_ target: XCUIApplication, name: String) {
        for attachment in [XCTAttachment(string: target.debugDescription),
                           XCTAttachment(screenshot: target.screenshot())] {
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testWiFiCellularRoundTrip() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        settings.buttons["com.apple.settings.wifi"].tap()
        let wifi = settings.switches["无线局域网"].firstMatch
        XCTAssertTrue(wifi.waitForExistence(timeout: 10))
        let original = wifi.value as? String
        XCTAssertEqual(original, "1", "This round-trip fixture starts on Wi-Fi")
        // XCTest can abort a test through Objective-C failure handling; cleanup
        // belongs in tearDown rather than relying on a Swift defer being run.
        mustRestoreWiFi = true
        wifi.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "0"), object: wifi)], timeout: 10), .completed)
        recordSurface(settings, name: "Wi-Fi disabled for cellular check")
        app.launch()
        XCTAssertTrue(app.staticTexts["VPN 已连接"].waitForExistence(timeout: 25))
        testPublicIPRefreshShowsSeparateEgresses()
        recordSurface(app, name: "Cellular public IP and VPN")
        settings.launch()
        settings.buttons["com.apple.settings.wifi"].tap()
        wifi.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"), object: wifi)], timeout: 10), .completed)
        XCTAssertTrue(settings.images["checkmark"].firstMatch.waitForExistence(timeout: 25))
        mustRestoreWiFi = false
        recordSurface(settings, name: "Wi-Fi restored")
        app.launch()
        XCTAssertTrue(app.staticTexts["VPN 已连接"].waitForExistence(timeout: 25))
        testPublicIPRefreshShowsSeparateEgresses()
        recordSurface(app, name: "Restored Wi-Fi public IP and VPN")
    }

    func testLockScreenWidgetAndLiveActivityLifecycle() {
        verifyWidgetLifecycle(waitForConnectivity: true)
    }

    /// Separate regression for the observed stale Widget after immediately backgrounding.
    func testQuickBackgroundWidgetAfterReconnect() {
        verifyWidgetLifecycle(waitForConnectivity: false)
    }

    private func verifyWidgetLifecycle(waitForConnectivity: Bool) {
        // Finish the restoration path even when a display assertion fails.
        continueAfterFailure = true
        XCTAssertTrue(app.staticTexts["VPN 已连接"].waitForExistence(timeout: 20))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let widget = springboard.buttons.matching(identifier:
            "com.sbraveyoung.qingzhou.ios.widget:QingzhouStatusWidget").firstMatch
        func showNotificationCenter() {
            XCUIDevice.shared.press(.home)
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.01))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)))
        }
        showNotificationCenter()
        XCTAssertTrue(widget.staticTexts["已连接"].waitForExistence(timeout: 15))
        let live = springboard.buttons.matching(identifier: "ListCell")
            .containing(.staticText, identifier: "已连接").firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 15))
        recordSurface(springboard, name: "Widget and Live Activity connected")
        XCUIDevice.shared.press(.home)
        app.launch()
        XCTAssertTrue(app.staticTexts["VPN 已连接"].waitForExistence(timeout: 20))
        app.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["VPN 未连接"].waitForExistence(timeout: 25))
        showNotificationCenter()
        XCTAssertTrue(widget.staticTexts["未连接"].waitForExistence(timeout: 20))
        XCTAssertTrue(live.waitForNonExistence(timeout: 10))
        recordSurface(springboard, name: "Widget disconnected and Live Activity ended")
        XCUIDevice.shared.press(.home)
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 20))
        if app.staticTexts["VPN 未连接"].exists {
            app.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.staticTexts["VPN 已连接"].waitForExistence(timeout: 30))
        // Separate fully established connectivity from the optimistic toggle label.
        if waitForConnectivity { testPublicIPRefreshShowsSeparateEgresses() }
        showNotificationCenter()
        XCTAssertTrue(widget.staticTexts["已连接"].waitForExistence(timeout: 20))
        XCTAssertTrue(live.waitForExistence(timeout: 15))
        recordSurface(springboard, name: "Widget and Live Activity reconnected")
        XCUIDevice.shared.press(.home)
        app.activate()
    }

    func testRestoreWiFi() {
        restoreWiFiConnection()
        XCTAssertTrue(app.staticTexts["VPN 已连接"].waitForExistence(timeout: 25))
        testPublicIPRefreshShowsSeparateEgresses()
        recordSurface(app, name: "VPN and public IP after Wi-Fi restoration")
    }

    private func restoreWiFiConnection() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        settings.buttons["com.apple.settings.wifi"].tap()
        let wifi = settings.switches["无线局域网"].firstMatch
        XCTAssertTrue(wifi.waitForExistence(timeout: 10))
        recordSurface(settings, name: "Wi-Fi before restoration")
        if wifi.value as? String != "1" {
            wifi.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"), object: wifi)], timeout: 10), .completed)
        XCTAssertTrue(settings.images["checkmark"].firstMatch.waitForExistence(timeout: 25))
        recordSurface(settings, name: "Wi-Fi connected after restoration")
        mustRestoreWiFi = false
        app.launch()
    }

    private func reveal(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "Expected control is not reachable", file: file, line: line)
    }
}
