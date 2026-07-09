# 阻断 QUIC：症状、根因、解法与安全边界

> 2026-07-09 定稿。结论：**规则 / 全局代理模式下默认阻断 QUIC（reject UDP 443）**，
> 强制浏览器回退 TCP 443 走代理。这是刻意取舍而非疏漏 —— QUIC 经代理节点普遍走不通
> （真机确认），阻断后 YouTube 等 QUIC 重度站点恢复正常。设置里可关（`Settings.blockQUIC`，
> 默认开），给 UDP 转发能力好的节点放行 QUIC。

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

默认开（`Settings.blockQUIC = true`，迁移 `decodeIfPresent ?? true`）：绝大多数用户
用的节点 UDP 能力一般，默认阻断才是「开箱即通」的正确缺省。

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
  「设置 → 代理 → 阻断 QUIC」关掉本开关放行 QUIC。

## 6. 类似问题（另一类，不由本开关兜底）

依赖 UDP 的应用（在线游戏、WebRTC 音视频、VoIP、部分 VPN-in-VPN）在**不支持 UDP 转发
的节点**上仍可能不通 —— 那是节点 UDP 转发能力的问题，与本开关是两码事：

- 本开关只处理 **UDP 443（QUIC/HTTP/3）**，且做法是「拒掉逼其回退 TCP」——
  游戏 / WebRTC 没有 TCP 回退路径，拒了就是断，所以不在本开关覆盖范围；
- 若用户的节点 UDP 能力好、又需要 QUIC / UDP 应用，**关掉本开关**即可放行 UDP 443 给代理；
- 根治 UDP 应用要靠「选支持全量 UDP 转发的节点」，属于节点能力范畴，非路由配置能解决。

## 7. 实现落点

- `Sources/QingzhouCore/Settings.swift` — `blockQUIC: Bool`（默认 true，Codable 迁移 `?? true`）
- `Sources/XrayConfig/XrayConfigComposer.swift` — `buildRouting` / `compose` 的 `blockQUIC` 参数
- `Sources/QingzhouApp/VPNTunnelManager.swift` — `configure` 写 `providerConfig["blockQUIC"]`
- `Sources/QingzhouApp/AppState.swift` — 3 处 configure 传 `settings.blockQUIC`
- `Apps/Tunnel-Shared/PacketTunnelProvider.swift` — 读存实例属性，startTunnel / reconfigure /
  performTest 三个 compose 调用点复用（切节点 / 预检不放开 QUIC）
- `Sources/QingzhouApp/SettingsView.swift` — 代理段 Toggle「阻断 QUIC」
