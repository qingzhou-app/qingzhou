import Foundation

/// 线程安全、带大小轮转的日志器。
///
/// 使用单个可复用的 `ISO8601DateFormatter` 与 `NSLock` 串行化写入，
/// 并在超过 `maxBytes`（默认 5 MiB）时轮转到 `<logPath>.1`（保留 `0600` 权限）。
public final class RelayLogger: @unchecked Sendable {
    public static let defaultMaxBytes: UInt64 = 5 * 1024 * 1024

    private let logPath: String?
    private let maxBytes: UInt64
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()
    private var handle: FileHandle?
    private var currentSize: UInt64 = 0

    public init(logPath: String?, maxBytes: UInt64 = RelayLogger.defaultMaxBytes) {
        self.logPath = logPath
        self.maxBytes = max(1, maxBytes)
    }

    deinit {
        lock.lock()
        try? handle?.close()
        handle = nil
        lock.unlock()
    }

    public func log(_ message: String) {
        let ts: String
        lock.lock()
        defer { lock.unlock() }

        ts = formatter.string(from: Date())
        let data = Data("\(ts) [relay] \(message)\n".utf8)

        guard let path = logPath else {
            FileHandle.standardError.write(data)
            return
        }

        ensureOpen(at: path)
        if handle != nil {
            if currentSize > 0 && currentSize + UInt64(data.count) > maxBytes {
                rotate(at: path)
            }
            if let rotatedOrOpen = handle {
                rotatedOrOpen.write(data)
                currentSize += UInt64(data.count)
                return
            }
        }
        FileHandle.standardError.write(data)
    }

    private func ensureOpen(at path: String) {
        if handle != nil { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        } else {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        let end = h.seekToEndOfFile()
        currentSize = end
        handle = h
    }

    private func rotate(at path: String) {
        try? handle?.close()
        handle = nil
        currentSize = 0

        let fm = FileManager.default
        let backupPath = path + ".1"
        if fm.fileExists(atPath: backupPath) {
            try? fm.removeItem(atPath: backupPath)
        }
        if fm.fileExists(atPath: path) {
            try? fm.moveItem(atPath: path, toPath: backupPath)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupPath)
        }
        fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        if let h = FileHandle(forWritingAtPath: path) {
            handle = h
            currentSize = 0
        }
    }
}
