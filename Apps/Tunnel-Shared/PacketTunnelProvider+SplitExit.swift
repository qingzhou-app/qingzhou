import Foundation
import os.log
import QingzhouCore
import XrayConfig
import XrayCore

extension PacketTunnelProvider {
    /// 从 providerConfiguration 解出分流方案的两个节点。
    ///
    /// 语义刻意严格：
    /// - `splitExit` 不是 true → 返回 nil，走原有单节点路径（老配置不受影响）；
    /// - `splitExit` 是 true 但任一节点解不出来 / 缺失 → **抛错**，绝不回退到单节点。
    ///   回退等于「海外出口变成从本机直连的住宅代理」——国内连不上，而且会把真实 IP
    ///   暴露给住宅服务商。宁可连不上并告诉用户原因。
    func resolveSplitExit(providerConfig: [String: Any]?) throws -> SplitExitNodes? {
        let enabled = (providerConfig?["splitExit"] as? NSNumber)?.boolValue
            ?? (providerConfig?["splitExit"] as? Bool) ?? false
        guard enabled else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func decode(_ key: String) throws -> Node {
            guard let raw = providerConfig?[key] as? String, !raw.isEmpty,
                  let data = raw.data(using: .utf8) else {
                throw NSError(domain: "com.sbraveyoung.qingzhou.tunnel", code: 1010,
                              userInfo: [NSLocalizedDescriptionKey: "分流方案缺少 \(key)"])
            }
            do { return try decoder.decode(Node.self, from: data) }
            catch {
                throw NSError(domain: "com.sbraveyoung.qingzhou.tunnel", code: 1011,
                              userInfo: [NSLocalizedDescriptionKey: "分流方案的 \(key) 无法解析：\(error.localizedDescription)"])
            }
        }
        let exit = try decode("exitNodeJSON")
        let hop = try decode("hopNodeJSON")
        guard exit.host.lowercased() != hop.host.lowercased() || exit.port != hop.port || exit.protocolType != hop.protocolType else {
            throw NSError(domain: "com.sbraveyoung.qingzhou.tunnel", code: 1012,
                          userInfo: [NSLocalizedDescriptionKey: "海外出口与跳板是同一个节点，会绕成死循环"])
        }
        os_log("split-exit: exit=%{public}@ hop=%{public}@",
               log: log, type: .default, exit.protocolType.rawValue, hop.protocolType.rawValue)
        return SplitExitNodes(exit: exit, hop: hop)
    }

    func resolveSplitExitPolicyGroups(providerConfig: [String: Any]?) throws -> [SplitExitPolicyGroup] {
        guard let raw = providerConfig?["splitExitPolicyGroupsJSON"] as? String, !raw.isEmpty else {
            return []
        }
        guard let data = raw.data(using: .utf8) else {
            throw NSError(domain: "com.sbraveyoung.qingzhou.tunnel", code: 1015,
                          userInfo: [NSLocalizedDescriptionKey: "分流策略组配置编码无效"])
        }
        do {
            return try JSONDecoder().decode([SplitExitPolicyGroup].self, from: data)
        } catch {
            throw NSError(domain: "com.sbraveyoung.qingzhou.tunnel", code: 1015,
                          userInfo: [NSLocalizedDescriptionKey: "分流策略组无法解析：\(error.localizedDescription)"])
        }
    }

    /// 读主 App 更新好的国内名单（direct.txt / cncidr.txt）。
    ///
    /// 主 App 写入 `split-exit-lists.json` 时已由 `SplitExitListsUpdater` 按内存预算
    /// （`SplitExitListsLimits`）完成采样裁剪，扩展侧直接全量加载即可，不再重复截断；
    /// 未入表的国内域名/IP 仍由内置 `geosite:cn` / `geoip:cn` 兜底。
    func loadSplitExitLists() -> SplitExitPlan.Lists {
        guard let dir = TunnelAppGroup.ensureWorkingDirectory() else {
            os_log("split-exit: App Group 不可用 → 名单只用 geosite/geoip", log: log, type: .error)
            return .init()
        }
        let url = dir.appendingPathComponent(SplitExitListsFile.fileName)
        guard let data = try? Data(contentsOf: url),
              let lists = SplitExitListsFile.decode(data) else {
            os_log("split-exit: 未找到名单文件 → 名单只用 geosite/geoip", log: log, type: .default)
            return .init()
        }
        os_log("split-exit: 已加载名单 domains=%d keywords=%d cidrs=%d",
               log: log, type: .default,
               lists.domains.count, lists.domainKeywords.count, lists.cidrs.count)
        return .init(cnDomains: lists.domains,
                     cnDomainKeywords: lists.domainKeywords,
                     cnCIDRs: lists.cidrs)
    }

    /// 用分流方案生成完整 xray 配置。TUN 接口名与 access log 与老路径一致，
    /// 这样连接页、流量统计、域名账本都不用改。
    /// 注：TUN 仍接管 IPv6 默认路由（`NEIPv6Settings` `fd00:c0de::1`）以防真实网络泄漏，
    /// 而 `SplitExitPlan` 刻意使用 `UseIPv4` + 单一 IPv4 FakeDNS 池（见 `SplitExitPlan.dns()` 注释）。
    func composeSplitExit(_ nodes: SplitExitNodes,
                          accessLogPath: String?,
                          tunInterfaceName: String) throws -> String {
        let plan = SplitExitPlan(exitNode: nodes.exit, hopNode: nodes.hop,
                                 lists: loadSplitExitLists(),
                                 blockQUIC: self.blockQUIC,
                                 relay: guardRelay.withLock { $0 },
                                 policyGroups: splitExitPolicyGroups.withLock { $0 })
        return try plan.composeJSON(
            accessLogPath: accessLogPath,
            tunInterfaceName: tunInterfaceName,
            metricsPort: metricsPort,
            publicIPPort: publicIPPort.withLock { $0 }
        )
    }
}
