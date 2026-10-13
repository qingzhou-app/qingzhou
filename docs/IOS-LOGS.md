# iOS 真机调试日志抓取

## 开发版验收快照（build23起）

当syslog无法提供主App编排日志时，可在DEBUG开发版启动时带`--qz-acceptance-record`：

```bash
xcrun devicectl device process launch --device <设备ID> --terminate-existing \
  com.sbraveyoung.qingzhou.ios --qz-acceptance-record
```

等待16秒后，使用CoreDevice的appDataContainer文件传输读取`Documents/Diagnostics/acceptance.json`。
每次启动生成独立runID、16份状态采样和有界事件。记录包括系统VPN状态（NEVPNStatus rawValue）、
实际激活/节点ID、选中节点ID与匹配结果、会话起点、规则计数和分类后的采认/重配事件。
不含节点凭据、URL、域名、原始日志；独立事件通道不受用户日志级别过滤。
记录仅在显式参数下运行15秒，Release不包含此入口，也不改变VPN/云同步配置。
可与`--qz-start-vpn`或`--qz-stop-vpn`组合使用；launch成功不等于VPN验收通过，必须核对快照。

> 用来诊断 #3 类问题：「打开 VPN 开关 → 系统设置看 VPN toggle 自动关闭」。
> 这种症状是 `saveToPreferences` 成功但 Extension（`Qingzhou-Tunnel-iOS.appex`）启动失败 →
> 系统标 connection failed → toggle 显示为 off。要看到具体错在哪，必须抓 Extension 那个进程的日志。

## 方法 1（推荐）：Mac 上的 Console.app

1. iPhone 用数据线连 Mac（**保持插着**，否则日志流断）
2. Mac 打开 `应用程序 → 实用工具 → 控制台`（或 Spotlight 搜 `Console.app`）
3. 左边设备栏选你的 iPhone
4. 顶部搜索框输入 `com.sbraveyoung.qingzhou` —— 把 app 和 Extension 的日志都过滤出来
5. 顶部点 **开始流式传输**
6. **回到 iPhone**，按下 VPN 开关
7. 等 5–10 秒，回到 Mac，**按 ⌘C 停止流**，把日志全选 ⌘A 复制

把这段日志贴给我（最近的 50–100 行，含 `PacketTunnel` 关键字就够）。重点看：

| 关键字 | 含义 |
|---|---|
| `startTunnel begin` | Extension 进程被系统拉起，进入 PacketTunnelProvider |
| `missing xrayJSON in providerConfiguration` | 主 App 没成功传配置（重新选节点 / 重启 app） |
| `setTunnelNetworkSettings failed` | iOS 拒绝我们的 IP / DNS 配置（罕见） |
| `packetFlow fd = -1` | iOS 26 改了内部结构，KVC 拿不到 fd → 需要换 API |
| `got tun fd: <数字>` | TUN 设备就绪 |
| `geoDir=... geoip=MISSING` | xcframework 里 geo 文件没打进去 |
| `XrayCore.run failed: <消息>` | xray-core 启动失败（多半是配置不对） |
| `xray-core started OK` | 成功！这时还失败说明是 xray-core 跑起来后处理流量出问题 |

## 方法 2：Xcode 设备日志

Xcode → `Window` → `Devices and Simulators` → 选 iPhone → 右下点 `Open Console` —— 和方法 1 等效，但 UI 稍微差点。

## 方法 3：抓 Extension 的 crash log

如果是内存超限（NetworkExtension iOS 上有 50 MB 软限），Extension 会被 jetsam 杀掉，crash 日志写在 iPhone 上：

`设置 → 隐私与安全性 → 分析与改进 → 分析数据`

找文件名含 `Qingzhou-Tunnel-iOS` 的，点开看。注意 `Termination Reason: PER-PROCESS-LIMIT` 就是 OOM。

## 方法 4：导出 xray 配置 dump

Extension 启动失败时会把生成的 xray JSON 写到 Caches `xray-config-dump.json`。
这个目录在 Extension 沙箱里，正常情况下没办法直接拿出来。但如果在 Mac 上跑：
```bash
log show --predicate 'subsystem CONTAINS "com.sbraveyoung.qingzhou"' --info --last 5m \
  | grep "dumped failing config"
```
能看到具体路径（虽然取不出来）。

未来要让用户能取出 dump，加 file sharing 即可（Info.plist 加 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`）—— S4 上架前会做。

## 把日志贴给我的格式

```
== Console.app 日志 ==
<粘贴 30-50 行带 com.sbraveyoung.qingzhou 的日志>

== 系统设置 → 网络 → VPN 看到的状态 ==
<截图或描述>

== 节点信息（脱敏后） ==
协议：trojan
host:port：example.com:443
有 SNI 吗：是 / 否
TLS 服务器证书是否合法（非自签）：是 / 否
```

我看完就能定位是配置错、内存超限、还是 iOS 26 KVC 失效。
