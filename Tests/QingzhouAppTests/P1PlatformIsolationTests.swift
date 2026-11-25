import XCTest
import QingzhouCore
import QingzhouLogging
@testable import QingzhouApp

/// P1 平台隔离与工程守卫测试：
/// 1. 确认 `SettingsView.swift` / `SplitExitListsView.swift` 的 macOS-only 分流/断网开关/sudo UI
///    严格位于 `#if os(macOS)` 块内，iOS 不会编译或暴露这些入口；
/// 2. 确认 `guardInstallCommand` 指向源码仓库脚本，且不再使用不存在的 `/Library/Application Support/qingzhou-guard/install.sh`；
/// 3. 确认 `PacketTunnelProvider.swift` 在 `composeSplitExit` 透传 `blockQUIC: self.blockQUIC`，
///    且 `loadSplitExitLists` 不再重复 `.prefix(SplitExitListsLimits.*)`。
final class P1PlatformIsolationTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // QingzhouAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private func splitMacOSAndNonMacOSSlices(source: String) -> (macOS: String, nonMacOS: String) {
        let lines = source.components(separatedBy: .newlines)
        var stack: [String] = []
        var macOSProtectedLines: [String] = []
        var nonMacOSLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") {
                stack.append(trimmed)
                continue
            } else if trimmed.hasPrefix("#elseif ") {
                if !stack.isEmpty { stack[stack.count - 1] = trimmed }
                continue
            } else if trimmed == "#else" {
                if !stack.isEmpty { stack[stack.count - 1] = "#else(\(stack.last ?? ""))" }
                continue
            } else if trimmed == "#endif" {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }

            if stack.contains(where: { $0 == "#if os(macOS)" }) {
                macOSProtectedLines.append(line)
            } else {
                nonMacOSLines.append(line)
            }
        }
        return (macOSProtectedLines.joined(separator: "\n"), nonMacOSLines.joined(separator: "\n"))
    }

    private func swiftFiles(in relativeDir: String, matchingPrefix prefix: String? = nil) throws -> [String] {
        let dirURL = repoRoot.appendingPathComponent(relativeDir)
        let entries = try FileManager.default.contentsOfDirectory(atPath: dirURL.path).sorted()
        return entries.compactMap { name in
            guard name.hasSuffix(".swift") else { return nil }
            if let prefix, !name.hasPrefix(prefix) { return nil }
            return "\(relativeDir)/\(name)"
        }
    }

    func testSettingsViewGuardsMacOSOnlySplitExitAndGuardUI() throws {
        let settingsFiles = ["Sources/QingzhouApp/SettingsView.swift"]
            + (try swiftFiles(in: "Sources/QingzhouApp/Settings"))
        var combinedSource = ""
        var combinedMacOS = ""

        for rel in settingsFiles {
            let source = try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)
            let (macOSBody, nonMacOSBody) = splitMacOSAndNonMacOSSlices(source: source)
            combinedSource += "\n" + source
            combinedMacOS += "\n" + macOSBody

            XCTAssertFalse(nonMacOSBody.contains("splitExitSection"), "\(rel): splitExitSection 必须在 #if os(macOS) 内")
            XCTAssertFalse(nonMacOSBody.contains("SettingsSplitExitSection"), "\(rel): SettingsSplitExitSection 必须在 #if os(macOS) 内")
            XCTAssertFalse(nonMacOSBody.contains("guardSection"), "\(rel): guardSection 必须在 #if os(macOS) 内")
            XCTAssertFalse(nonMacOSBody.contains("SettingsGuardSection"), "\(rel): SettingsGuardSection 必须在 #if os(macOS) 内")
            XCTAssertFalse(nonMacOSBody.contains("refreshGuardStatus"), "\(rel): refreshGuardStatus 必须在 #if os(macOS) 内")
            XCTAssertFalse(nonMacOSBody.contains("showListsSheet"), "\(rel): showListsSheet 必须在 #if os(macOS) 内")
            XCTAssertFalse(nonMacOSBody.contains("sudo "), "\(rel): iOS 可见代码禁止出现 sudo 命令")
            XCTAssertFalse(nonMacOSBody.contains("qingzhou-guard"), "\(rel): iOS 可见代码禁止出现 qingzhou-guard")
        }

        XCTAssertTrue(combinedMacOS.contains("struct SettingsSplitExitSection"))
        XCTAssertTrue(combinedMacOS.contains("struct SettingsGuardSection"))
        XCTAssertTrue(combinedMacOS.contains("sudo sh Tools/qingzhou-guard/install.sh"))
        XCTAssertFalse(combinedSource.contains("/Library/Application Support/qingzhou-guard/install.sh"),
                       "安装前不存在 /Library/Application Support/qingzhou-guard/install.sh")
        XCTAssertFalse(combinedSource.contains("UIPasteboard"), "macOS-only guard 辅助函数不应保留 iOS UIPasteboard 分支")
        XCTAssertFalse(combinedSource.contains("guard 每 10 秒读一次"), "应已更新为 10809 回环 TCP 控制端口说明")
    }

    func testAppStateAndHelpersGuardSplitExitAndFollowExitRegionForIOS() throws {
        // 即使 iCloud 同步把 macOS 的 splitExitEnabled / followExitRegion / guardRelayEnabled 带到 iOS，
        // iOS 侧所有读取与执行路径也必须处于 #if os(macOS) 守卫内，不得阻断 startTunnel、下载名单或篡改语言/时区。
        let appStateFiles = try swiftFiles(in: "Sources/QingzhouApp", matchingPrefix: "AppState")
        let guardedFiles = appStateFiles + [
            "Sources/QingzhouApp/NetworkInfoService.swift",
            "Sources/QingzhouApp/SplitExitListsUpdater.swift",
        ]
        let forbiddenInNonMacOS = [
            "settings.splitExitEnabled",
            "settings.followExitRegion",
            "settings.guardRelayEnabled",
            "settings.splitExitPolicyGroups",
            "requestSystemTimeZone(",
            "refreshSplitExitLists(",
        ]

        for rel in guardedFiles {
            let source = try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)
            let (_, nonMacOSBody) = splitMacOSAndNonMacOSSlices(source: source)
            let executableNonMacOS = nonMacOSBody
                .components(separatedBy: .newlines)
                .filter {
                    let t = $0.trimmingCharacters(in: .whitespaces)
                    return !t.hasPrefix("//")
                        && !t.contains("func requestSystemTimeZone(")
                        && !t.contains("func refreshSplitExitLists(")
                }
                .joined(separator: "\n")
            for token in forbiddenInNonMacOS {
                XCTAssertFalse(
                    executableNonMacOS.contains(token),
                    "\(rel) non-macOS slice must not reference '\(token)' outside #if os(macOS)"
                )
            }
        }

        // 验证 AppState 核心计算属性自带 #if os(macOS) ... #else 安全返回值
        let appStateSource = try appStateFiles
            .map { try String(contentsOf: repoRoot.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        for signature in [
            "public var splitExitBlockedReason: String?",
            "public var isFollowingExitRegion: Bool",
            "public var effectiveLanguage: AppLanguage",
            "public var displayTimeZone: TimeZone",
            "var activeSplitExit: (exit: Node, hop: Node)?",
        ] {
            guard let range = appStateSource.range(of: signature) else {
                XCTFail("Missing signature \(signature) in AppState*.swift")
                continue
            }
            let snippet = String(appStateSource[range.lowerBound...].prefix(450))
            XCTAssertTrue(snippet.contains("#if os(macOS)"), "\(signature) 必须包含 #if os(macOS) 守卫")
        }
    }

    @MainActor
    func testAppStateSyncedSplitExitSettingsLoadCleanlyWithoutMutatingDefaults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = Persistence(directory: dir)
        var synced = Settings()
        synced.splitExitEnabled = true
        synced.splitExitExitNodeID = UUID()
        synced.splitExitHopNodeID = UUID()
        synced.followExitRegion = true
        synced.guardRelayEnabled = true
        synced.language = .ja
        synced.iCloudSyncEnabled = false
        try persistence.saveSnapshot(Persistence.Snapshot(subscriptions: [], nodes: [], customRules: [], settings: synced, currentNodeId: nil))

        let state = AppState(logger: Logger(capacity: 50, minimumLevel: .error), persistence: persistence)
        XCTAssertEqual(state.settings.language, .ja)
        XCTAssertFalse(state.isFollowingExitRegion, "未运行 VPN 且无 proxyIPInfo 时不应激活跟随出口地区")
        XCTAssertEqual(state.effectiveLanguage, .ja)
        XCTAssertNil(state.activeSplitExit, "未命中实际出口/跳板节点时 activeSplitExit 必须为 nil")
        #if os(macOS)
        XCTAssertNotNil(state.splitExitBlockedReason)
        #else
        XCTAssertNil(state.splitExitBlockedReason)
        #endif
    }

    func testSplitExitListsViewIsGuardedForMacOS() throws {
        let path = repoRoot.appendingPathComponent("Sources/QingzhouApp/SplitExitListsView.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(source.contains("#if os(macOS)"))
        XCTAssertFalse(source.contains("#if os(iOS)"))
    }

    func testPacketTunnelProviderSplitExitPassesBlockQUICAndDropsRedundantPrefix() throws {
        let ptpFiles = try swiftFiles(in: "Apps/Tunnel-Shared", matchingPrefix: "PacketTunnelProvider")
        let source = try ptpFiles
            .map { try String(contentsOf: repoRoot.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertTrue(source.contains("blockQUIC: self.blockQUIC"))
        XCTAssertTrue(source.contains("policyGroups: splitExitPolicyGroups.withLock"))
        XCTAssertFalse(source.contains("lists.domains.prefix(SplitExitListsLimits"))
        XCTAssertFalse(source.contains("lists.domainKeywords.prefix(SplitExitListsLimits"))
        XCTAssertFalse(source.contains("lists.cidrs.prefix(SplitExitListsLimits"))
        XCTAssertFalse(source.contains("名单本身按域名热度排过序"))
    }

    func testExitRegionLocalizedSummaryTranslatesUnknownTimezone() {
        let profile = ExitRegionProfile(countryCode: "JP", country: "Japan", city: "Tokyo", timezoneID: nil)
        XCTAssertEqual(profile.localizedSummary, "Japan · Tokyo · \(L("未知时区"))")
    }
}
