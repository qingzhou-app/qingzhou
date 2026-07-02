import XCTest
@testable import XrayCore

/// 内存采样器的回归测试 —— 在 swift test 的宿主进程里直接采，
/// 和扩展进程用的是同一条 mach call 路径。
final class MemoryFootprintTests: XCTestCase {

    /// 钉住验收 #17 的"恒 0"回归：task_info 的 count 参数没给够整个结构体时，
    /// 内核会成功返回但不填 phys_footprint（保持 0）。任何跑着 XCTest 的活进程
    /// footprint 都远大于 1MB —— 采出 nil 或小值即为回归。
    func testCurrentFootprintIsPlausiblyNonZero() {
        let fp = MemoryFootprint.currentFootprint()
        XCTAssertNotNil(fp, "footprint 采样在本机进程里不应失败")
        XCTAssertGreaterThan(fp ?? 0, 1024 * 1024,
                             "XCTest 进程的 phys_footprint 必然 > 1MB，小于即字段没被内核填充")
    }

    func testPlatformLimit() {
        #if os(iOS)
        XCTAssertEqual(MemoryFootprint.platformLimitBytes, 50 * 1024 * 1024)
        #else
        XCTAssertEqual(MemoryFootprint.platformLimitBytes, 0, "macOS 无 jetsam 硬上限，报 0")
        #endif
    }
}
