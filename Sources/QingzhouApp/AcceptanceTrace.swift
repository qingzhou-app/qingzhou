#if DEBUG
import Foundation

/// 仅开发验收使用的白名单事件。不接收自由文本，不受普通日志级别影响。
@MainActor
public enum AcceptanceTrace {
    public enum Kind: String, Codable, Sendable {
        case adopted, startSubmitted, cleanRestart, inPlaceSwitch, autoSelected
        case remoteRulesChanged, reapplyFullStarted, reapplyNodeStarted
        case unexpectedDisconnect, memoryWarning
    }

    public struct Event: Codable, Sendable {
        public let at: Date
        public let kind: Kind
    }

    public private(set) static var events: [Event] = []
    private static var enabled = false

    public static func begin() {
        events.removeAll(keepingCapacity: true)
        enabled = true
    }

    public static func end() { enabled = false }

    public static func record(_ kind: Kind) {
        guard enabled else { return }
        if events.count >= 128 { events.removeFirst() }
        events.append(Event(at: Date(), kind: kind))
    }
}
#endif
