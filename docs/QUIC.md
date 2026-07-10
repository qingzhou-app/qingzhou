# 阻断 QUIC：症状、根因、解法与安全边界

> 2026-07-09 定稿。结论：**规则 / 全局代理模式下默认阻断 QUIC（reject UDP 443）**，
> 强制浏览器回退 TCP 443 走代理。这是刻意取舍而非疏漏 —— QUIC 经代理节点普遍走不通
> （真机确认），阻断后 YouTube 等 QUIC 重度站点恢复正常。
>
> **build 11 起：从单 bool 升级为智能三档 `Settings.quicPolicy`（`.auto` / `.alwaysBlock` /
> `.neverBlock`，默认 `.auto`）**。`.auto` 做**非对称**处理：hysteria2（QUIC 原生协议）节点先
> 放行并连接后实测 h3，走不通再挡；其余 TCP 基协议直接挡。见下方「§8 智能策略」。

## 1. 症状

规则 / 全局模式下：

- **YouTube 打不开 / 转圈 / 视频卡死**，同一时刻 `x.com`（Twitter）等非 QUIC 站点正常；
- 浏览器里**手动关掉 QUIC / 实验性 HTTP/3** 后 YouTube 立刻恢复 —— 已真机确认；
- 现象只在开了代理（rule / global）时出现，直连模式无此问题。

典型是「部分站点（恰好是 QUIC 重度站点：Google 系、YouTube、部分 CDN）整体不可用，
其余正常」。容易被误判成节点本身坏了或某地区被墙，实则是传输层协议问题。

## 2. 根因：QUIC over 代理不通

QUIC = HTTP/3 over **UDP 443**。浏览器对支持 HTTP/3 的站点（Google 系全量）会优先用 QUIC。

轻舟整机流量走 TUN → xray 路由。UDP 443 的 QUIC 包被路由到代理 outbound 后：

- 很多节点协议 / 出口对 **UDP 转发支持很差或根本不转发**（尤其只优化了 TCP 的节点）；
- 即便节点转发 UDP，中间链路对 UDP 443 的丢包 / 限速 / QoS 也远比 TCP 443 差；
- 于是 QUIC 握手超时 / 大量丢包，而浏览器**不会自动降级到 TCP**（它以为 QUIC 可用、
  只是网络差），页面就一直挂着。

对照：TCP 443（HTTP/2 over TLS）经同一节点稳定可达 —— 所以只要能逼浏览器走 TCP 就正常。

## 3. 解法：reject UDP 443，强制回退 TCP

在 `XrayConfigComposer.buildRouting` 的 **rule / global** 模式路由里，**紧跟在
DNS(udp 53→dns-out)规则之后**插入一条：

```json
{ "type": "field", "network": "udp", "port": 443, "outboundTag": "reject" }
```

`reject` = blackhole outbound。UDP 443 被直接拒 → 浏览器发现 QUIC 不可用 →
**自动回退 TCP 443（HTTP/2）** → 走代理正常。

位置要点（first-match）：
- 必须在 catch-all「tcp,udp→proxy」/ 用户规则**之前**，否则 UDP 443 先被吞去代理；
- 必须在 DNS 拦截规则**之后**，不能影响 `udp 53 → dns-out`（fakedns 的命脉）。

**`.direct` 模式不加**：直连无代理，QUIC 直连本就正常，加了反而改变直连行为（无意义且有害）。

默认阻断（`.auto` 对绝大多数 TCP 基节点 = 挡）：绝大多数用户用的节点 UDP 能力一般，
默认阻断才是「开箱即通」的正确缺省。迁移：旧 `blockQUIC` bool 字段解码忽略（build 10 仅内测机、
无正式用户），`quicPolicy` 缺字段 / 未知档位 `(try? decode) ?? .auto`。

## 4. 为什么安全（不误伤节点连接本身）

**关键：阻断 UDP 443 只作用于 TUN 进来、经路由规则决策的「用户流量」，
不影响节点自身的出网连接。**

- **hysteria2（QUIC 协议节点）不受影响**：hysteria2 跑在 UDP 上，但节点的 dial 是
  **outbound handler 自身的出网**（xray 直接向节点服务器发包），**不经 TUN、不吃 routing
  规则**。routing 的 UDP 443 reject 规则只对「从 tun-in 进来、要决定去哪个 outbound」的
  流量生效；节点握手不在这条链路上。所以开着阻断，hysteria2 / 任何 QUIC 型节点照常连。
- **DoQ（DNS over QUIC，UDP 853）不受影响**：规则限定 `port: 443`，853 不匹配。
- **DNS（udp 53）不受影响**：reject 规则排在 `udp 53 → dns-out` 之后，fakedns 照常触发。

## 5. 代价

