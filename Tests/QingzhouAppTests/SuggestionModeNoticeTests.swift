import XCTest
import QingzhouCore
@testable import QingzhouApp

/// 域名分析「建议」tab 的模式提示：非规则模式下分流建议只是参考，不加说明会误导
/// （真实验收反馈：全局模式下「国内域名走了代理」本来就是预期行为）。
final class SuggestionModeNoticeTests: XCTestCase {

    func testRuleModeHasNoNotice() {
        XCTAssertNil(DomainAnalysisView.suggestionModeNotice(for: .rule),
                     "规则模式下建议可直接行动，不需要弱化说明")
    }

    func testGlobalModeExplainsAllTrafficProxied() {
        let n = DomainAnalysisView.suggestionModeNotice(for: .global)
        XCTAssertNotNil(n)
        XCTAssertTrue(n!.contains("全局模式"))
        XCTAssertTrue(n!.contains("仅供参考"))
    }

    func testDirectModeExplainsAllTrafficDirect() {
        let n = DomainAnalysisView.suggestionModeNotice(for: .direct)
        XCTAssertNotNil(n)
        XCTAssertTrue(n!.contains("直连模式"))
        XCTAssertTrue(n!.contains("仅供参考"))
    }
}
