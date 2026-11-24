import Foundation

public protocol TimeZoneProviding: Sendable {
    func currentTimeZone() -> String
    func setSystemTimeZone(_ identifier: String) -> Bool
    func isValidTimeZone(_ identifier: String) -> Bool
}

public struct SystemTimeZoneProvider: TimeZoneProviding {
    public static let zoneinfoRoot = "/usr/share/zoneinfo/"

    public init() {}

    public func isValidTimeZone(_ identifier: String) -> Bool {
        Self.validateZoneInfoIdentifier(identifier, zoneinfoRoot: Self.zoneinfoRoot)
    }

    public static func validateZoneInfoIdentifier(_ id: String, zoneinfoRoot: String = Self.zoneinfoRoot) -> Bool {
        guard !id.isEmpty,
              !id.hasPrefix("/"),
              !id.hasSuffix("/"),
              !id.hasPrefix("+"),
              !id.contains(".."),
              !id.contains("//"),
              !id.contains("\\"),
              !id.contains("\0"),
              !id.contains(where: { $0.isWhitespace }) else {
            return false
        }
        guard TimeZone(identifier: id) != nil else {
            return false
        }
        let path = zoneinfoRoot + id
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        guard let fh = FileHandle(forReadingAtPath: path) else {
            return false
        }
        defer { try? fh.close() }
        let magic = (try? fh.read(upToCount: 4)) ?? Data()
        return magic == Data("TZif".utf8)
    }

    public func currentTimeZone() -> String {
        #if os(macOS)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/systemsetup")
        p.arguments = ["-gettimezone"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(decoding: data, as: UTF8.self)
        if let range = out.range(of: "Time Zone: ") {
            return String(out[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
        #else
        return TimeZone.current.identifier
        #endif
    }

    @discardableResult
    public func setSystemTimeZone(_ identifier: String) -> Bool {
        #if os(macOS)
        guard isValidTimeZone(identifier) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/systemsetup")
        p.arguments = ["-settimezone", identifier]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
        #else
        return false
        #endif
    }
}

/// 系统时区控制器：记录首次原时区到 `tzOrigPath` 供 `RESTORE` 与 `uninstall.sh` 还原，
/// 并在 `SET-TZ` 时将目标时区与 `currentTimeZone()`（而非 `tzOrigPath`）比对。
public final class TimeZoneController: @unchecked Sendable {
    public enum ActionResult: Sendable, Equatable {
        case ok
        case invalidZone
        case setFailed
        case noOriginal
    }

    private let tzOrigPath: String
    private let provider: TimeZoneProviding
    private let logger: RelayLogger?
    private let lock = NSLock()

    public init(
        tzOrigPath: String = "/Library/Application Support/qingzhou-guard/timezone-orig",
        provider: TimeZoneProviding = SystemTimeZoneProvider(),
        logger: RelayLogger? = nil
    ) {
        self.tzOrigPath = tzOrigPath
        self.provider = provider
        self.logger = logger
    }

    public func currentTimeZone() -> String {
        lock.lock()
        defer { lock.unlock() }
        return provider.currentTimeZone().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func setTimeZone(_ rawTZ: String) -> ActionResult {
        let tz = rawTZ.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider.isValidTimeZone(tz) else {
            return .invalidZone
        }

        lock.lock()
        defer { lock.unlock() }

        let current = provider.currentTimeZone().trimmingCharacters(in: .whitespacesAndNewlines)

        // 首次切换前记录原时区（只记一次），供 RESTORE 与 uninstall.sh 用
        if !FileManager.default.fileExists(atPath: tzOrigPath) {
            if !current.isEmpty {
                let parent = (tzOrigPath as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                try? current.write(toFile: tzOrigPath, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tzOrigPath)
                logger?.log("记录原时区：\(current)")
            }
        }

        // 与当前系统时区比对，而不是与 timezone-orig 比对：
        // 切到海外时区后再切回原时区时，必须真正调用 systemsetup 还原。
        if current == tz {
            return .ok
        }

        if provider.setSystemTimeZone(tz) {
            logger?.log("系统时区 → \(tz)")
            return .ok
        } else {
            logger?.log("设置时区失败：\(tz)")
            return .setFailed
        }
    }

    public func restore() -> ActionResult {
        lock.lock()
        defer { lock.unlock() }

        guard let orig = try? String(contentsOfFile: tzOrigPath, encoding: .utf8) else {
            return .noOriginal
        }
        let target = orig.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return .noOriginal
        }
        guard provider.isValidTimeZone(target) else {
            return .invalidZone
        }
        if provider.setSystemTimeZone(target) {
            logger?.log("还原时区 → \(target)")
            return .ok
        } else {
            logger?.log("还原时区失败：\(target)")
            return .setFailed
        }
    }
}