- **失去 QUIC 传输优化**（0-RTT、连接迁移、更好的多路复用抗丢包）—— 但这些优化在
  「经代理」场景本就基本无意义（额外一跳 + 节点侧 UDP 劣化早已吃掉 QUIC 的收益），
  回退 TCP 443 的实际体验反而更稳。
- 对 UDP 转发能力**很好**的节点，阻断会让本可用的 QUIC 白白降级到 TCP。这类用户可在
  「设置 → 代理 → 阻断 QUIC」选 **强制关闭** 放行 QUIC（或用默认 `.auto` 让 hysteria2 节点自动实测放行）。

## 6. 类似问题（另一类，不由本开关兜底）

依赖 UDP 的应用（在线游戏、WebRTC 音视频、VoIP、部分 VPN-in-VPN）在**不支持 UDP 转发
的节点**上仍可能不通 —— 那是节点 UDP 转发能力的问题，与本开关是两码事：

- 本开关只处理 **UDP 443（QUIC/HTTP/3）**，且做法是「拒掉逼其回退 TCP」——
  游戏 / WebRTC 没有 TCP 回退路径，拒了就是断，所以不在本开关覆盖范围；
- 若用户的节点 UDP 能力好、又需要 QUIC / UDP 应用，把策略选 **强制关闭** 即可放行 UDP 443 给代理；
- 根治 UDP 应用要靠「选支持全量 UDP 转发的节点」，属于节点能力范畴，非路由配置能解决。

## 7. 实现落点

- `Sources/QingzhouCore/QUICPolicy.swift` — `QUICPolicy` 枚举 + `QUICPolicyResolver.shouldBlock`
  （三档 → 有效阻断值纯逻辑）+ `QUICProbeDecision.shouldMarkBroken`（h3 探测结果 → 是否判坏）
- `Sources/QingzhouCore/Settings.swift` — `quicPolicy: QUICPolicy`（默认 `.auto`，Codable 迁移
  `(try? decode) ?? .auto`，旧 `blockQUIC` bool 忽略）
- `Sources/XrayConfig/XrayConfigComposer.swift` — `buildRouting` / `compose` 的 `blockQUIC: Bool`
  参数**签名不变**（build 10 起）；由调用方传入 resolver 算好的有效值
- `Sources/QingzhouApp/VPNTunnelManager.swift` — `configure` 写 `providerConfig["blockQUIC"]`
  （键名不变，值 = 有效阻断）
- `Sources/QingzhouApp/AppState.swift` — `effectiveBlockQUIC(for:)` 算有效值；3 处 compose 调用点
  （startTunnel / 全量重配 / 原地换出口）改传有效值；`runningBlockQUIC` 记录在跑 routing 的有效值
  用于原地换出口的 routing 一致性判断；`probeQUICForCurrentNodeIfNeeded` / `probeHTTP3NegotiatedProtocol`
  HTTP/3 实测；`quicPolicyBinding` / `setQUICPolicy` 改档热生效
- `Apps/Tunnel-Shared/PacketTunnelProvider.swift` — **不改**：仍读 `providerConfig["blockQUIC"] as? Bool`
  存实例属性，startTunnel / reconfigure / performTest 三个 compose 调用点复用（三档语义全在主 App 收敛）
- `Sources/QingzhouApp/SettingsView.swift` — 代理段 Picker「阻断 QUIC：自动 / 强制开启 / 强制关闭」

## 8. 智能策略（`.auto` + 实测探测）—— build 11

单 bool「一刀切阻断」对 hysteria2 这类 **QUIC 原生协议**节点是误伤：它们的出口本就以 UDP/QUIC
转发为强项，挡掉 UDP 443 反而把它们最擅长的传输降级。于是 `.auto` 做**非对称**处理：

### 三档语义

| 档位 | 语义 |
|---|---|
| `.auto`（默认） | hysteria2 节点**先放行** + 连接后实测 h3，走不通再挡；其余协议直接挡 |
| `.alwaysBlock`（强制开启） | 所有节点、所有情况恒挡 UDP 443 → 强制回退 TCP |
| `.neverBlock`（强制关闭） | 所有节点恒放行 QUIC（UDP 转发能力好的自建节点用） |

有效阻断值 = `QUICPolicyResolver.shouldBlock(policy:protocolType:knownBrokenOnThisNode:)`，
在**主 App**每个 compose 调用点算出后经 `providerConfiguration["blockQUIC"]`（bool，键名不变）
下发。扩展侧 routing 仍只吃一个 bool —— 三档 + 探测的复杂度全部收敛在主 App，数据面零改动。

### 非对称探测（hysteria2 放行 + 实测；TCP 基节点直接挡）

- **TCP 基协议**（trojan / vmess / vless / shadowsocks）：`.auto` 下**直接挡**，不探测 ——
  它们 UDP 转发普遍差，探测只是徒增一跳成本和一次可能的重配。
