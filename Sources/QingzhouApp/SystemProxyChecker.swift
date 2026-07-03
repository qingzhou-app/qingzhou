import Foundation
#if canImport(CFNetwork)
import CFNetwork
#endif

/// 只读地检查系统是否开启了 HTTP/HTTPS/SOCKS 系统代理。
///
/// 为什么需要：轻舟是 TUN 模式（抢默认路由、抓全部流量）。但如果系统里还开着**系统代理**
/// （最常见是 Clash/Clash Verge 的「系统代理」模式，指向 127.0.0.1:某端口），那么认系统代理的
/// App 会把流量先发给那个本机端口——`127.0.0.1` 走环回、**不经轻舟的 TUN**——于是变成
/// 「App → Clash → 轻舟隧道」的双重代理链，任一环出问题就整体联不上网。这时候提示用户先关掉
/// 系统代理，能省掉一大堆"莫名其妙全断"的排查。
///
/// 只调用 `CFNetworkCopySystemProxySettings()` **读取**设置，不修改任何系统配置（沙箱允许）。
enum SystemProxyChecker {

    /// 系统代理开着时返回一段可读的冲突提示；没开返回 nil。
    static func conflictWarning() -> String? {
        #if canImport(CFNetwork)
        guard let cf = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let settings = cf as? [String: Any] else {
            return nil
        }
        func hit(_ enableKey: CFString, _ hostKey: CFString, _ portKey: CFString, _ label: String) -> String? {
            guard (settings[enableKey as String] as? Int) == 1 else { return nil }
            let host = (settings[hostKey as String] as? String) ?? ""
            guard !host.isEmpty else { return nil }
            let port = (settings[portKey as String] as? Int) ?? 0
            return "\(label) \(host):\(port)"
        }
        var hits: [String] = []
        if let h = hit(kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPProxy, kCFNetworkProxiesHTTPPort, "HTTP") {
            hits.append(h)
        }
        #if os(macOS)
        if let h = hit(kCFNetworkProxiesHTTPSEnable, kCFNetworkProxiesHTTPSProxy, kCFNetworkProxiesHTTPSPort, "HTTPS") {
            hits.append(h)
        }
        if let h = hit(kCFNetworkProxiesSOCKSEnable, kCFNetworkProxiesSOCKSProxy, kCFNetworkProxiesSOCKSPort, "SOCKS") {
            hits.append(h)
        }
        #endif
        guard !hits.isEmpty else { return nil }
        // 信息性提示，不是硬冲突：系统代理（走环回、不经 TUN）与轻舟 TUN 可共存，只是形成
        // App→系统代理→轻舟 的冗余双重代理，一般不影响联网。真正会互斥的是「另一个 TUN 代理」
        // 抢默认路由（那种得关一个），但那个沙箱内难可靠检测，只能靠用户判断。
        let hitList = hits.joined(separator: L("、"))
        return L("检测到系统代理已开启（\(hitList)，可能是 Clash 等工具）。轻舟是 TUN 模式，可与它共存（会形成冗余的双重代理，一般不影响使用）；若个别 App 联网异常，可先关掉系统代理排除干扰。")
        #else
        return nil
        #endif
    }
}
