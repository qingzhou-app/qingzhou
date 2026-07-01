import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 「连接」页里标注来源 App 的小标签：macOS 上显示真实 App 图标 + 友好名字，
/// iOS 上（拿不到进程归属）不会用到，退化成占位符 + bundle id。
struct SourceAppLabel: View {
    let bundleID: String

    var body: some View {
        #if os(macOS)
        let info = AppInfoCache.shared.info(for: bundleID)
        HStack(spacing: 4) {
            if let icon = info.icon {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            } else {
                Image(systemName: "app.dashed").imageScale(.small)
            }
            Text(info.name).lineLimit(1)
        }
        #else
        Label(bundleID, systemImage: "app.dashed").lineLimit(1)
        #endif
    }
}

#if os(macOS)
/// bundle id → (友好名, 图标) 的缓存。NSWorkspace 查询略慢，缓存避免每帧重查。
@MainActor
final class AppInfoCache {
    static let shared = AppInfoCache()
    private var cache: [String: (name: String, icon: NSImage?)] = [:]

    func info(for bundleID: String) -> (name: String, icon: NSImage?) {
        if let c = cache[bundleID] { return c }
        let resolved = resolve(bundleID)
        cache[bundleID] = resolved
        return resolved
    }

    private func resolve(_ bundleID: String) -> (name: String, icon: NSImage?) {
        let ws = NSWorkspace.shared
        // helper 进程（com.google.Chrome.helper、...claudefordesktop.helper）在系统里没有独立
        // App，逐级剥掉末段后缀回退到主 App bundle id 才能查到图标。
        var bid = bundleID
        var url = ws.urlForApplication(withBundleIdentifier: bid)
        while url == nil, let dot = bid.range(of: ".", options: .backwards) {
            bid = String(bid[..<dot.lowerBound])
            url = ws.urlForApplication(withBundleIdentifier: bid)
        }
        guard let url else {
            // 查不到（系统守护进程等）：用 bundle id 末段兜底做名字，无图标
            let fallback = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            return (fallback, nil)
        }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        return (name, ws.icon(forFile: url.path))
    }
}
#endif
