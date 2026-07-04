import Foundation
import QingzhouCore

/// SIP008 在线配置分发格式解析器（Outline / 部分 Shadowsocks 机场用）。
///
/// SIP008 是一份**整体 JSON**，不是分享链接列表，所以要在走 base64/明文链接路径之前单独识别。
/// 典型结构：
/// ```json
/// {
///   "version": 1,
///   "servers": [
///     { "id": "...", "remarks": "香港", "server": "1.2.3.4", "server_port": 8388,
///       "method": "aes-256-gcm", "password": "pw", "plugin": "", "plugin_opts": "" }
///   ]
/// }
/// ```
/// 每个 server 就是一个 Shadowsocks 节点。字段映射见 `parse`。
public enum SIP008Parser {

    public enum Error: Swift.Error, Sendable {
        case notSIP008          // 不是 JSON 对象 / 没有 servers 数组
    }

    /// 快速嗅探：trim 后以 `{` 开头。真正是不是 SIP008 由 `parse` 判定（能否 decode 出 servers 数组）。
    public static func looksLikeSIP008(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
    }

    /// 解析 SIP008 JSON。
    ///
    /// - 顶层必须是 JSON 对象且含 `servers` 数组，否则抛 `Error.notSIP008`（调用方据此 fall through 到别的格式）。
    /// - `servers` 存在（哪怕是空数组）就认定「格式已识别」；单个 server 坏了不致命，收进 `errors`，好的照收。
    /// - 字段映射（SIP008 spec）：
    ///   - `server` → host（必填）
    ///   - `server_port` → port（必填，接受数字或数字字符串）
    ///   - `method` → cipher（必填）
    ///   - `password` → password（必填）
    ///   - `remarks` / `tag` → name（缺则退化为 `host:port`）
    ///   - `plugin` / `plugin_opts` → 透传进 parameters（可选）
    public static func parse(_ text: String) throws -> (nodes: [Node], errors: [(name: String, reason: String)]) {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let dict = root as? [String: Any],
              let servers = dict["servers"] as? [[String: Any]] else {
            throw Error.notSIP008
        }

        var nodes: [Node] = []
        var errors: [(name: String, reason: String)] = []

        for (index, server) in servers.enumerated() {
            let label = (server["remarks"] as? String)
                ?? (server["tag"] as? String)
                ?? "servers[\(index)]"
            do {
                nodes.append(try node(from: server))
            } catch let e as FieldError {
                errors.append((label, e.reason))
            } catch {
                errors.append((label, "\(error)"))
            }
        }
        return (nodes, errors)
    }

    private struct FieldError: Swift.Error { let reason: String }

    private static func node(from server: [String: Any]) throws -> Node {
        guard let host = (server["server"] as? String), !host.isEmpty else {
            throw FieldError(reason: "缺少 server 字段")
        }
        guard let port = intValue(server["server_port"]) else {
            throw FieldError(reason: "缺少或非法的 server_port 字段")
        }
        guard let method = (server["method"] as? String), !method.isEmpty else {
            throw FieldError(reason: "缺少 method 字段")
        }
        // password 允许空串（个别 method 不需要），但字段本身要在
        guard let password = server["password"] as? String else {
            throw FieldError(reason: "缺少 password 字段")
        }

        let name: String
        if let remarks = (server["remarks"] as? String) ?? (server["tag"] as? String), !remarks.isEmpty {
            name = remarks
        } else {
            name = "\(host):\(port)"
        }

        var params: [String: String] = [:]
        if let plugin = server["plugin"] as? String, !plugin.isEmpty {
            params["plugin"] = plugin
        }
        if let pluginOpts = server["plugin_opts"] as? String, !pluginOpts.isEmpty {
            params["plugin-opts"] = pluginOpts
        }

        return Node(
            name: name,
            protocolType: .shadowsocks,
            host: host,
            port: port,
            password: password,
            cipher: method,
            parameters: params
        )
    }

    /// server_port 在规范里是数字，但个别机场会给成字符串，两者都接。
    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
