import XCTest
@testable import QingzhouCore

final class TrafficConfigurationWindowTests: XCTestCase {
    func testMixedOrUnknownWindowDoesNotCreditEitherConfiguration() {
        let a = UUID(), b = UUID()
        var window = TrafficConfigurationWindow()
        XCTAssertNil(window.configurationForSample(current: a))
        XCTAssertEqual(window.configurationForSample(current: a), a)
        XCTAssertNil(window.configurationForSample(current: b), "A流量混入换成B后的第一个采样周期，不记B峰值")
        XCTAssertEqual(window.configurationForSample(current: b), b)
        XCTAssertNil(window.configurationForSample(current: nil))
        XCTAssertNil(window.configurationForSample(current: b))
    }
}
