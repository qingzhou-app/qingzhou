# 节点自动择优 — 算法沿革与现状

> 为什么留这份文档：择优算法迭代了五代，每一代都是被真实问题逼出来的。
> 后来者（包括未来的我们）改这块前，先看清楚每层解决什么、别把治过的病again。

## 沿革：五代算法，各治一种病

### 第 1 代：纯直连 TCP 握手延迟
全量节点测直连 TCP 三次握手 RTT（`TCPConnectLatencyProber`，NWConnection 到 host:port，
`.ready` 即记时；VPN 运行时绑物理接口绕开 utun），最低者当选。
**治**：有自动选节点这回事。
**病**：直连握手快 ≠ 走它上网快——出口绕路、超售、已被墙的"假快"节点频出。

### 第 2 代：经代理延迟精选（#11B，2026-07-03）
VPN 运行中，把直连结果为绿的候选**真实走一遍代理**（扩展起临时 xray 实例发 HTTP，
`pingNode`，串行 + 38MB 内存护栏），按端到端延迟精选。
**治**：第 1 代的"假快"节点。
**成本**：串行慢、只在 VPN 运行中可用，所以是"直连初筛 + 经代理精选"两段式。

### 第 3 代：倍率 tiebreaker（2026-07-05 机场兼容性批次）
`NodeRateParser` 从订阅元数据（`rate`/`倍率`/`multiplier`/`ratio`）或节点名
（`2x`/`0.5倍`/`日本-OS-1-:0.6`…）识别倍率；延迟"相当"（直连 ±30ms / 经代理 ±200ms
tieBand）时优先低倍率，识别不出按 1.0。
**治**：同样快的节点里白白烧高倍率流量。
**边界**：倍率只在 tieBand 内有话语权——41ms 的 0.5x 永远赢不了 32ms 的 2x。

### 第 4 代：黏性滞后 + 无感热切换（2026-07-06，de2c894 + f6c0e27）
换当前节点必须 `currentMs − bestMs ≥ max(50ms, currentMs×30%)`
（`autoSwitchWorthRestart`；当前节点本轮测速失败则无条件放行）。同批上了
libXray `SwitchOutbound` 热插拔，换节点走 nodeOnly 快路径不再全量重启隧道。
**治**：延迟抖动让最优者每轮易主 → 频繁切换 → 图标闪 + 断流几秒（用户两次投诉）。

### 第 5 代：多维打分（2026-07-07 拍板，P1 开发中）
`score = 0.45×延迟 + 0.30×稳定性 + 0.15×带宽 + 0.10×成本`，锚点归一；
新增每节点测量历史（环形 20 条）支撑稳定性维；切换要"分数领先 ≥8 且连续 2 轮"。
P2 接用户 Top 域名画像做测量目标 + 三档预设。完整设计见 [NODE-SCORING.md](NODE-SCORING.md)。
**治**：纯延迟维看不见的"延迟低但抖动大/失败率高"节点；倍率无法连续参与决策；
测量目标（Cloudflare）不代表用户真实访问。

## 不变的外层约束（每代都保留）

- **地区硬约束**：`preferredRegion` 优先圈定、`excludedRegions` 剔除（先过滤后选优）；
- **手动排除**：`isExcluded` 节点不进候选；
- **触发时机**：开 App / 定时（默认 30 分钟）/ 手动，`schedulerLoop` 统一调度；
- **黏性闸**：`autoSwitchWorthRestart`（第 4 代引入，第 5 代之上仍然叠加）。

## 关键代码索引（2026-07-07）

| 部件 | 位置 |
|---|---|
| 择优主流程 | `AppState.autoSelectBestNode`（AppState.swift ~1299） |
| 地区约束 | `pickBestRespectingRegions`（~1448） |
| 选优内核 | 第 4 代 `bestPreferringLowRate`（~1431）→ 第 5 代 NodeScorer |
| 黏性闸 | `autoSwitchWorthRestart`（~1423） |
| 直连测速 | `Sources/QingzhouSpeedTest/LatencyProber.swift` |
| 经代理测速 | `VPNTunnelManager.pingNode` → libXray Ping |
| 倍率解析 | `Sources/QingzhouCore/NodeRateParser.swift`、`Node.effectiveRate` |
