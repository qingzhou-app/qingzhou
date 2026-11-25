import Foundation
import QingzhouCore
import QingzhouGuardRelayCore
import QingzhouSubscription
import QingzhouApp

final class FakeTimeZoneProvider: TimeZoneProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var currentTZ: String
    private var validZones: Set<String>
    private var failSet: Bool
    private var _setCalls: [String] = []

    init(
        initial: String = "Asia/Shanghai",
        validZones: Set<String> = [
            "Asia/Shanghai",
            "America/New_York",
            "Asia/Tokyo",
            "Europe/London",
            "UTC",
        ],
        failSet: Bool = false
    ) {
        self.currentTZ = initial
        self.validZones = validZones
        self.failSet = failSet
    }

    var setCalls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _setCalls
    }

    func setShouldFail(_ shouldFail: Bool) {
        lock.lock()
        failSet = shouldFail
        lock.unlock()
    }

    func currentTimeZone() -> String {
        lock.lock()
        defer { lock.unlock() }
        return currentTZ
    }

    func setSystemTimeZone(_ identifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        _setCalls.append(identifier)
        if failSet { return false }
        currentTZ = identifier
        return true
    }

    func isValidTimeZone(_ identifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return validZones.contains(identifier)
    }
}

final class InMemorySplitExitListsStore: SplitExitListsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SplitExitLists?
    private var nextSaveError: Error?
    private var corruptReadBackCount = false
    private var _saveCount = 0
    private var _loadCount = 0

    init(initial: SplitExitLists? = nil) {
        self.stored = initial
    }

    var saveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _saveCount
    }

    var loadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _loadCount
    }

    func setNextSaveError(_ error: Error?) {
        lock.lock()
        nextSaveError = error
        lock.unlock()
    }

    func setCorruptReadBack(_ corrupt: Bool) {
        lock.lock()
        corruptReadBackCount = corrupt
        lock.unlock()
    }

    func load() -> SplitExitLists? {
        lock.lock()
        defer { lock.unlock() }
        _loadCount += 1
        guard var current = stored else { return nil }
        if corruptReadBackCount {
            current.domains = []
        }
        return current
    }

    func save(_ lists: SplitExitLists) throws {
        lock.lock()
        defer { lock.unlock() }
        _saveCount += 1
        if let err = nextSaveError {
            nextSaveError = nil
            throw err
        }
        stored = lists
    }
}

final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable (URL) throws -> (Data, [String: String])
    private var _requestedURLs: [URL] = []

    init(handler: @escaping @Sendable (URL) throws -> (Data, [String: String])) {
        self.handler = handler
    }

    convenience init(routes: [String: Result<String, Error>]) {
        self.init { url in
            let key = url.lastPathComponent
            if let result = routes[key] ?? routes[url.absoluteString] {
                switch result {
                case .success(let body):
                    return (Data(body.utf8), [:])
                case .failure(let err):
                    throw err
                }
            }
            throw URLError(.fileDoesNotExist)
        }
    }

    func updateHandler(_ newHandler: @escaping @Sendable (URL) throws -> (Data, [String: String])) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    var requestedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return _requestedURLs
    }

    func get(_ url: URL) async throws -> (Data, [String: String]) {
        let currentHandler: @Sendable (URL) throws -> (Data, [String: String]) = lock.withLock {
            _requestedURLs.append(url)
            return handler
        }
        return try currentHandler(url)
    }
}

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}
