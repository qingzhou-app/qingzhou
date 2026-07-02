# 阶段 2 准备工作指南（历史文档 · 已被取代）

> ⚠️ **历史文档，已被取代 —— 别照这个 B/C 节做。** 本文写于早期，当时打算用 **sing-box** 作内核。
> 实际项目最终采用的是 **xray-core**，通过 **libXray**（binary xcframework：`Frameworks/LibXray.xcframework`）接入，
> **不使用 sing-box / SingBox.xcframework**。下文凡是提到 `sing-box` / `SingBox.xcframework` / `Libbox` 的地方，
> 请一律理解为「历史方案」；真正落地的内核集成见 [ROADMAP.md](ROADMAP.md) 的 S1/S2 与 `Sources/XrayCore/`。
> 另外，Swift 模块早期叫 `VPN*`，现已统一改名为 `Qingzhou*`（`QingzhouApp` / `QingzhouCore` / …）。
>
> A 节（Apple 后台配置：4 个 Bundle ID `com.sbraveyoung.qingzhou.*` + App Group `group.com.sbraveyoung.qingzhou`）仍然有效。

> 这是给 **拿到付费 Apple Developer 账号、正在等 Packet Tunnel entitlement 审批** 的人看的。等审批的 1–4 周里，把下面 A / B 两件事做完，等邮件一到立刻能闭环。

## 当前状态

代码层面已经做完的（仓库现在的样子）：

- ✅ 两个 PacketTunnel Extension target（`Qingzhou-Tunnel-iOS` / `Qingzhou-Tunnel-macOS`），stub `PacketTunnelProvider` 现在编得过、签得过、能嵌进主 app
- ✅ 主 App 和 Extension 的 entitlements 已经写好 `packet-tunnel-provider` 和 `application-groups`
- ✅ `AppGroupStorage` 共享存储类：写 `tunnel-config.json` 到 `group.com.sbraveyoung.qingzhou` 容器
- ✅ `VPNTunnelManager` 包装 `NETunnelProviderManager`：load / configure / start / stop API，错误兜底
- ✅ 主页 VPN 开关接到 `VPNTunnelManager` 真启停；entitlement 拿不到时会弹 alert 提示

差的两块（外部依赖）：

- ⏳ Apple 的 `packet-tunnel-provider` entitlement 审批
- ⏳ ~~sing-box.xcframework 编译~~ →（历史；实际改用 xray-core / `LibXray.xcframework`）

---

## A. Apple Developer 后台配置

A1–A3 这三步不依赖 entitlement 审批，**现在就能做**。

### A1. 注册两个 Bundle ID

进 <https://developer.apple.com/account/resources/identifiers/list>，右上 `+` → `App IDs` → `App`：

| Description | Bundle ID | 类型 |
|---|---|---|
| VPN iOS | `com.sbraveyoung.qingzhou.ios` | Explicit |
| VPN iOS Tunnel | `com.sbraveyoung.qingzhou.ios.tunnel` | Explicit |
| VPN macOS | `com.sbraveyoung.qingzhou.mac` | Explicit |
| VPN macOS Tunnel | `com.sbraveyoung.qingzhou.mac.tunnel` | Explicit |

> 注意是 **4 个** Bundle ID，不是 2 个。每个 app 都需要主 app + tunnel extension 各一个 ID。

每个 ID 在 Capabilities 段勾这两项（**找不到 Network Extensions 就先跳过，等审批批了再回来勾**）：

- ☑️ `App Groups`
- ☑️ `Network Extensions`（如已有 → 勾；未审批 → 等批了再回来）

### A2. 创建 App Group

进 <https://developer.apple.com/account/resources/identifiers/list/applicationGroup>，`+` → `App Groups`：

| Description | Identifier |
|---|---|
| VPN Shared | `group.com.sbraveyoung.qingzhou` |

> Identifier **必须**以 `group.` 开头，且**必须**就叫 `group.com.sbraveyoung.qingzhou` —— 代码里写死的常量，改名要同步改 [Sources/QingzhouApp/AppGroupStorage.swift](../Sources/QingzhouApp/AppGroupStorage.swift) 第 15 行。

### A3. 把 App Group 绑到 4 个 Bundle ID

回 Identifiers 列表，**逐个**点开上面 4 个 Bundle ID：

