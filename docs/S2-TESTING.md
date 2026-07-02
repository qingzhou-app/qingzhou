# S2 真机测试 procedure

> 代码已就绪：`PacketTunnelProvider` 真接 xray-core，iOS / macOS 两个 Tunnel target 都嵌入 LibXray.xcframework 编译过。剩下的就是**你**在真机上跑一次，看流量真的能走通。

## ⚠️ 一定要看：「permission denied」是怎么回事

NetworkExtension **强制要求 Apple Developer 真签名**。
- `install.sh`（不带参数）= ad-hoc 签名 = VPN 必报 permission denied
- `install.sh --signed` = 用你 Team UK7MME38H9 真签 = VPN 能工作
- 或者用 **Xcode ⌘R**（自动真签）

```bash
cd Apps
./install.sh --signed     # macOS 上跑 VPN 必须加 --signed
```

或者用 Xcode：
1. `xcodegen generate && open Qingzhou.xcodeproj`
2. 选 `Qingzhou-macOS` scheme + `My Mac` destination
3. ⌘R（Xcode 自动用你的 Apple Developer 签名）

**第一次开 VPN 开关时**：
1. macOS 弹「Qingzhou-macOS 想要添加 VPN 配置 / 输入密码」→ 输 Mac 登录密码 → 允许
2. 如果没弹密码框就直接报错 → 去 `系统设置 → 隐私与安全性`，**最下面**有「VPN 配置已被阻止」红字 → 点「允许」
3. 再开一次开关 → 应该就通了

> 现在的版本（W3 起）**不再用 App Group**，不会再弹「Qingzhou-macOS 想访问其他 App 数据」的隐私警告。xray JSON 通过 `providerConfiguration` 直接传给 Tunnel Extension；geo 数据库内嵌在 Extension Resources 里。
>
> **2026-05-18 重要修复**：之前 xray 启动后流量空跑（在中国访问 google.com 超时）的根因 ——
> libXray 的 `ConvertShareLinksToXrayJson` 只产 `outbounds`，没有 inbound / routing / dns，xray
> 启动了但**根本不接管 TUN 流量**。已加 [XrayConfigComposer](../Sources/XrayCore/XrayConfigComposer.swift)
> 把 outbound 包装成完整 xray 配置（含 `tun` inbound、按 ProxyMode 走的 routing、防 DNS 污染的 DNS 段）。

如果上面都做了还报 permission denied，跳到最下面的「permission denied 完整排查」。

## 在 iPhone 上一次性跑通

### 0. 前置（如果还没做）
- [ ] iPhone 已经数据线连 Mac
- [ ] Xcode → Settings → Accounts → 你的付费 Apple ID 已添加且能看到 `UK7MME38H9` Team
- [ ] iPhone 上「设置 → 通用 → VPN 与设备管理」之前如果信任过开发者就保留

### 1. 生成 Xcode 工程

```bash
cd /Users/sbraveyoung/code/src/github.com/qingzhou-app/qingzhou/Apps
xcodegen generate
open Qingzhou.xcodeproj
```

### 2. 在 Xcode 里选 iPhone 真机

- 顶部 scheme 切到 `Qingzhou-iOS`
- destination 下拉选你的 iPhone（不是 simulator）
- ⌘B 先试编一遍，应该通过

### 3. ⌘R 装到 iPhone

第一次会有几个弹窗：
- **iPhone**：「无法验证开发者 → 设置 → 通用 → VPN 与设备管理 → 信任 sbraveyoung」
- **再 ⌘R**

### 4. 准备一个真实的 trojan 节点

需要一个真能用的 trojan 服务器（你自己的或订阅里的），形式 `trojan://密码@主机:端口?sni=...#名字`。

打开 app → 节点页 → 右上 `+` → 粘贴这条链接 → 添加。

### 5. 选中节点

点新添加的节点（变绿勾✓）。

### 6. 第一次切开关 VPN

回首页 → 「VPN 未连接」开关向右拉。

**第一次会触发系统弹窗**：「VPN 配置」要求你允许。点「允许」+ 输入 Face ID / 锁屏密码。

之后：
- 开关变绿 → 进入「VPN 已连接」
- 状态栏顶部出现 `VPN` 图标
- 如果失败 → 主页会弹 alert 写错误信息

### 7. 验证流量真的走代理了

iPhone Safari 打开 <https://ipinfo.io/json>，看返回的 `ip` 字段应该是**你 trojan 服务器的出口 IP**，不是你蜂窝/Wi-Fi 的 IP。

或者打开 <https://www.google.com> —— 如果能加载，说明翻墙成功。

### 8. 关 VPN

主页开关向左拉 → 应该立刻断。

## 失败排查表

### 「VPN 启动失败：未找到 xray 配置」

- AppGroup entitlement 没生效。在 Apple Developer 后台确认 `group.com.sbraveyoung.qingzhou` 已绑定到 4 个 Bundle ID 都做过 Configure。
- Xcode → Product → Clean Build Folder → 重 ⌘R。

