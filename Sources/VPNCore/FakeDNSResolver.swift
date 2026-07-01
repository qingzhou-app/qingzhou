import Foundation

/// 解析 DNS 响应报文，提取「A 记录 IP → 查询的域名」。
///
/// 为什么要它：开了 FakeDNS 后，xray 给每个域名分配一个 198.18.x.x 假 IP，但这版内核的
/// access log 记的是假 IP、不会反查回域名。于是 appex 自己在 socketpair 层截下 xray 发回
/// App 的 DNS 响应（明文 UDP），用这个解析器建「假 IP → 域名」映射，主 App 再拿它把连接
/// 列表里的假 IP 翻译成域名。纯字节解析，可单测，不依赖真机。
public enum FakeDNSResolver {

    /// 解析一个 DNS 响应报文（DNS message，不含 IP/UDP 头），返回若干 (ip, domain)。
    /// 只取 question 的域名 + answer 里的 A 记录（IPv4）。畸形/非 A 记录安全跳过。
    public static func parseResponse(_ bytes: [UInt8]) -> [(ip: String, domain: String)] {
        guard bytes.count >= 12 else { return [] }
        let qdcount = Int(bytes[4]) << 8 | Int(bytes[5])
        let ancount = Int(bytes[6]) << 8 | Int(bytes[7])
        guard qdcount >= 1 else { return [] }

        var offset = 12
        // 第一个 question 的 qname 就是这次查询的域名
        guard let (domain, afterQ) = readName(bytes, offset) else { return [] }
        offset = afterQ + 4                      // 跳过 qtype(2) + qclass(2)
        for _ in 1..<qdcount {                   // 跳过其余 question
            guard let (_, next) = readName(bytes, offset) else { return [] }
            offset = next + 4
        }

        var result: [(ip: String, domain: String)] = []
        for _ in 0..<ancount {
            guard let (_, afterName) = readName(bytes, offset) else { break }
            let p = afterName
            guard p + 10 <= bytes.count else { break }
            let type = Int(bytes[p]) << 8 | Int(bytes[p + 1])
            let rdlength = Int(bytes[p + 8]) << 8 | Int(bytes[p + 9])
            let rdataStart = p + 10
            guard rdataStart + rdlength <= bytes.count else { break }
            if type == 1 && rdlength == 4 {      // A 记录 = IPv4
                let ip = "\(bytes[rdataStart]).\(bytes[rdataStart+1]).\(bytes[rdataStart+2]).\(bytes[rdataStart+3])"
                result.append((ip: ip, domain: domain))
            } else if type == 28 && rdlength == 16 {   // AAAA 记录 = IPv6
                result.append((ip: formatIPv6(Array(bytes[rdataStart..<(rdataStart + 16)])), domain: domain))
            }
            offset = rdataStart + rdlength
        }
        return result
    }

    /// appex 用的一站式入口：给一个 IP 包，如果它是 DNS 响应就解析出 (假IP, 域名) 映射，否则空。
    public static func mappingsFromIPPacket(_ packet: [UInt8]) -> [(ip: String, domain: String)] {
        guard let dns = dnsPayloadFromDNSResponse(packet) else { return [] }
        return parseResponse(dns)
    }

    /// 若 IP 包是 IPv4 的 DNS 响应（UDP 源端口 53），返回其中的 DNS 报文；否则 nil。
    static func dnsPayloadFromDNSResponse(_ packet: [UInt8]) -> [UInt8]? {
        guard packet.count >= 20, packet[0] >> 4 == 4 else { return nil }   // IPv4
        let ihl = Int(packet[0] & 0x0F) * 4
        guard ihl >= 20, packet[9] == 17, packet.count >= ihl + 8 else { return nil }  // UDP
        let srcPort = Int(packet[ihl]) << 8 | Int(packet[ihl + 1])
        guard srcPort == 53 else { return nil }                            // DNS 响应从 53 来
        return Array(packet[(ihl + 8)...])                                 // 跳过 IP 头 + UDP 头(8)
    }

    /// 把 16 字节 IPv6 格式化成 Go net.IP.String 的压缩形式（xray access log 用的就是它），
    /// 例如 fc00:0:0:0:0:0:0:11 → "fc00::11"，这样才能和 access log 里的假 IPv6 对上。
    static func formatIPv6(_ b: [UInt8]) -> String {
        guard b.count == 16 else { return "" }
        var g = [Int]()
        for i in stride(from: 0, to: 16, by: 2) { g.append(Int(b[i]) << 8 | Int(b[i + 1])) }
        // 找最长的连续零段（≥2 段才压缩成 ::）
        var bestStart = -1, bestLen = 0, curStart = -1, curLen = 0
        for i in 0..<8 {
            if g[i] == 0 {
                if curStart == -1 { curStart = i; curLen = 1 } else { curLen += 1 }
                if curLen > bestLen { bestStart = curStart; bestLen = curLen }
            } else { curStart = -1; curLen = 0 }
        }
        if bestLen < 2 {
            return g.map { String($0, radix: 16) }.joined(separator: ":")
        }
        let head = (0..<bestStart).map { String(g[$0], radix: 16) }.joined(separator: ":")
        let tail = ((bestStart + bestLen)..<8).map { String(g[$0], radix: 16) }.joined(separator: ":")
        return head + "::" + tail
    }

    /// 读一个 DNS name（labels），返回 (域名, 名字之后的偏移)。
    /// 处理压缩指针（0xC0）——跟随指针读内容，但返回的偏移是指针之后（不是被指向处）。
    private static func readName(_ bytes: [UInt8], _ start: Int) -> (String, Int)? {
        var labels: [String] = []
        var offset = start
        var jumped = false
        var afterPointer = start
        var safety = 0
        while offset < bytes.count {
            safety += 1
            if safety > 128 { return nil }       // 防环
            let len = Int(bytes[offset])
            if len == 0 {
                offset += 1
                if !jumped { afterPointer = offset }
                return (labels.joined(separator: "."), afterPointer)
            }
            if len & 0xC0 == 0xC0 {              // 压缩指针
                guard offset + 1 < bytes.count else { return nil }
                if !jumped { afterPointer = offset + 2 }
                offset = (len & 0x3F) << 8 | Int(bytes[offset + 1])
                jumped = true
                continue
            }
            guard offset + 1 + len <= bytes.count else { return nil }
            labels.append(String(bytes: bytes[(offset+1)..<(offset+1+len)], encoding: .utf8) ?? "")
            offset += 1 + len
        }
        return nil
    }
}
