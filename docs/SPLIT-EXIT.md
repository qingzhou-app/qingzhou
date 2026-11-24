# 分流方案：国内直连、其余全走海外出口、断了也不漏

本文对应 `Sources/XrayConfig/SplitExitPlan.swift`。它描述的是**一个固定策略**的实现，
不是通用配置器；实现状态和留白都写在最后一节，别把「有代码」当成「已上线」。

## 出口形状

```
App → TUN → xray
              ├─ exit（静态住宅 SOCKS5）──dialerProxy──→ hop（跳板节点）→ 住宅入口
              ├─ direct（freedom）
              └─ reject（blackhole）
```

- `exit` 是**唯一**的海外出口，协议是 `socks`，不可能落成 `freedom`。所以「海外出口组里
  没有 DIRECT」是结构性的，不靠某条规则写对。
- `hop` 只作为 `streamSettings.sockopt.dialerProxy` 的引用存在，**不作为任何路由规则的
  outboundTag**。跳板坏了，海外整体不通，不会退化成直连。
- 没有 url-test、没有 fallback、没有自动换节点：出口是手选的，挂了就是断。
- 住宅代理自身地址也经跳板（`dialerProxy` 覆盖该出站的所有连接），否则国内连不上住宅入口，
  而且会把本机真实 IP 暴露给住宅服务商。

## 规则顺序（first-match，上→下即优先级）

| # | 匹配 | 出口 | 为什么在这个位置 |
|---|---|---|---|
| 0 | `inboundTag: dns-module` 且目标是国内解析器 | direct | 用出口去查国内 DNS 会拿到境外边缘 IP |
| 1 | `inboundTag: dns-module`（其余，即海外 DoH） | exit | 海外域名必须由海外 DNS 经海外出口解析 |
| 2 | `tun-in` 的 53 端口 | dns-out | fake-ip 在这里分配假地址 |
| 3 | UDP 443 | reject | 经 SOCKS5 出口的 QUIC 基本不通，强制回退 TCP |
| 4 | Claude 域名 + `claude`/`anthropic` 关键字 | exit | 需求第 1 条 |
| 5 | 局域网与保留地址（含 `100.64.0.0/10`） | direct | 需求第 2 条 |
| 6 | B 站（`geosite:bilibili` + `mirrorakam` 关键字）、微信 | direct | 需求第 3 条 |
| 7 | `geosite:geolocation-!cn`（tcp） | exit | 需求第 4 条，**必须排在国内名单之前** |
| 8 | `geosite:geolocation-!cn`（udp） | reject | 出口没有可用 UDP |
| 9 | `geosite:cn` + 注入的国内域名 | direct | 需求第 5 条 |
| 10 | `geoip:cn` + 注入的国内 IP 段 | direct | 同上；`domainStrategy: AsIs` 保证不为匹配去做本地解析 |
| 11 | 其余 tcp | exit | 需求第 6 条 |
| 12 | 其余 udp | reject | 出口关掉 UDP，不回退直连 |

第 7 条的位置是整套方案的关键：Loyalsoldier 的国内域名名单里混着
`googletagmanager` / `doubleclick` 这类海外公司的域名，如果国内名单先匹配，Claude 网页
加载统计脚本时就会用国内 IP 出去。

`mirrorakam` 只能按关键字匹配：B 站视频分片域名形如
`upos-sz-mirrorakam.akamaized.net`，与 `bilibili.com` 不同后缀。

内置 `geosite.dat` **没有** `wechat` 分类（实测 1469 个分类里不存在），所以微信直连靠
`geosite:tencent` + 显式域名兜底。

## DNS

- `queryStrategy: UseIPv4` + **只有 IPv4 假 IP 池**（`198.18.0.0/15`，没有 `fc00::/18`）：
  不返回 IPv6 地址。
