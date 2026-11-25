import Foundation

public struct CredentialPair: Sendable, Equatable {
    public let user: String
    public let pass: String

    public init(user: String, pass: String) {
        self.user = user
        self.pass = pass
    }
}

/// 分离的转发凭据与控制凭据。
///
/// `relay-auth` 格式：
/// ```
/// forward:<forwardUser>:<forwardPass>
/// control:<controlUser>:<controlPass>
/// ```
/// 任意一侧缺失、为空或两侧凭据相同时一律 fail closed（返回 `nil`）。
public struct RelayAuthCredentials: Sendable, Equatable {
    public let forwarding: CredentialPair
    public let control: CredentialPair

    private static func isValidUser(_ user: String) -> Bool {
        !user.isEmpty && !user.contains { $0.isWhitespace || $0.isNewline || $0 == "\r" || $0 == "\n" || $0 == ":" }
    }

    private static func isValidForwardPassword(_ pass: String) -> Bool {
        !pass.isEmpty && !pass.contains { $0.isNewline || $0 == "\r" || $0 == "\n" }
    }

    private static func isValidControlPassword(_ pass: String) -> Bool {
        !pass.isEmpty && !pass.contains { $0.isWhitespace || $0.isNewline || $0 == "\r" || $0 == "\n" }
    }

    public init?(forwarding: CredentialPair, control: CredentialPair) {
        guard Self.isValidUser(forwarding.user),
              Self.isValidForwardPassword(forwarding.pass),
              Self.isValidUser(control.user),
              Self.isValidControlPassword(control.pass),
              forwarding != control else {
            return nil
        }
        self.forwarding = forwarding
        self.control = control
    }

    public static func load(from path: String) -> RelayAuthCredentials? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parse(text)
    }

    public static func parse(_ text: String) -> RelayAuthCredentials? {
        var forwardPair: CredentialPair?
        var controlPair: CredentialPair?

        for raw in text.split(whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("forward:") {
                let rest = String(line.dropFirst("forward:".count))
                if let pair = parsePair(rest) {
                    forwardPair = pair
                }
            } else if line.hasPrefix("control:") {
                let rest = String(line.dropFirst("control:".count))
                if let pair = parsePair(rest) {
                    controlPair = pair
                }
            }
        }

        guard let f = forwardPair, let c = controlPair else { return nil }
        return RelayAuthCredentials(forwarding: f, control: c)
    }

    private static func parsePair(_ raw: String) -> CredentialPair? {
        guard let sep = raw.firstIndex(of: ":") else { return nil }
        let user = String(raw[..<sep])
        let pass = String(raw[raw.index(after: sep)...])
        guard !user.isEmpty, !pass.isEmpty else { return nil }
        return CredentialPair(user: user, pass: pass)
    }
}
