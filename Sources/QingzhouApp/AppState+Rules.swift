import Foundation
import QingzhouCore
import QingzhouRules

extension AppState {
    // MARK: - 规则

    /// 进入 xray routing 的用户规则全集：**自定义在前 = 自定义优先于远程**
    /// （xray routing.rules 按序 first-match）。
    public var effectiveUserRules: [Rule] { customRules + remoteRules }

    public func addCustomRule(_ rule: Rule) {
        customRules.append(rule)
        logger.info("Added custom rule \(rule.lineForm)", category: "rules")
        persist()
        reapplyForRulesChange()
    }

    public func removeCustomRule(_ rule: Rule) {
        customRules.removeAll { $0.id == rule.id }
        persist()
        reapplyForRulesChange()
    }

    /// 「一键规则」的结果，UI 据此不用再猜发生了什么（toast 文案已在方法内给出）。
    public enum QuickRuleOutcome: Equatable, Sendable {
        case added(domain: String)                                     // 新增了一条规则
        case retargeted(domain: String, from: RuleTarget, to: RuleTarget) // 同域名已有规则，原地改目标
        case unchanged(domain: String)                                 // 同域名同目标，什么都没做
        case notADomain(host: String)                                  // 裸 IP / 无点主机名，DOMAIN-SUFFIX 不适用
    }

    /// 域名分析 / 连接页的「加入直连 / 代理 / 拒绝」一键规则入口。
    ///
    /// - host 先归并成主域名（registrable domain），规则形如 `DOMAIN-SUFFIX,youtube.com,PROXY`；
    /// - 自定义规则里已有同域名的 DOMAIN / DOMAIN-SUFFIX 时**原地改目标**而不是重复添加
    ///   （改目标顺手升级成 SUFFIX，覆盖全部子域名）；同域名同目标则告知「已存在」；
    /// - 走 addCustomRule 同款持久化 + 热切换路径，VPN 在跑且 rule 模式时立即生效；
    /// - 每种结果都有 toast 反馈。
    @discardableResult
    public func quickAddDomainRule(forHost host: String, target: RuleTarget) -> QuickRuleOutcome {
        let domain = DomainAnalyzer.registrableDomain(host)
        guard !HostClassifier.isBareIP(host), domain.contains(".") else {
            showToast(L("「\(host)」不是域名，无法生成域名规则"))
            return .notADomain(host: host)
        }
        let targetName = Self.quickRuleTargetName(target)
        if let idx = customRules.firstIndex(where: {
            ($0.type == .domainSuffix || $0.type == .domain) && $0.value.lowercased() == domain
        }) {
            let old = customRules[idx].target
            guard old != target else {
                showToast(L("已有规则：\(customRules[idx].lineForm)"))
                return .unchanged(domain: domain)
            }
            customRules[idx].target = target
            customRules[idx].type = .domainSuffix
            logger.info("Retargeted custom rule \(customRules[idx].lineForm) (was \(old.rawValue))",
                        category: "rules")
            persist()
            reapplyForRulesChange()
            showToast(L("\(domain) 已从\(Self.quickRuleTargetName(old))改为\(targetName)，规则已生效"))
            return .retargeted(domain: domain, from: old, to: target)
        }
        addCustomRule(Rule(type: .domainSuffix, value: domain, target: target, comment: "一键添加"))
        showToast(L("已加入\(targetName)：\(domain)，规则已生效"))
        return .added(domain: domain)
    }

    /// 「可合并规则」建议的一键应用：删掉同域名的散规则，在第一条被替换规则的位置
    /// 插入一条 `DOMAIN-SUFFIX,主域名,目标`（保住 first-match 优先级），
    /// 走 addCustomRule 同款持久化 + 热切换路径。
    /// 建议已过期（规则被删/被改）时不动任何东西，返回 false。
    @discardableResult
    public func applyRuleMerge(_ suggestion: RuleMergeSuggestion) -> Bool {
        let ids = Set(suggestion.rules.map(\.id))
        // 过期检查：建议里的规则必须**全部**还在且目标未变 —— 部分失效时语义已经变了
        //（比如其中一条被改成了 REJECT），按过期处理让 UI 重新计算建议。
        let live = customRules.filter { ids.contains($0.id) }
        guard live.count == suggestion.rules.count,
              live.allSatisfy({ $0.target == suggestion.target }),
              let firstIdx = customRules.firstIndex(where: { ids.contains($0.id) }) else {
            showToast(L("规则已变化，建议已过期"))
            return false
        }
        customRules.removeAll { ids.contains($0.id) }
        let merged = Rule(type: .domainSuffix, value: suggestion.domain,
                          target: suggestion.target, comment: "合并自 \(suggestion.rules.count) 条规则")
        customRules.insert(merged, at: min(firstIdx, customRules.count))
        logger.info("Merged \(suggestion.rules.count) rules into \(merged.lineForm)", category: "rules")
        persist()
        reapplyForRulesChange()
        showToast(L("已合并 \(suggestion.rules.count) 条为 \(merged.lineForm)，规则已生效"))
        return true
    }

    private static func quickRuleTargetName(_ t: RuleTarget) -> String {
        switch t {
        case .proxy:  return L("代理")
        case .direct: return L("直连")
        case .reject: return L("拒绝")
        }
    }

    /// 规则集变了：VPN 在跑且是 rule 模式时热切换，让新规则立即对真实流量生效。
    /// global / direct 模式不吃规则，改规则不值得为此断流重启隧道。
    func reapplyForRulesChange() {
        guard settings.proxyMode == .rule else { return }
        // 没跑时 reapplyRunningTunnel 内部 guard 直接返回
        Task { await reapplyRunningTunnel() }
    }

    /// 下载完整版 geo 数据；成功后走规则变更同款热切换 —— 扩展重启时发现 App Group
    /// 里的完整版，datDir 切过去并解锁外国 GEOIP 码规则，用户不用手动关开 VPN。
    public func downloadFullGeoData() async {
        let ok = await geoData.downloadFullGeoIP()
        if ok {
            logger.info("完整版 geo 数据下载完成（来源：\(geoData.info?.sourceName ?? "?")）", category: "geo")
            reapplyForRulesChange()
        } else if case .failed(let message) = geoData.phase {
            logger.error("完整版 geo 数据下载失败：\(message)", category: "geo")
        }
    }

    public func currentRuleEngine() -> RuleEngine {
        RuleEngine(rules: customRules + remoteRules)
    }
}
