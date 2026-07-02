# 轻舟 隐私政策 / Qingzhou Privacy Policy

> 生效日期 / Effective Date：__待填__
> 最后更新 / Last Updated：__待填__

---

## 中文版

### 一、我们是谁

「轻舟」(以下简称"本应用")是一款帮助用户管理代理节点订阅、本地路由规则与发起系统 VPN 连接的工具型应用。开发者为个人开发者 `sbraveyoung`(以下简称"我们")。

我们**不运营任何代理节点服务**,本应用仅是一个客户端工具,所有代理节点由你自己提供。

### 二、我们收集哪些数据

**不收集任何个人身份信息**。本应用不要求注册、不需要邮箱、不需要电话号码,我们无法将任何使用行为与你的真实身份关联。

具体来说,本应用**不会收集**：

- 你的姓名、邮箱、电话或任何账号信息
- 设备标识符(IDFA / IDFV / advertisingIdentifier)
- 位置信息(GPS / Wi-Fi 三角定位等)
- 通讯录、相册、健康数据
- 浏览历史、搜索关键词、访问的网站
- 设备使用统计、崩溃日志(iOS 系统自带的崩溃报告由 Apple 处理,我们既不收也不读)
- 第三方分析数据(我们不接入 Firebase、Google Analytics、友盟、Sentry 等任何统计 / 分析 / 监控 SDK)

### 三、本地存储的数据

为完成应用基础功能,以下数据**仅在你的设备本地**存储,在你不删除应用的前提下保留：

| 数据 | 用途 | 存储位置 |
|---|---|---|
| 订阅 URL | 拉取节点列表 | `~/Documents/VPN/state.json`(iOS 沙箱内) |
| 节点信息(协议 / 主机 / 端口 / 凭据) | 建立 VPN 连接 | 同上 |
| 自定义路由规则 | 决定走代理 / 直连 / 拒绝 | 同上 |
| 设置项(主题、日志级别、排序偏好) | 个性化界面 | 同上 |
| 测速结果(延迟数值) | 节点排序 | 同上 |

以上数据**不会**通过网络发送到任何服务器,也**不会**通过 iCloud / Apple ID 备份与其他设备同步,**除非**你手动开启 iOS 的 "iCloud 备份" 功能(此时数据由 Apple 加密保管,我们仍然看不到)。

### 四、网络传输的数据

为完成代理功能,本应用会向以下目标发送网络请求：

1. **你自己配置的订阅源 URL**：刷新节点列表时会向这个 URL 发起 HTTPS 请求。请求内容仅包含 User-Agent 头,不带任何个人信息。
2. **你选中的代理节点服务器**：开启 VPN 后,你的网络流量会通过这台服务器转发。这台服务器由你自己选择和信任,**我们不运营、不监控、不记录**任何经过它的流量。
3. **公共 DNS 解析服务**：默认配置使用 Google `8.8.8.8` 与 Cloudflare `1.1.1.1` 解析域名,规则模式下国内域名会经过阿里 `223.5.5.5` 解析。这些是公共 DNS 服务,我们不与他们共享任何个人信息,他们的隐私政策见各自官网。

### 五、第三方服务

本应用**不集成任何第三方 SDK**。引用的开源库均为本地编译进二进制,不进行网络通信(除上述代理与订阅功能外)。

- xray-core (Mozilla Public License 2.0) — 代理核心
- libXray (MIT) — xray-core 的 iOS / macOS binding
- Yams (MIT) — Clash YAML 解析

### 六、儿童隐私

本应用**面向 17 岁以上用户**。我们不会有针对性地收集 13 岁以下儿童的数据(因为我们对所有用户都不收集数据)。

如果你是父母或监护人,发现孩子在使用本应用,可以直接卸载应用 —— 设备上的所有本地数据会一并删除。

### 七、你的权利

由于我们不在云端存储任何与你相关的数据,你可以通过以下方式行使隐私权利：

- **访问 / 导出数据**：所有数据在你设备本地的 JSON 文件中,可通过 iOS 系统的 "文件" app 直接查看(后续会提供导出按钮)
- **删除数据**：卸载本应用即可一次性删除所有本地数据,无残留
- **撤回授权**：iOS 设置 → 通用 → VPN 与设备管理,删除 VPN 配置即可

### 八、政策变更

我们如果改变本政策,会在本仓库提交新的版本并在应用更新说明里告知。我们建议你在应用更新后查看最新版本。

### 九、联系方式

GitHub Issues: https://github.com/qingzhou-app/qingzhou/issues

---

## English Version

### 1. Who we are

Qingzhou (the "App") is a utility tool that helps users manage proxy subscription URLs, local routing rules, and establish system VPN connections. It is developed by an individual developer (`sbraveyoung`).

**We operate no proxy servers.** The App is purely a client tool; the nodes are entirely supplied by you.

### 2. Data we do **not** collect

The App requires no registration, no email, no phone number. We **do not collect** any of the following:

- Personally identifying information
- Device identifiers (IDFA / IDFV / advertisingIdentifier)
- Location data
- Contacts, photos, health data
- Browsing or search history
- Usage analytics or crash logs (iOS system crash reports are handled by Apple; we neither collect nor read them)
- Any third-party SDK data — we do not integrate Firebase, Google Analytics, Sentry, or any analytics SDK

### 3. Data stored locally

To deliver core features, the following is stored **only on your device**:

| Data | Purpose | Location |
|---|---|---|
| Subscription URLs | Refresh node lists | `~/Documents/VPN/state.json` (iOS sandbox) |
| Node info (protocol / host / port / credentials) | Establish VPN connections | same |
| Custom routing rules | Decide proxy / direct / reject | same |
| Settings (theme, log level, sort) | UI personalization | same |
| Latency measurements | Node ranking | same |

This data is **never** transmitted to any server we control, and is **not** synced via iCloud / Apple ID **unless** you explicitly enable iOS iCloud Backup (in which case Apple encrypts and stores it; we still cannot access it).

### 4. Data transmitted over the network

To perform proxy duties, the App makes network requests to:

1. **Your subscription URL** — HTTPS request to refresh node list. Only carries a User-Agent header.
2. **Your chosen proxy server** — Your traffic flows through this server, chosen and trusted by you. **We do not operate, monitor, or log** any traffic through it.
3. **Public DNS resolvers** — Google `8.8.8.8` and Cloudflare `1.1.1.1` by default; AliDNS `223.5.5.5` for Chinese domains in rule mode. We do not share any personal information with these services.

### 5. Third-party services

The App **integrates no third-party SDKs**. Open-source libraries are statically linked and perform no network communication beyond the proxy / subscription functions described above.

- xray-core (Mozilla Public License 2.0) — proxy core
- libXray (MIT) — iOS / macOS binding for xray-core
- Yams (MIT) — Clash YAML parsing

### 6. Children's privacy

The App is intended for users **17 years of age or older**. We do not knowingly collect data from children under 13 (and we do not collect data from anyone, regardless of age).

### 7. Your rights

Since we hold no cloud-stored data linked to you:

- **Access / Export** — All data lives in JSON files in your device's sandbox; you can inspect them through iOS Files app
- **Delete** — Uninstalling the App removes all local data; no residue
- **Revoke** — iOS Settings → General → VPN & Device Management → remove the VPN profile

### 8. Changes to this policy

Updates to this policy will be committed to this repository and noted in the App release notes.

### 9. Contact

GitHub Issues: https://github.com/qingzhou-app/qingzhou/issues

---

> 本政策中文版本与英文版本如有歧义,以中文版为准。
> In case of any discrepancy, the Chinese version prevails.