- **hysteria2**：`.auto` 下**先放行**，隧道连上 / 换到该节点后，主 App 用 `URLSession` 对已知
  HTTP/3 端点（`cloudflare-quic.com`，备 `google/generate_204`）发一个轻请求：
  - `URLRequest.assumesHTTP3Capable = true`（iOS15+/macOS12+，目标系统均可用）允许**首个请求**
    就尝试 h3，无需先收 Alt-Svc 先验；
  - 从 `URLSessionTaskMetrics.transactionMetrics.last?.networkProtocolName` 读回**实际协商到**
    的协议：`"h3"` = QUIC 真能跑（该节点确实转发 UDP）→ 保持放行，什么都不做；
  - 非 h3（回退 `"h2"`/`"http/1.1"` 或整体失败 → nil）= 该 hysteria2 节点没转发 UDP →
    标记该节点（by `identityFingerprint`）QUIC 实测坏 + 触发**一次** `reapplyRunningTunnel(.full)`，
    让 routing 带上 `blockQUIC=true`。
  - 决策阈值抽成纯函数 `QUICProbeDecision.shouldMarkBroken`（TDD）；URLSession 调用本身靠编译 + 真机。

### reconfigure-on-fail 的一次性代价

判坏后的整实例重配是一次 stop→start，会有**短暂断流**（同热切换）。这是**一次性**代价：
标记落进内存 Set 后，同会话内该节点不再探测（守卫 `!knownBroken` 直接跳过），也不会反复重配。

### per-node 内存缓存（`quicKnownBrokenNodes`）

- key 用 `Node.identityFingerprint`（订阅刷新后 UUID 可能变、指纹稳定）；
- **仅本会话内存**：不落盘、不上 iCloud —— 换会话重探一次可接受，避免一次网络抖动把节点永久钉死。

### 原地换出口的 routing 一致性（`runningBlockQUIC`）

原地换出口（`nodeOnly` / libXray `SwitchOutbound`）**只换 outbound、不重建 routing**。而有效阻断
值现在随节点协议 / 实测坏标记变化（trojan 挡 ↔ hysteria2 放行）。若新节点有效值与当前 routing 所用的
`runningBlockQUIC` 不一致，原地换会留下**过期的 QUIC 路由**（放行档位下 trojan 漏 UDP443，或阻断
档位下 hysteria2 的 h3 被自家路由挡死→被误判坏）。故：**不一致时把 `nodeOnly` 升级为全量重启**重建
routing，一致时才走零断流快路径。用现有 routing-rule + reconfigure 机制，**不碰 socketpair 桥热路径**。

## 9. 状态可视化 —— 设置页「当前 QUIC 运行态」

`.auto` 的「放行 → 实测 → 通过 / 改挡」全在后台发生，用户（和真机验收）完全看不见。
于是设置页 QUIC 策略选择器下方加一行**当前运行态**说明（footer 轻量形态，**隧道开着才显示**）：

| 运行态（`QUICRuntimeStatus`） | 状态行 |
|---|---|
| `.forcedBlock` | 当前：已阻断 QUIC（策略强制开启） |
| `.forcedAllow` | 当前：放行 QUIC（策略强制关闭） |
| `.autoBlockedTCPBased` | 当前：已阻断 QUIC（TCP 系协议节点） |
| `.autoProbing` | 当前：暂放行 QUIC，HTTP/3 实测中… |
| `.autoProbePassed` | 当前：放行 QUIC（HTTP/3 实测通过） |
| `.autoBrokenBlocked` | 当前：已阻断 QUIC（实测不通，已自动改挡） |

实现要点（**纯观测，探测 / 阻断语义零改动**）：

- 状态推导是**纯函数** `QUICRuntimeStatusResolver.status(policy:protocolType:knownBrokenOnThisNode:probePassedOnThisNode:)`
  （`Sources/QingzhouCore/QUICPolicy.swift`，全输入空间单测覆盖）；`QUICRuntimeStatus.isBlocking`
  与 `QUICPolicyResolver.shouldBlock` 的逐点一致性有不变量测试钉死 —— 状态行绝不能骗人。
- 「实测通过」来自新增的观测集合 `AppState.quicProbePassedNodes`（探测 OK 且仍是同一节点在跑时记录；
  每轮探测开始时移除该节点回到「实测中」）。它**不参与**阻断决策 —— 决策仍只认
  `quicKnownBrokenNodes` / `QUICPolicyResolver`。
- UI 入口 `AppState.quicRuntimeStatus`（隧道没开 / 无当前节点时 nil = 不显示）+
  `SettingsView.quicStatusText`（文案映射），四语在 `Apps/App-Shared/Localizable.xcstrings`。