- 国内域名、跳板域名、住宅域名 → `223.5.5.5` / `119.29.29.29`（明文走直连）。
  节点自己的域名如果用出口解析，就是「用出口解析出口自己的地址」，自指成环。
- 其余 → 海外 DoH（`https://1.1.1.1/dns-query` 等）。这些查询按第 1 条规则走 `exit`，
  出口挂了海外解析就失败，**不会**退回国内 DNS 拿到国内 IP。

## 规则名单

`SplitExitPlan.Lists` 接收外部注入的国内域名 / 国内 IP 段（对应 Loyalsoldier 的
`direct.txt` / `cncidr.txt`）。空数组是合法的，此时仅用 `geosite:cn` / `geoip:cn`，
行为正确但粒度粗。**每日自动拉取尚未实现**（见下）。

## geosite 分类白名单

xray 遇到 routing 里引用了不存在的 geosite 分类会**直接启动失败**——一条手写错的规则
就能让整机断网。所以 `GeoDataBundle.supportsGeoSite` 用白名单，只放行内置 dat 里核实过的
分类；未知名与 `!cn` 这种反转写法一律跳过（xray 没有反转语义，透传会得到永不命中的规则）。
目前是手工维护的 23 个分类；内置 dat 有 1469 个，要引用其它分类需扩表并做一次真机启动验证。

## 实现状态

已完成（有单测）：

- SOCKS5 协议解析 / 出站 / 分享链接编码 / Clash YAML 导入
- `dialerProxy` 链式出口、单出口 UDP 拒绝
- `GEOSITE` 规则类型与转换、geosite 白名单
- 上述规则顺序、DNS 结构、假 IP 结构、出口组结构的完整配置构造
- **接入 App**：设置页「分流方案」开关 + 海外出口 / 跳板两个手选下拉；
  `Settings.splitExit{Enabled,ExitNodeID,HopNodeID}` 持久化；
  `AppState.startTunnel` / `performReapply` 把两个节点塞进 providerConfiguration；
  隧道扩展按 `splitExit` 走 `SplitExitPlan`，否则走原有单节点路径

接入时的几条硬约束（都有测试或显式分支）：

- 出口或跳板缺一个 → **不连接**并报原因，绝不退回单节点。回退等于让住宅代理从本机直连。
- 出口与跳板是同一节点 → 拒绝（会绕成死循环）。
- 分流开启期间**跳过自动择优**（否则会把 `currentNodeId` 改掉，等于自动换出口）。
- 分流开启时强制 `.rule` 模式（全局/直连那两套 routing 与它互斥）。
- 扩展内 `reconfigure` / `switchNode` 在分流模式下**明确回错**，让主 App 回退全量重启；
  否则会用旧节点套新配置，产生"半新半旧"的配置。
- 自定义用户规则在分流模式下不注入：规则顺序是需求固定的，插进去会破坏优先级保证。

未完成（不要在验收里算作已实现）：

1. **规则名单每日更新**：`Lists` 目前恒为空，只用内置 `geosite:cn` / `geoip:cn`。
2. **断网开关**：pf 侧独立组件完全没做。零泄漏依赖「代理核心的身份」这一前提，
   本轮未能实测确认（本机进程列表被系统限制，`ps` 不可用），必须在目标机上用特权脚本
   实测后再设计，不能只看代码推断。
3. **IPv6 接管**：TUN 层仍声明 IPv6 默认路由（`PacketTunnelProvider` 里，
   用于接住 IPv6 流量避免绕过隧道），但 DNS 已不返回 AAAA。故障瞬间 IPv6 是否漏出属于
   断网开关范畴，未验证。
4. **iOS target 未在本轮编译验证**：macOS target（含同一个隧道扩展、同一份 Sources）编译通过；
   iOS 的 xcodebuild 在依赖解析阶段被本机沙箱拦住（`sandbox-exec: Operation not permitted`），
   与代码无关，需要在正常终端里跑一次 `scripts/verify.sh` 确认。

