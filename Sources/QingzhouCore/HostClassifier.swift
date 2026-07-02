import Foundation

/// 判定连接目标是不是「裸 IP」（没有域名），供连接页 / 域名分析页的「忽略 IP」过滤用。
///
/// 背景：FakeDNS 反查不到域名的连接，`targetHost` 就是一个 IP —— 在域名分析里没有
/// 聚合价值，在连接列表里是噪音。这个过滤把它们隐藏掉。
///
/// 设计取舍：
/// - **纯函数、不依赖 Darwin 的 inet_pton** —— 行为完全由自己的解析定义，跨平台一致、可单测。
/// - **保守判定**：只有能确认是合法 IP（可带端口 / 方括号 / zone id）才返回 true。
///   畸形输入（如 "256.1.1.1"、"1::2::3"）返回 false —— 宁可漏过滤也不误杀，
///   误杀会让用户以为连接数据丢了。
/// - 整数形式 IP（"3232235521"）不识别：实际日志里不会出现，识别它反而可能误杀数字开头的主机名。
public enum HostClassifier {

    /// `target` 是否为裸 IP。接受的形态：
    /// - IPv4：`1.2.3.4`，可带端口 `1.2.3.4:443`
    /// - IPv6：`::1` / `2001:db8::1` / 完整 8 组 / 内嵌 IPv4（`::ffff:1.2.3.4`）/ zone id（`fe80::1%en0`）
    /// - 方括号 IPv6：`[::1]`，可带端口 `[2001:db8::1]:443`
    public static func isBareIP(_ target: String) -> Bool {
        let s = target.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return false }

        // [IPv6] 或 [IPv6]:port
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return false }
            let inner = String(s[s.index(after: s.startIndex)..<close])
            let suffix = s[s.index(after: close)...]
            if !suffix.isEmpty {
                guard suffix.hasPrefix(":"), isValidPort(suffix.dropFirst()) else { return false }
            }
            return isIPv6(inner)
        }

        if isIPv4(s) { return true }

        // IPv4:port —— 从右起最后一个冒号切端口（IPv6 不可能只有一个冒号段是端口，
        // 未加方括号的 IPv6 直接整体走 isIPv6）
        if let lastColon = s.lastIndex(of: ":"),
           s[..<lastColon].contains(":") == false {   // 只有一个冒号才可能是 host:port
            let host = String(s[..<lastColon])
            let port = s[s.index(after: lastColon)...]
            if isValidPort(port), isIPv4(host) { return true }
        }

        return isIPv6(s)
    }

    // MARK: - IPv4

    private static func isIPv4(_ s: String) -> Bool {
        // 用 components（不丢空段），"1.2.3.4." 这类尾部空段才能被判非法
        let parts = s.components(separatedBy: ".")
        guard parts.count == 4 else { return false }
        for p in parts {
            guard (1...3).contains(p.count),
                  p.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let v = Int(p), v <= 255 else { return false }
        }
        return true
    }

    // MARK: - IPv6

    private static func isIPv6(_ input: String) -> Bool {
        // 去掉 zone id（fe80::1%en0）；zone 前必须真有地址
        var s = input
        if let percent = s.firstIndex(of: "%") {
            s = String(s[..<percent])
            guard !s.isEmpty else { return false }
        }

        // "::" 最多出现一次
        let doubleColonParts = s.components(separatedBy: "::")
        guard doubleColonParts.count <= 2 else { return false }
        let hasDoubleColon = doubleColonParts.count == 2

        func groups(of side: String) -> [String]? {
            if side.isEmpty { return [] }
            let gs = side.components(separatedBy: ":")
            // components 保留空段：单个前导/尾随/连续冒号 → 空段 → 非法
            return gs.contains("") ? nil : gs
        }

        guard let head = groups(of: doubleColonParts[0]),
              let tail = hasDoubleColon ? groups(of: doubleColonParts[1]) : []
        else { return false }

        let all = head + tail
        guard !all.isEmpty || hasDoubleColon else { return false }  // 空串不是地址（"::" 是）

        // 内嵌 IPv4 只允许出现在最后一组，占 2 组的量
        var groupCount = all.count
        for (i, g) in all.enumerated() {
            if g.contains(".") {
                guard i == all.count - 1, isIPv4(g) else { return false }
                groupCount += 1   // IPv4 占 32 位 = 2 组
            } else {
                guard (1...4).contains(g.count),
                      g.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return false }
            }
        }

        // 组数约束：有 :: 时它至少压缩 1 组（显式组 ≤ 7）；没有则必须恰好 8 组
        return hasDoubleColon ? groupCount <= 7 : groupCount == 8
    }

    // MARK: - 端口

    private static func isValidPort<S: StringProtocol>(_ p: S) -> Bool {
        guard !p.isEmpty, p.count <= 5,
              p.allSatisfy({ $0.isASCII && $0.isNumber }),
              let v = Int(p), (1...65535).contains(v) else { return false }
        return true
    }
}