### 「VPN 启动失败：无法从 packetFlow 拿到 TUN 文件描述符」

- 极少见。可能 iOS 26 改了 NEPacketTunnelFlow 内部结构。报 issue 给我，附上 Xcode 控制台日志。

### 「VPN 启动失败：xray-core: ...」

xray-core 启动了但拒绝你的配置：
- 检查 trojan 链接是不是合法（host / port / password / sni 都对）
- 看 Xcode 控制台日志：能看到 `XrayCore.run failed: <具体原因>`
- 常见问题：你 trojan 服务器证书不在系统信任链 → 加 `&allowInsecure=1` 重试

### 流量没走代理（ipinfo.io 返回本地 IP）

- 检查节点页选中的是不是想要的节点（绿勾）
- 检查 trojan 服务器自己是不是工作的（在 Mac 上用 trojan-go / sing-box CLI 验证）
- 检查代理模式（首页底部 segment）—— 应该是「全局」或「规则」，不是「直连」

### 一开 VPN 整个 app 卡死

- xray-core 启动可能在阻塞主线程。在 Console.app 过滤 `Qingzhou-Tunnel-iOS` 看 stack。
- 把 [Apps/Tunnel-Shared/PacketTunnelProvider.swift](../Apps/Tunnel-Shared/PacketTunnelProvider.swift) 里 `XrayCore.run` 放到 `Task.detached`。

## 调试日志位置

**iPhone 真机：**
1. Xcode → Window → Devices and Simulators → 选你的 iPhone → Open Console
2. 过滤 `com.sbraveyoung.qingzhou` 看主 App + Tunnel 两个进程的日志混合输出

**macOS：**
```bash
log stream --predicate 'subsystem CONTAINS "com.sbraveyoung.qingzhou"' --info
```

## 验证成功后告诉我什么

报告以下任一项就够：

✅ **成功路径**：「7 步走通了，ipinfo.io 显示我 trojan 出口 IP」
⚠️ **失败路径**：哪一步炸了 + Xcode 控制台**最近的 20 行日志**截图（必须含 `com.sbraveyoung.qingzhou` 相关行）

然后我们进 S3（4 协议→config 转换器 + 单测），或者修 S2 残留 bug。

---

## permission denied 完整排查

按顺序检查：

### 1. 签名方式确认（最常见原因）

```bash
codesign -dv /Applications/Qingzhou-macOS.app 2>&1 | head -5
```

- 看到 `Authority=Apple Development: <你的邮箱> (XXXXXXXXXX)` → ✅ 真签名
- 看到 `Signature=adhoc` 或 `Signature=Adhoc` → ❌ ad-hoc 签名，**VPN 不能用**

修复：`./install.sh --signed`，或者直接 Xcode ⌘R。

### 2. 系统设置里检查 VPN 配置

`系统设置 → 网络` 看左边栏有没有 `Qingzhou-macOS` 条目：

| 看到 | 含义 | 怎么办 |
|---|---|---|
| 没有任何 VPN 条目 | 配置保存失败 | 看上面的「VPN 配置已被阻止」 |
| 有 `Qingzhou-macOS` 但显示「未启用」 | 配置存了但被禁 | 点进去 toggle 开 |
| 有 `Qingzhou-macOS` 显示「正在连接」一直转 | xray-core 自己有问题 | 看下面「xray-core 启动失败」 |

### 3. 系统设置里看是否被拦截

`系统设置 → 隐私与安全性`，往下拉到最底：

- 如果有红色 / 黄色字 **「VPN 配置已被阻止 / Qingzhou-macOS was blocked from adding a VPN configuration」** → 点右边「允许」
- 如果有 **「来自身份不明的开发者」** → 也点允许（虽然你真签了，但 entitlement 第一次仍会触发审查）

### 4. 看实时日志看真实错误

```bash
log stream --predicate 'subsystem CONTAINS "com.sbraveyoung.qingzhou" OR subsystem CONTAINS "NetworkExtension"' --info 2>&1 | head -50
```

然后**在另一个终端**打开 VPN 开关。看 log stream 里出现的红色 / 错误行。

把那 5–10 行贴回来给我。

### 5. 干净重置 VPN 状态（核武器）

如果上面都没解决，把残留的旧 VPN 配置全清掉重来：

```bash
# 删 system VPN 配置
sudo rm /Library/Preferences/com.apple.networkextension.plist
sudo rm -rf /Library/Preferences/SystemConfiguration/NetworkInterfaces.plist

# 重启 NetworkExtension daemon（不用重启电脑）
sudo killall -9 com.apple.NetworkExtension neagent nesessionmanager 2>/dev/null || true

# 删 app 然后重装
rm -rf /Applications/Qingzhou-macOS.app
./install.sh --signed
```

注意上面的命令会把 **所有** VPN 配置（公司 VPN 之类的）也清掉，仅自用环境用。

### 6. 还不行？

`log stream` 那 5-10 行 + `codesign -dv` 输出 → 贴给我。
