# Shadowrocket 指南与轻舟功能对照

核对日期：2026-10-30。用途：产品决策清单，不代表新增功能已经获准开发。

## 范围与判断口径

- 对照来源：[LOWERTOP/Shadowrocket 使用手册](https://github.com/LOWERTOP/Shadowrocket/blob/main/README.md)，本次读取 README blob SHA：`eeab58d98d60c060eccae68350a1ede168fddb32`；同时检查了仓库的 [lazy_group.conf](https://github.com/LOWERTOP/Shadowrocket/blob/main/lazy_group.conf)。该手册是社区项目，混合正式版和 TestFlight 能力，不能视为所有版本的官方保证。
- 轻舟以当前源码中的“模型→配置转换→隧道执行→用户入口”判断，不把底层 Xray 支持、解析器接受、未启用的实验代码算作完整支持。
- “已有”表示有实现，并不替代每项真机验收。build 37 是已安装基线；当前 build 38 的双栈/DNS 修复仍为工作区改动，未安装、未完成真隧道验收。
- 按用户要求停止 VPN 切换、重启及相关主动测试；后续直连复测由用户手动进行。本轮仅核对、编写文档。

## 一、已有的基础与特色能力

| 编号 | 能力 | 轻舟实际范围 |
|---|---|---|
| A01 | 常用节点协议 | Trojan、Shadowsocks、VMess、VLESS、Hysteria2；具体传输参数仍以转换器支持范围为准。 |
| A02 | 节点导入与分享 | 分享链接、二维码、订阅；Clash YAML 主要读取节点，不能据此宣称支持完整 Clash 配置。 |
| A03 | 订阅维护 | 更新、定时刷新、节点合并、异常提示、订阅用量展示。 |
| A04 | 三种路由模式 | 规则、全局代理、直连；build 37 已实现无选中节点启动直连的路径，相关交互验收单独保留。 |
| A05 | 基础分流规则 | 域名精确/后缀/关键词、IPv4/IPv6 CIDR、GEOIP、FINAL；动作是直连、代理、拒绝。 |
| A06 | 规则管理 | 自定义规则、搜索、远程规则源、命中统计；统计不是任意配置的完整语义验证器。 |
| A07 | 测速与诊断 | TCP 探测、真实代理请求探测、可设置代理测试目标、错误分类、脱敏诊断报告；UDP 型协议不直接用 TCP 失败判坏。 |
| A08 | 全局节点择优 | 综合延迟、稳定性、测速表现和倍率偏好，含地区偏好、失败冷却、切换滞后及选择解释；作用于当前全局代理节点。 |
| A09 | 流量可观测性 | 实时速率、连接、域名分析、代理/直连拆分、本次 VPN 会话/日/月账本与导出。历史存在保留期限、容量上限和归因边界，不是无限期抓包。 |
| A10 | 两路公网 IP | 分别展示节点出口与物理直连出口；已有修复与验收记录，不能用这两项替代所有网站可达性测试。 |
| A11 | 同步及恢复 | iCloud 配置同步、设置内手动恢复；已处理启动反复提醒恢复问题。 |
| A12 | 自动化和桌面体验 | App Intents/快捷指令、专注模式入口、启动自动连接、macOS 指定 App 启动触发、定时关闭、小组件/Live Activity、菜单栏。各平台入口不同。 |

这些是轻舟已有能力，不等于每一项都比 Shadowrocket 更强；本报告未进行两款 App 的同条件性能测试。

## 二、部分支持或语义不等价

| 编号 | 能力 | 现状与缺口 | 决策性质 |
|---|---|---|---|
| P01 | 自动切换 / 故障回退 | 有自动择优；另有可选故障提醒及用户触发操作，但未形成可独立配置的 fallback 策略组。不能把周期择优等同于请求失败即时回退。 | 扩展能力 |
| P02 | DNS | 已有按模式生成的 DNS、FakeDNS、域名嗅探和 DNS 路由；没有完整的用户 DNS 配置页。当前双栈改动待验收。 | 扩展能力 + 待验收 |
| P03 | 远程规则集 | 有一个远程规则文本源；没有多 RULE-SET/DOMAIN-SET 引用、独立更新和策略绑定体系。 | 扩展能力 |
| P04 | PROCESS-NAME / USER-AGENT | 模型及解析层接受，但 Xray 路由转换器直接忽略；macOS 的进程名规则入口也不能证明实际生效。来源 App 标注实验功能目前关闭，且标注本身不等于路由。 | **现有语义缺口** |
| P05 | no-resolve 等扩展参数 | 逗号后附加内容被保存为 comment，未执行 no-resolve 语义；不能承诺导入后行为相同。 | **现有语义缺口** |
| P06 | QUIC 控制 | 有开关/策略；规则或全局模式中阻断 UDP 443 的规则在普通用户规则之前，不能等同“仅阻断走代理的 QUIC”。纯直连模式跳过该阻断。 | 范围差异 |
| P07 | 温和切换 | 兼容条件下的节点变更有原地切换路径；模式、规则、QUIC 变化不保证保留所有既有连接。 | 扩展能力 |
| P08 | 按需连接 | 有系统 On-Demand 保持/重连；定时关闭会话会禁用它以避免自动重连。没有用户配置的 Wi-Fi/蜂窝/SSID 条件矩阵。 | 扩展能力 |
| P09 | 自动化接口 | 已有快捷指令/App Intents；未找到完整的 URL Scheme 操作体系。 | 扩展能力 |
| P10 | GEOIP | 有地理库使用与资源下载/回退；没有完整的自定义数据库来源、ASN 规则及配套管理。 | 扩展能力 |
| P11 | 测试工具 | 已有 TCP/真实代理探测；没有同等的 ICMP 测试入口，也没有输入任意目标后逐步解释规则命中全过程的调试器。 | 扩展能力 |

P04/P05 应先明确“实现该语义”还是“拒绝/明确提示不支持”。这是功能真实性问题，不应与可选的大型新功能混在一起。

## 三、尚未支持，供逐项选择

### 路由与出口组织

| 编号 | 待选功能 | 用户可以获得什么 | 主要依赖 |
|---|---|---|---|
| N01 | 命名策略组 / 按服务指定出口 | Claude 固定一组、视频走另一组、下载直连；不同业务同时使用不同出口。 | RuleTarget、配置生成和运行态从单代理扩展为多出站。 |
| N02 | 组内手选、自动测速、故障回退 | 为每组分别设节点范围、选择规则、检测目标和切换条件。 | N01；复用现有择优逻辑但要隔离各组状态。 |
| N03 | 组内负载均衡 / 随机选择 | 把不同连接分配到多个节点；不是单个下载自动叠加所有节点带宽。 | N01；需定义会话粘性和故障处理。 |
| N04 | 嵌套策略组 | 组合地区组、订阅组、服务组，减少重复维护。 | N01；循环引用校验和选择解释。 |
| N05 | 代理链 / 前置代理 | 经中转节点到最终出口，或使用现有 HTTP/SOCKS 网关。 | 多出站拓扑、协议约束和链路诊断。 |
| N06 | 网络场景 | 家庭 Wi-Fi、公司 Wi-Fi、蜂窝自动使用不同配置/出口。 | 网络条件、系统权限与确定性切换策略。 |

### 规则、配置及订阅

| 编号 | 待选功能 | 用户可以获得什么 | 主要依赖 |
|---|---|---|---|
| N07 | 多配置档与配置切换 | 工作、游戏、旅行分别维护规则、DNS、策略组；当前设置为单套。 | 配置模型、迁移、实际生效状态。 |
| N08 | 完整配置导入/预览/组合 | 导入 `.conf` 后显示支持和不支持项；支持扩展配置/合并时清楚展示最终结果。 | 专用解析器及兼容规范；不能复用节点导入就声称完成。 |
| N09 | 多远程规则集 | 按用途订阅不同规则集、单独更新及绑定策略。 | 规则源模型、缓存、更新失败处理。 |
| N10 | 高级规则条件 | 域名通配符、端口、ASN、逻辑 AND/OR/NOT 等。 | 各条件从解析到隧道逐一实现；协议/URL/UA 的可见性不同。 |
| N11 | 规则测试与命中解释 | 输入域名/IP/端口，解释命中顺序及 DNS 影响，定位“为什么走代理”。 | 与实际隧道一致的评估逻辑，不能只做近似模拟。 |
| N12 | 更多拒绝动作 | 针对请求选择丢弃、拒绝或特定 HTTP 响应。 | 网络层与 HTTP 层分别实现，不能仅扩充枚举。 |
| N13 | 订阅正则筛选/转换脚本 | 自动保留或排除匹配节点、重命名、转换订阅内容。 | 普通列表搜索/手动排除不等同此功能；脚本需独立运行边界。 |

### DNS 与隧道网络

| 编号 | 待选功能 | 用户可以获得什么 | 主要依赖 |
|---|---|---|---|
| N14 | 用户可配置 DNS | 设置直连/代理/节点解析/备用 DNS，选择加密传输。 | 配置校验、启动引导、防解析循环与错误回退。 |
| N15 | Hosts / 按域名指定 DNS | 对特定站点固定 IP 或使用指定解析器。 | 地址族、TTL、优先级和 FakeDNS 协调。 |
| N16 | DNS 经指定代理 / ECS 等 | 对解析请求的出口与位置信息进行更细控制。 | 多出站、解析隐私及服务兼容性。 |
| N17 | FakeDNS 例外 / 非 A、AAAA 记录策略 | 为不兼容服务保留真实地址，处理 HTTPS/SVCB 等记录。 | DNS 与 TUN 映射一致性；当前没有用户入口。 |
| N18 | DNS 专用日志 | 查看查询、答案、耗时、缓存与解析器路径，定位解析问题。 | 结构化 DNS 事件和有界保留；普通连接日志不足以替代。 |
| N19 | STUN 控制 | 对 WebRTC/STUN 流量单独处理。 | UDP 识别与行为设计；现有 QUIC 阻断不能替代。 |
| N20 | UDP 不支持时的明确策略 | 用户选择拒绝或直连等行为，避免隐式结果。 | 按协议能力进行路由和提示。 |
| N21 | 高级隧道路由/兼容开关 | 配置纳入/排除路由、局域网及系统服务例外。 | 系统 API、平台限制、回滚与回归矩阵。 |

### 内容处理、共享与扩展协议

| 编号 | 待选功能 | 用户可以获得什么 | 主要依赖 |
|---|---|---|---|
| N22 | HTTPS MITM 与证书管理 | 在用户授权范围内读取和修改 HTTPS 内容。 | 完整证书信任与 HTTP 代理子系统；当前没有。 |
| N23 | URL / 请求响应头 / 正文重写 | 自定义重定向、删改字段和内容。 | HTTPS 内容通常依赖 N22；不是普通域名分流。 |
| N24 | 本地响应映射 | 用本地文件/响应替代特定请求结果。 | HTTP 处理和资源管理；HTTPS 通常依赖 N22。 |
| N25 | JavaScript 自动化引擎 | 请求响应、事件、定时任务等扩展逻辑。 | JS 运行时、权限、资源限制、生命周期与调试。 |
| N26 | 模块与远程模块更新 | 将规则、重写、脚本等打包成可开关的功能模块。 | 合并优先级、兼容校验；依赖具体模块使用的子功能。 |
| N27 | 局域网/热点代理共享 | 让其他设备经本机 HTTP/SOCKS 代理上网。 | 对外监听、认证、访问范围、平台后台约束；现有 loopback 服务不算共享。 |
| N28 | Tailscale 集成 | 私网访问、子网路由和出口节点等工作流。 | 独立网络栈/身份体系及与 VPN 的共存设计。 |
| N29 | 更多节点协议 | WireGuard、TUIC、SSH、HTTP/SOCKS、AnyTLS 等；需按实际需求逐协议选择。 | 各协议的引擎、导入、配置、测速与真机覆盖，不能一次勾选即视为全部支持。 |

说明：普通 iOS VPN 的“某 App 分流”常实际指该服务的域名/IP 规则，不能据此承诺任意进程级分流。指南中的隐藏 VPN 图标属于特殊系统行为，不列为轻舟常规功能候选；也未将皮肤、旗帜样式等细枝末节逐个计数。

## 四、结合现有问题，应如何理解这些差距

- **LM Studio 下载耗流量**：已有自定义直连规则可以解决指定域名；N11 可解释为何走代理，N09 可降低维护成本。下载实际落点可能是重定向/CDN/其他模型托管域名，仅匹配入口域名不一定覆盖所有下载。
- **AI 服务固定出口**：当前地区偏好和全局择优不能让 Claude 与视频同时固定到不同节点。需要 N01，再选择是否加入 N02。固定出口有助于减少出口变化，但不能保证第三方平台永不封号。
- **VPN 直连与关闭 VPN 行为不同**：隧道内仍涉及 DNS、FakeDNS、地址族和转发栈；“直连”不代表完全绕过 VPN。当前 build 38 修复需要独立验收，不能由这份功能清单判定解决。
- **完整导入 Shadowrocket 懒人配置**：当前不支持。节点解析成功、部分规则导入成功，都不能证明 DNS、策略组和扩展参数生效；应明确提示缺失能力。
- **重写/脚本生态**：N22–N26 是一整套内容处理子系统，与当前以连接转发和可观测性为主的轻舟差距最大，不能当作增加几个设置开关。

## 五、源码证据索引

| 结论 | 关键源码 |
|---|---|
| 协议和导入范围 | [ProxyProtocol.swift](../Sources/QingzhouCore/ProxyProtocol.swift)、[ClashConfigParser.swift](../Sources/QingzhouProtocols/ClashConfigParser.swift) |
| 规则类型、目标及实际转换 | [Rule.swift](../Sources/QingzhouCore/Rule.swift)、[RuleParser.swift](../Sources/QingzhouRules/RuleParser.swift)、[RoutingRuleConverter.swift](../Sources/XrayConfig/RoutingRuleConverter.swift) |
| DNS、QUIC、单代理出站 | [XrayConfigComposer.swift](../Sources/XrayConfig/XrayConfigComposer.swift) |
| 单远程源和规则 UI | [RemoteRulesFetcher.swift](../Sources/QingzhouApp/RemoteRulesFetcher.swift)、[RulesView.swift](../Sources/QingzhouApp/RulesView.swift)、[Settings.swift](../Sources/QingzhouCore/Settings.swift) |
| 择优及稳定性 | [NodeScorer.swift](../Sources/QingzhouCore/NodeScorer.swift)、[NodeSelectionHysteresis.swift](../Sources/QingzhouCore/NodeSelectionHysteresis.swift)、[ProxySelectionRound.swift](../Sources/QingzhouApp/ProxySelectionRound.swift) |
| 功能开关及故障提醒 | [FeatureFlags.swift](../Sources/QingzhouApp/FeatureFlags.swift)、[AppState.swift](../Sources/QingzhouApp/AppState.swift) |
| 按需连接及重配 | [VPNTunnelManager.swift](../Sources/QingzhouApp/VPNTunnelManager.swift)、[PacketTunnelProvider.swift](../Apps/Tunnel-Shared/PacketTunnelProvider.swift)、[qingzhou_switch.go](../scripts/patches/libxray/qingzhou_switch.go) |
| 流量账本 | [DomainTrafficLedger.swift](../Sources/QingzhouCore/DomainTrafficLedger.swift)、[DomainTrafficView.swift](../Sources/QingzhouApp/DomainTrafficView.swift)、[流量分析边界](DOMAIN-TRAFFIC.md) |
| 自动化及网络观测 | [TunnelIntents.swift](../Sources/QingzhouApp/TunnelIntents.swift)、[FocusFilterIntent.swift](../Sources/QingzhouApp/FocusFilterIntent.swift)、[MeasurementNetworkObserver.swift](../Sources/QingzhouApp/MeasurementNetworkObserver.swift) |

## 六、决策记录

所有 N 项当前均为 **待用户决定**，没有默认批准。可按编号标记“支持 / 暂缓 / 不做”，对 P 项则选择“补齐语义 / 明确限制”。本轮没有因为该对照新增产品代码。
