import Foundation

/// Fixed destination shared by the app's TLS client and the tunnel's dedicated inbound.
/// This is deliberately not an arbitrary forwarding proxy.
public enum PublicIPProbe {
    public static let host = "ipwho.is"
    public static let path = "/"
    public static let maximumResponseBytes = 65_536
}
