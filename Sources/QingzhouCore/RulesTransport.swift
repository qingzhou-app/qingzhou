import Foundation

/// 主 App ↔ 隧道扩展 之间用户规则的传输编解码。
///
/// 为什么要压缩：规则走 `providerConfiguration`（落 VPN preferences plist）或
/// `sendProviderMessage`（XPC 消息），两者都有大小限制，而远程规则动辄几千条。
/// [Rule] JSON 化后 zlib 压缩（规则文本重复度高，压缩率 ~10:1），几千条规则
/// 压完只有几十 KB，正常情况都能内联；超大规则集由调用方降级为
/// 「写 App Group 文件传路径」（见 VPNTunnelManager.rulesPayload）。
///
/// 放在 QingzhouCore：主 App（QingzhouApp 包）和隧道扩展（Apps/Tunnel-Shared，
/// 只 link QingzhouCore/XrayConfig/XrayCore）都要用，QingzhouCore 是唯一公共底座。
public enum RulesTransport {

    public enum TransportError: Swift.Error {
        case corruptedPayload
    }

    /// [Rule] → JSON → zlib 压缩后的 Data。
    public static func encode(_ rules: [Rule]) throws -> Data {
        let encoder = JSONEncoder()
        // 规则不含 Date 字段，但统一 iso8601 与项目其他编码点保持一致习惯
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(rules)
        return try (json as NSData).compressed(using: .zlib) as Data
    }

    /// encode 的逆操作。数据损坏 / 不是合法 payload 时抛错（调用方降级为空规则集，
    /// 不能因为规则解不出来就让 VPN 起不来）。
    public static func decode(_ data: Data) throws -> [Rule] {
        let json: Data
        do {
            json = try (data as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw TransportError.corruptedPayload
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Rule].self, from: json)
    }
}