1. 找到 `App Groups` 那行 → 点 `Configure`
2. 勾上 `group.com.sbraveyoung.qingzhou`
3. Continue → Save

### A4.（拿到 entitlement 邮件后）勾上 Network Extensions

Apple 邮件批复后，重复 A3 流程，这次勾 `Network Extensions` 那行的 `Configure`：

- ☑️ `Packet Tunnel`（重要：不是 Personal VPN）

然后 Xcode 会在下次 build 时**自动重新生成 provisioning profile**。

---

## B. 编 sing-box.xcframework（⚠️ 历史方案，已弃用 —— 实际用 xray-core / libXray，勿照做）

预计耗时 **30–60 分钟**（含工具链下载）。这一步**完全可以现在就开始**，不依赖 Apple 审批。

### B1. 装 Go + gomobile

```bash
# Go 1.22 或更新（我这台 Mac 默认 brew install go 装的是最新版）
brew install go
go version

# gomobile 是 Go 转 iOS/Mac 工具
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest

# 把 GOPATH/bin 永久加进 PATH
echo 'export PATH=$HOME/go/bin:$PATH' >> ~/.zshrc
source ~/.zshrc

# 第一次 gomobile init 会下载 NDK 工具链，几分钟
gomobile init
```

### B2. 克隆 sing-box

```bash
mkdir -p ~/code && cd ~/code
git clone --depth 1 https://github.com/SagerNet/sing-box.git
cd sing-box
```

### B3. 编 xcframework

```bash
# 编译 ios + iossimulator + macos 三种 slice 合并的 xcframework
# 协议 tags 决定 binary 里包含哪些核心；下面是覆盖本项目需要的全部
gomobile bind -v \
  -target=ios,iossimulator,macos \
  -ldflags='-s -w' \
  -tags='with_clash_api,with_quic,with_wireguard,with_utls,with_gvisor,with_dhcp,with_ech' \
  -o ~/code/src/github.com/qingzhou-app/qingzhou/Frameworks/SingBox.xcframework \
  ./experimental/libbox
```

> 这一步在我的 M3 / Apple Silicon 上跑大约 20–30 分钟，在 Intel Mac 上更久。耐心等。

### B4. 验证产物

```bash
cd ~/code/src/github.com/qingzhou-app/qingzhou
ls -la Frameworks/SingBox.xcframework
# 应该看到一个 ~80-120 MB 的目录，含 ios-arm64 / ios-arm64_x86_64-simulator / macos-arm64_x86_64 三个子目录
```

每个子目录里有一个 `Libbox.framework`，就是给 Swift 用的 binary 接口。

---

## C. （完成后我做）真接内核（历史写的是 sing-box；实际落地为 xray-core / libXray）

A4 邮件 + B4 产物都到位之后，告诉我，我做这几件事：

1. **把 SingBox.xcframework 加到 project.yml**：两个 Tunnel target 都 link 它
2. **重写 PacketTunnelProvider**：
   - 启动时读 AppGroup 里的 `tunnel-config.json`
   - 把 `Node` 转成 sing-box JSON 配置（outbounds + route）
   - 调 `Libbox.NewService(config)` + `service.Start()` 起核心
   - 建 TUN：`setTunnelNetworkSettings` + `packetFlow` 读写绑到 libbox 的 TUN 接口
3. **主 app ↔ Extension IPC**：用 `sendProviderMessage` 拉实时连接列表 / 流量统计
4. **删 `sampleConnectionsLoop`**：连接页的演示数据换成真数据
5. **通过代理的端到端测速**：URLSession 走本地 HTTP 端口
6. **跑通真机调试 + 写阶段 2 测试报告**

预计 2–3 小时落地，外加测试。

---

## 你现在的 checklist

- [ ] A1. 注册 4 个 Bundle ID
- [ ] A2. 创建 App Group `group.com.sbraveyoung.qingzhou`
- [ ] A3. 把 App Group 绑到 4 个 Bundle ID
- [ ] 提交 / 跟进 Packet Tunnel entitlement 申请（路径见 [BUILD.md](BUILD.md) 或最近一次对话回复）
- [ ] B. 跑 `gomobile bind` 出 SingBox.xcframework
- [ ] A4. entitlement 邮件批复后，回 Bundle ID 勾上 Network Extensions

做完任意一项告诉我，我接着做下一步。
