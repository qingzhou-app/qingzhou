# 健康触发的无感故障切换（Health-triggered Failover）— 设计

> 2026-07-08 立项。用户拍板:**扩展版**（app-dead 也有效）+ **保守**（检测+告警+一键切,
> 首版不做静默自动切）。回滚锚点 tag `checkpoint/pre-failover-build8`。
> 本文是设计存档 + 实现规格。红队失败模式全表见文末。

## 问题

节点在使用中挂掉（服务器死/被墙/账号到期），但还没到定时择优的采样点，网络就断了。
更糟:默认 `autoSelectTrigger == .onAppLaunch`,定时择优根本没开,不改设置的话节点挂了
**永不自动恢复**。而 App 被杀/切后台时,主 App 的任何监控都停摆——所以检测必须在**扩展**里。

## 核心事实

- **切换动作现成**:`SwitchOutbound` 热插拔 "proxy" outbound handler,毫秒级、零断流。缺的只是**检测**。
- **检测信号只能用 xray proxy per-outbound 计数**（`reportXrayOutboundStats`,每 2s）:
  判据 =「**proxy 上行还在涨、下行却持平**,持续 N 秒」。
  - ❌ 不用 TUN 层字节:FakeDNS 合成的假 IP 下行会污染它。
  - ❌ 不用 access log:它在「路由派发那刻」写 `accepted`,**死节点照样写**,dial 失败根本不进日志。
  - ❌ 不用「下行=0」单条件:空闲也是 0,必须「上行在涨」配对成立。

## 首版范围（保守 MVP）

**检测在扩展、告警到用户、切换由用户一键触发（不自动切数据面）。** 默认关（opt-in）。

```
扩展(每 2s):喂 NodeHealthDetector(proxy up/down 增量) 
  → 确认 .suspect(去抖 N 秒 + 各种门) 
  → 写 App Group node-health.json + 发一条本地通知(带冷却)「当前节点疑似故障,点此切换」
主 App(特性开 + 读到 suspect):
  → 连接页红色横幅 + 一键「切换到最优节点」(排除疑似死的那个,复用打分+switchNode)
  → 通知的动作按钮 → 同一切换
```

soak 证明误报率够低后,再单独评估「放开静默自动切」（届时补主动探测二次确认 + 熔断器）。

## 分层与放置

| 部件 | 放哪 | 理由 |
|---|---|---|
| 判死纯逻辑 `NodeHealthDetector` | QingzhouCore | 纯函数、可 TDD,扩展/主App 都能用 |
| 喂样本 + 发通知 + 写信号 | 扩展 PacketTunnelProvider | app-dead 才有效;字节本就在进程内数,被动信号零额外内存 |
| 候选列表(排好序) | 主 App 打分 → App Group | 打分/健康史在主 App;扩展只需「下一个候选」 |
| 告警 UI + 一键切 | 主 App | 用户发起、走现有 switchNode |
| 开关(默认关) | Settings + FeatureFlags | opt-in + 运行时 kill-switch |

## NodeHealthDetector 纯逻辑规格（TDD 重点）

输入:一串 `(proxyUplinkTotal, proxyDownlinkTotal, at)` 样本 + 事件(switch/restart → resetBaseline)。
输出:`.healthy` / `.suspect`。

必须满足（每条对应一个红队失败模式,见文末）:
- **配对判据**:仅当「上行增量 > 阈值 且 下行增量 ≈ 0」持续 ≥ `suspectSustainSeconds`(建议 8~12s)才 suspect。（F4/F19）
- **空闲不判**:上行也≈0 → healthy（是空闲不是死）。（F19）
- **去抖/迟滞**:单个采样窗失败不算;恢复侧也要迟滞,别抖动。（F3）
- **baseline 重置**:每次 switch/restart 后作废旧 baseline,设「判定空窗」直到新 baseline 就绪。（F5）
- **起手宽限**:connect/switch 后 `graceSeconds` 内不判定。（F7）
- **睡眠跳变**:样本间隔异常大（>阈值,=挂起）→ 丢弃该窗、重建 baseline,用单调时钟。（F8）
- **模式感知**:proxy 无上行（direct/规则全直连）→ no-op。（F19 规则变体）

## 扩展侧集成约束

- 硬 `guard` 非切换中（mid-switch stop→start 会让所有信号虚假触发）。（F24）
- switchNode/reconfigure 后 resetBaseline + 宽限。（F5/F7）
- 通知带冷却（同一节点每 M 分钟最多一条），别刷屏。
- 长驻循环每迭代套 `autoreleasepool`,扩展**不留 history**（只吐瞬时结果,历史在主 App）。（F17）
- 被动信号零成本;首版**不在扩展做主动探测**（临时 xray 实例吃内存,撞 38MB 护栏/50MB jetsam）。（F16）

## 一键切换（主 App）

- 排除刚判死的节点(短时冷却),从打分候选里选最优健康替代,走 `reapplyRunningTunnel(.nodeOnly)`。（F13）
- 若替代也立即失败 → 不无限切,提示「机场疑似整体不可用」。（F10/F12 的保守版:首版是用户手动,天然限速）
- 尊重用户手动 pin 的节点:更高告警门槛,只提示不强推。（F25）

## 与现有机制协同

- 所有节点变更唯一入口仍是 `reapplyRunningTunnel`(串行 + `isSwitchingTunnel` + `pendingReapplyScope` 合并)。（F21/F23/F24）
- failover 是「死了→切」的独立意图,**绕开分数黏性/幅度闸**（那些是「也许更好→别折腾」,方向相反）。首版因为是用户一键,天然不与定时择优静默抢跑。（F22）
- 全量重启回退必须复用 `关On-Demand→stop→轮询disconnected→start` 序列。（F23）

## 回滚

- 代码:`git reset --hard checkpoint/pre-failover-build8`。
- 二进制:重装 Organizer 里的 1.0(8) 归档。
- 运行时:设置里关掉 failover 开关(默认就是关的)。

---

## 红队失败模式全表（F1–F25,来自 2026-07-08 workflow 对抗性评审）

**① Flapping**:F1 本地断网/漫游被当节点死(→本地网络前置门)、F2 目标站抖动(→多目标任一通)、
F3 单轮瞬时抖动(→连续 K 轮去抖)、F4 上行重/慢源站 TTFB 期误报(→持续+配对条件)、
F5 计数跨切换未重置(→显式重建 baseline)、F6 TUN 被 FakeDNS 污染(→只用 proxy 计数)、
F7 建链/切换过渡误报(→起手宽限)、F8 睡眠跳变(→单调时钟丢弃)、F9 探测自污染(→排除探测字节)。
**② 误切到同样坏的**:F10 整机场挂→切换风暴(→熔断+退避)、F11 本地无网切换(→本地前置门)、
F12 直连绿出口黑洞假快节点(→换后经代理验证)、F13 切回刚判死的(→冷却黑名单)、F14 同 IP 段(→按 ASN/region 多样化)。
**③ 开销/误报**:F15 主动探测烧流量(→被动优先)、F16 pingNode 吃内存撞护栏(→不做周期主信号)、
F17 长驻循环内存泄漏(→autoreleasepool)、F18 access log accepted 陷阱(→不用它)、
F19 downlink==0 二义(→配对条件)、F20 分辨率~2-3s 别过拟合。
**④ 与现有机制打架**:F21 与定时择优抢跑(→唯一串行入口)、F22 黏性/幅度闸方向相反(→独立快路径)、
F23 On-Demand 竞态(→复用关闭序列)、F24 isSwitchingTunnel 窗口自触发(→硬 guard)、F25 强切用户 pin 节点(→高门槛/只告警)。
