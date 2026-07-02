# 轻舟 / Qingzhou

跨平台 iOS / macOS 网络配置工具,基于 [xray-core](https://github.com/XTLS/Xray-core)。

> Cross-platform iOS / macOS network configuration utility, built on xray-core.

[![Tests](https://img.shields.io/badge/tests-147%20passing-success)]()
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-iOS%2017%2B%20%7C%20macOS%2014%2B-lightgrey)]()

---

## 是什么

轻舟帮你做三件事:

- **管理代理节点订阅** — trojan / vmess / vless / shadowsocks 多协议,Clash YAML 导入
- **自定义路由规则** — 中国域名直连、海外走代理、自定义 GEOIP / IP-CIDR / DOMAIN-SUFFIX 规则
- **通过系统 VPN 框架转发流量** — 标准 `NEPacketTunnelProvider` Extension,无私有 API

不是节点服务提供方 —— 节点由你自己提供。

## 隐私

**零数据收集**。所有节点 / 订阅 / 规则只在你设备本地 (`Documents/VPN/state.json`),不上传任何服务器。
不接第三方 SDK(Firebase / Analytics / Sentry 之类全部没有)。

完整隐私政策见 [docs/PRIVACY.md](docs/PRIVACY.md) 或线上版 https://qingzhou-app.github.io/qingzhou/PRIVACY 。

## 平台

- iOS 17+ (主要平台)
- macOS 14+ (S6 sprint 完成度,共用 Tunnel 桥接代码)

## 架构

```
┌─────────────────────────┐
│  Qingzhou-iOS / Qingzhou-macOS    │ ← 主 App(SwiftUI,无 libXray 依赖,启动 < 1s)
│  - 订阅/节点/规则 UI    │
│  - VPNTunnelManager     │
└──────────┬──────────────┘
           │ providerConfiguration["nodeJSON"]
           ▼
┌─────────────────────────┐
│  Qingzhou-Tunnel-iOS.appex   │ ← Network Extension(独立进程,内存上限 50MB)
│  - PacketTunnelProvider │
│  - socketpair TUN shim  │ ← iOS 26 起 KVC fd 路径已失效,改用 socketpair
│  - NodeConverter        │ ← 纯 Swift 把 Node 转 xray outbound JSON
│  - xray-core (libXray)  │ ← Go,实际跑代理协议
└─────────────────────────┘
```

技术栈细节见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 编译

```bash
git clone https://github.com/qingzhou-app/qingzhou.git
cd qingzhou

# 第一步:构建 LibXray.xcframework(~10 分钟,只用做一次)
./scripts/build-libxray.sh

# 第二步:生成 Xcode 项目
brew install xcodegen
cd Apps && xcodegen generate

# 第三步:Xcode 打开,选 Qingzhou-iOS scheme,Cmd+R
open Apps/Qingzhou.xcodeproj
```

详细 build 说明 / 真机签名 / 调试技巧见 [docs/BUILD.md](docs/BUILD.md)。

## 测试

```bash
swift test  # 147 测试,通常 < 1 秒
```

## 文档

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 架构总览
- [docs/BUILD.md](docs/BUILD.md) — 编译 / 签名 / 真机调试
- [docs/USAGE.md](docs/USAGE.md) — 用户视角的使用说明
- [docs/ROADMAP.md](docs/ROADMAP.md) — 12 个 sprint 路线图
- [docs/APP_STORE.md](docs/APP_STORE.md) — App Store 上架准备
- [docs/ORG_ACCOUNT.md](docs/ORG_ACCOUNT.md) — Apple Org 账号注册指南
- [docs/ICON_BRIEF.md](docs/ICON_BRIEF.md) — App 图标设计 brief
- [docs/PRIVACY.md](docs/PRIVACY.md) — 隐私政策
- [docs/IOS-LOGS.md](docs/IOS-LOGS.md) — iOS 真机日志抓取指引

## 协议 / License

本仓库代码 MIT 协议,见 [LICENSE](LICENSE)。

依赖的开源组件:

| 库 | 协议 | 用途 |
|---|---|---|
| [xray-core](https://github.com/XTLS/Xray-core) | MPL-2.0 | 代理协议核心 |
| [libXray](https://github.com/xtlsapi/libXray) | MIT | xray-core 的 iOS / macOS binding |
| [Yams](https://github.com/jpsim/Yams) | MIT | Clash YAML 解析 |

## 使用须知

- 17 岁以上用户使用。
- 不应用于任何违反当地法律法规的用途。
- 开发者不运营任何代理节点,不为通过本工具的流量负责。

## 支持这个项目 / Support

轻舟是免费开源项目，靠用户捐赠维持开发。如果它帮到了你：

[![爱发电](https://img.shields.io/badge/爱发电-支持一下-946ce6?logo=github-sponsors&logoColor=white)](https://afdian.com/a/qingzhou-app)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-Buy%20me%20a%20coffee-ff5e5b?logo=ko-fi&logoColor=white)](https://ko-fi.com/qingzhou)

- 🇨🇳 大陆用户：[爱发电](https://afdian.com/a/qingzhou-app)（支付宝 / 微信）
- 🌍 Overseas: [Ko-fi](https://ko-fi.com/qingzhou) (credit card / PayPal)
- ₮ USDT (TRC-20): `TDczVRXsMNZ6ySqWipxqLfVgdqpnrpCoAE`

捐赠者如愿意留名，会列入下方鸣谢名单（默认匿名）。
Sponsors who opt in will be credited below (anonymous by default).

### 鸣谢 / Sponsors

感谢每一位支持者。Thank you to all our sponsors!

<!-- sponsors:start -->
<!-- sponsors:end -->

## 反馈

[GitHub Issues](https://github.com/qingzhou-app/qingzhou/issues)
