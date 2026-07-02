import XCTest
import Network
@testable import QingzhouSpeedTest

/// PhysicalInterfacePicker 的纯函数单测 —— 输入接口列表（名字 + 类型），输出选中的下标。
///
/// 关键回归场景（历史教训，见 LatencyProber.swift 注释）：
/// iPhone USB 网络共享等场景下，唯一的物理网卡类型也是 `.other`——
/// 之前用 prohibitedInterfaceTypes=[.other] 一刀切，把它也禁了 → 探针全超时。
/// 所以选择逻辑必须：按名字识别 utun 等虚拟接口，而不是按类型一刀切；
/// 找不到合适物理接口时返回 nil（调用方回退到无绑定，保住可用性）。
final class PhysicalInterfacePickerTests: XCTestCase {

    private func candidate(_ name: String, _ type: NWInterface.InterfaceType) -> ProbeInterfaceCandidate {
        ProbeInterfaceCandidate(name: name, type: type)
    }

    // MARK: 明确物理类型（wifi / cellular / wiredEthernet）优先

    func testPrefersWifiOverUtun() {
        // VPN 开启时的典型列表：utun 排最前（主路由），物理 Wi-Fi 在后面
        let list = [candidate("utun4", .other), candidate("en0", .wifi)]
        XCTAssertEqual(PhysicalInterfacePicker.pickIndex(list), 1)
    }

    func testPrefersCellularOverUtun() {
        let list = [candidate("utun2", .other), candidate("pdp_ip0", .cellular)]
        XCTAssertEqual(PhysicalInterfacePicker.pickIndex(list), 1)
    }

    func testPrefersWiredEthernetOverUtun() {
        let list = [candidate("utun0", .other), candidate("en5", .wiredEthernet)]
        XCTAssertEqual(PhysicalInterfacePicker.pickIndex(list), 1)
    }

    func testKeepsSystemPreferenceOrderAmongPhysical() {
        // 多个物理口时不重排 —— availableInterfaces 本身就是系统偏好序，第一个物理口就是最优
        let wifiFirst = [candidate("en0", .wifi), candidate("pdp_ip0", .cellular)]
        XCTAssertEqual(PhysicalInterfacePicker.pickIndex(wifiFirst), 0)
        let cellFirst = [candidate("pdp_ip0", .cellular), candidate("en0", .wifi)]
        XCTAssertEqual(PhysicalInterfacePicker.pickIndex(cellFirst), 0)
    }

    // MARK: .other 不能一刀切 —— USB 共享回归场景

    func testUSBSharingOnlyOtherInterfaceIsPicked() {
        // 历史坑：USB 网络共享下唯一物理网卡（如 en2）类型是 .other，必须能选中
        let list = [candidate("en2", .other)]
        XCTAssertEqual(PhysicalInterfacePicker.pickIndex(list), 0)
    }

    func testUSBSharingOtherPlusUtunPicksTheNonUtun() {
        // VPN 开着 + USB 共享：utun 和 en2 都是 .other，按名字挑出 en2
        let list = [candidate("utun3", .other), candidate("en2", .other)]
        XCTAssertEqual(PhysicalInterfacePicker.pickIndex(list), 1)
    }

    func testExplicitPhysicalTypeBeatsOtherEvenIfOtherComesFirst() {
        // .other 的 en2 排前面，但后面有明确的 .wifi —— 选确定性更高的 .wifi
        let list = [candidate("en2", .other), candidate("en0", .wifi)]
        XCTAssertEqual(PhysicalInterfacePicker.pickIndex(list), 1)
    }

    // MARK: 找不到合适物理口 → nil（回退无绑定）

    func testOnlyUtunReturnsNil() {
        XCTAssertNil(PhysicalInterfacePicker.pickIndex([candidate("utun1", .other)]))
    }

    func testEmptyListReturnsNil() {
        XCTAssertNil(PhysicalInterfacePicker.pickIndex([]))
    }

    func testLoopbackIsNeverPicked() {
        XCTAssertNil(PhysicalInterfacePicker.pickIndex([candidate("lo0", .loopback)]))
    }

    func testKnownVirtualNamesAreExcluded() {
        // awdl（AirDrop）/ llw（低延迟 WLAN）/ ipsec / ppp 都不是能出公网的物理口
        let list = [
            candidate("awdl0", .other),
            candidate("llw0", .other),
            candidate("ipsec0", .other),
            candidate("ppp0", .other),
            candidate("utun0", .other),
        ]
        XCTAssertNil(PhysicalInterfacePicker.pickIndex(list))
    }

    func testVirtualNameMatchIsCaseInsensitive() {
        XCTAssertNil(PhysicalInterfacePicker.pickIndex([candidate("UTUN0", .other)]))
    }
}
