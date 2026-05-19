---
title: 轻舟 / Qingzhou
description: 跨平台 iOS / macOS 网络配置工具
---

# 轻舟 / Qingzhou

跨平台 iOS / macOS 网络配置工具,帮助你管理代理节点订阅、自定义路由规则、通过系统 VPN 框架转发本机流量。

> A cross-platform iOS / macOS utility for managing proxy node subscriptions, custom routing rules,
> and forwarding device traffic through the system VPN framework.

---

## 公开文档 / Public Docs

- [隐私政策 / Privacy Policy](PRIVACY.html)
- [App Store 上架说明 / Submission Notes](APP_STORE.html) — 含 Apple 5.4 合规、加密出口合规等
- [项目源码 / Source Code](https://github.com/sbraveyoung/qingzhou)
- [问题反馈 / Support](https://github.com/sbraveyoung/qingzhou/issues)

---

## 设计取向 / Design Principles

- **零数据收集**：所有节点 / 订阅 / 设置全部本地存储,App 不上传任何用户数据
- **不接第三方 SDK**：没有 Firebase / Google Analytics / Sentry 这类统计 / 分析
- **不运营节点**：我们不提供任何代理服务,App 是纯客户端工具
- **开源透明**:核心代码 MIT 开源,可审计

---

## 协议 / License

- App 代码 (本仓库) : **MIT**
- 内核 [xray-core](https://github.com/XTLS/Xray-core) : **MPL-2.0**
- Binding 层 [libXray](https://github.com/xtlsapi/libXray) : **MIT**

---

## 联系 / Contact

GitHub Issues: [github.com/sbraveyoung/qingzhou/issues](https://github.com/sbraveyoung/qingzhou/issues)
