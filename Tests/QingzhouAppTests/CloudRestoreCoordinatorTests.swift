import XCTest
@testable import QingzhouApp

@MainActor
final class CloudRestoreCoordinatorTests: XCTestCase {
    private func candidate(_ revision: Int) -> VaultRestoreCandidate {
        let header = VaultHeader(schemaVersion: 1, revision: revision,
            modifiedAt: Date(timeIntervalSince1970: 100), deviceName: "test")
        return VaultRestoreCandidate(header: header, backupFileName: "r\(revision).json",
            replacementContext: .existing(header))
    }

    func testClosedThenReopenedListRejectsPreviousLoad() throws {
        let state = CloudRestoreCoordinator()
        state.presentVersions()
        let old = try XCTUnwrap(state.beginVersionLoad())
        state.dismissVersions()
        state.presentVersions()
        let current = try XCTUnwrap(state.beginVersionLoad())
        state.finishVersionLoad(.loaded([candidate(1)]), requestID: old)
        XCTAssertEqual(state.versionLoad, .loading)
        state.finishVersionLoad(.loaded([candidate(2)]), requestID: current)
        XCTAssertEqual(state.versionOptions, [candidate(2)])
        XCTAssertTrue(state.isVersionSheetPresented)
    }

    func testRetryRejectsOlderSuccessAndFailure() throws {
        let state = CloudRestoreCoordinator()
        state.presentVersions()
        let old = try XCTUnwrap(state.beginVersionLoad())
        let retry = try XCTUnwrap(state.beginVersionLoad())
        state.finishVersionLoad(.loaded([candidate(1)]), requestID: old)
        XCTAssertEqual(state.versionLoad, .loading)
        state.finishVersionLoad(.loaded([candidate(2)]), requestID: retry)
        state.finishVersionLoad(.failed("late failure"), requestID: old)
        XCTAssertEqual(state.versionOptions, [candidate(2)])
    }

    func testDismissRejectsLateResultAndCannotStartHiddenLoad() throws {
        let state = CloudRestoreCoordinator()
        state.presentVersions()
        let request = try XCTUnwrap(state.beginVersionLoad())
        state.dismissVersions()
        state.finishVersionLoad(.failed("late failure"), requestID: request)
        XCTAssertFalse(state.isVersionSheetPresented)
        XCTAssertNil(state.versionLoad)
        XCTAssertNil(state.beginVersionLoad())
    }

    func testChoosingVersionDefersOfferAndPreservesReplacementContext() throws {
        let state = CloudRestoreCoordinator()
        state.presentVersions()
        let request = try XCTUnwrap(state.beginVersionLoad())
        let chosen = candidate(1)
        state.choose(chosen)
        XCTAssertNil(state.offer)
        XCTAssertEqual(state.pendingCandidate, chosen)
        XCTAssertFalse(state.isVersionSheetPresented)
        state.finishVersionLoad(.loaded([candidate(2)]), requestID: request)
        XCTAssertNil(state.versionLoad)
        // SwiftUI 的关闭 binding 可以先于 onDismiss，不能清掉已选候选。
        state.dismissVersions()
        state.presentPendingOffer()
        XCTAssertEqual(state.offer, chosen)
        XCTAssertNil(state.pendingCandidate)
        state.offer = nil
        state.presentPendingOffer()
        XCTAssertNil(state.offer, "onDismiss 重复回调不能再次弹确认")
    }

    func testReopeningDropsUnpresentedChoice() {
        let state = CloudRestoreCoordinator()
        state.presentVersions()
        state.choose(candidate(1))
        state.presentVersions()
        state.presentPendingOffer()
        XCTAssertNil(state.offer)
        XCTAssertNil(state.pendingCandidate)
        XCTAssertTrue(state.isVersionSheetPresented)
    }

    func testLoadingFailureKeepsSheetPresentedAndRetryCanSucceed() throws {
        let state = CloudRestoreCoordinator()
        state.presentVersions()
        let request = try XCTUnwrap(state.beginVersionLoad())
        state.finishVersionLoad(.failed("not downloaded"), requestID: request)
        XCTAssertTrue(state.isVersionSheetPresented)
        XCTAssertNil(state.versionOptions)
        let retry = try XCTUnwrap(state.beginVersionLoad())
        state.finishVersionLoad(.loaded([candidate(1)]), requestID: retry)
        XCTAssertTrue(state.isVersionSheetPresented)
        XCTAssertEqual(state.versionOptions, [candidate(1)])
    }
}
