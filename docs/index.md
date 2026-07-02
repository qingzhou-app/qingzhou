---
title: 轻舟 / Qingzhou
description: 跨平台 iOS / macOS 网络配置工具 — 零数据收集、开源、自备节点
---

# 轻舟 · Qingzhou

**轻舟已过万重山。** 一款轻量、零数据收集的 iOS / macOS 网络配置工具。
你自备节点,它负责把本机流量按你的规则,经系统 VPN 框架优雅转发。

> **Lightweight. Zero data collection. Bring your own nodes.**
> A native iOS / macOS utility that routes your device traffic through the system VPN
> framework — by your rules, with nothing phoned home.

<p>
  <a href="#download">下载 / Download</a> ·
  <a href="https://github.com/qingzhou-app/qingzhou">源码 / Source</a> ·
  <a href="PRIVACY.html">隐私 / Privacy</a> ·
  <a href="https://github.com/qingzhou-app/qingzhou/issues">反馈 / Support</a>
</p>

---

## 为什么是轻舟 / Why Qingzhou

- **零数据收集** — 节点 / 订阅 / 规则 / 设置全部只存在你的设备上,不上传任何服务器。
  没有 Firebase、没有 Analytics、没有 Sentry、没有广告。
- **不运营节点** — 我们是纯客户端工具,不提供也不转售任何代理服务。节点由你自己提供。
- **原生轻量** — SwiftUI 写的主 App,启动 < 1 秒;内核跑在独立的 Network Extension 进程,不拖慢前台。
- **开源可审计** — App 代码 MIT 开源,你能看清它到底做了什么、没做什么。

> Your nodes, your rules, your device. Nothing leaves it. The app code is MIT-licensed and auditable.

---

## 核心功能 / Features

| | |
|---|---|
| 🔗 **多协议节点** | trojan / vmess / vless / shadowsocks / hysteria2,支持 Clash YAML 导入 |
| 📡 **订阅管理** | 订阅自动刷新、节点并发测速、一键择优、按地区优先 / 排除 |
| 🧭 **智能分流** | 规则模式:国内直连、海外走代理;可自定义 GEOIP / IP-CIDR / DOMAIN 规则 |
| 📊 **流量洞察** | 首页实时流量波形;连接页**域名分析** — 哪些域名走代理 / 直连、命中哪条规则、规则优化建议 |
| ⚡ **顺手的体验** | 切换节点 / 模式自动热重启;快捷指令 / Siri 一键开关;macOS 打开指定 App 自动连 |
| 🔒 **标准框架** | 基于 Apple `NEPacketTunnelProvider`,无私有 API,全程 TUN 转发 |

---

## 工作原理 / How it works

1. 你提供节点订阅链接或单条分享链接,App 把节点信息保存在**本地**。
2. 选一个节点开启 VPN,系统弹出标准 VPN 授权对话框。
3. xray-core 在后台 Extension 进程里运行,按你的规则路由流量 —— 流量直接发往**你自己选的节点**,我们看不到、不记录。

---

## 下载 / Download {#download}

- 🚧 **App Store** — 即将上架(国际区) / Coming soon (international App Store)
- 🧪 **TestFlight** — 内测招募中,关注 [GitHub](https://github.com/qingzhou-app/qingzhou) 获取邀请
- 🛠 **自行编译** — 见 [BUILD.md](https://github.com/qingzhou-app/qingzhou/blob/main/docs/BUILD.md)

> 目标用户多在中国大陆,但 App 上架**国际区**(美 / 港 / 日等),请用非中国大陆 Apple ID 下载 —— 同类工具的常规做法。

---

## 常见问题 / FAQ

**要自己有节点吗?** 是。轻舟是纯客户端,不提供任何节点。你需要自备订阅源或分享链接。

**会收集我的数据吗?** 不会。零收集、零上传、零第三方 SDK。详见[隐私政策](PRIVACY.html)。

**支持哪些协议?** trojan / vmess / vless / shadowsocks / hysteria2,以及 Clash YAML 导入。

**安全吗?** 流量经 Apple 标准 TLS + 开源 xray-core 加密,直发你自己的节点。App 代码开源可审计。

**和市面上的客户端有什么不同?** 原生 SwiftUI、零数据收集、开源、外加域名分析 / 流量波形 / 自动重启 / 快捷指令这些顺手的细节。

---

## 协议 / License

App 代码(本仓库): **MIT** · 内核 [xray-core](https://github.com/XTLS/Xray-core): **MPL-2.0** · Binding [libXray](https://github.com/xtlsapi/libXray): **MIT**

---

<sub>GitHub: [github.com/qingzhou-app/qingzhou](https://github.com/qingzhou-app/qingzhou) · 反馈走 [Issues](https://github.com/qingzhou-app/qingzhou/issues)</sub>
