# 轻舟 隐私政策 / Qingzhou Privacy Policy

> 生效日期 / Effective Date：2026-07-03
> 最后更新 / Last Updated：2026-10-12

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

为完成应用基础功能,以下数据在设备本地存储。配置可按下文的 iCloud 配置镜像设置同步；网络访问历史与测量历史不参与配置镜像：

| 数据 | 用途 | 存储位置 |
|---|---|---|
| 订阅 URL | 拉取节点列表 | `~/Documents/VPN/state.json`(iOS 沙箱内) |
| 节点信息(协议 / 主机 / 端口 / 凭据) | 建立 VPN 连接 | 同上 |
| 自定义路由规则 | 决定走代理 / 直连 / 拒绝 | 同上 |
| 设置项(主题、日志级别、排序偏好) | 个性化界面 | 同上 |
| 测速结果(延迟数值) | 节点排序 | 同上 |

应用默认开启 **iCloud 配置镜像**：当你登录 iCloud 且开启 iCloud Drive 时，订阅 URL、节点配置（包括连接凭据）、自定义规则和设置会写入你个人 iCloud Drive 的「轻舟」文档容器，并保留最多五份滚动历史。你可以在设置中关闭镜像；关闭会停止后续同步，不会自动删除云端文件。如需删除已有云端配置，请在「文件」App / Finder 的 iCloud Drive 中删除「轻舟」里的配置文件和 backups 目录。该文档为 JSON，应用没有额外加密，能访问该文档的人也能读取节点凭据。我们不运营这个存储服务，也无法访问你的个人 iCloud 配置。

以下诊断数据只保留在设备本地，不放入配置镜像：连接与域名访问记录、域名每日汇总、规则命中统计、节点测速历史、被动带宽与扩展内存统计。它们用于连接分析、择优与排障，不发送给开发者。系统 iCloud 设备备份是另外一项 Apple 功能，其范围由你的系统设置决定。

### 四、网络传输的数据

为完成代理功能,本应用会向以下目标发送网络请求：

1. **你自己配置的订阅源 URL**：刷新节点列表时会向这个 URL 发起 HTTPS 请求。请求内容仅包含 User-Agent 头,不带任何个人信息。
2. **你选中的代理节点服务器**：开启 VPN 后,你的网络流量会通过这台服务器转发。这台服务器由你自己选择和信任,**我们不运营、不监控、不记录**任何经过它的流量。
3. **公共 DNS 解析服务**：默认配置使用 Google `8.8.8.8` 与 Cloudflare `1.1.1.1` 解析域名,规则模式下国内域名会经过阿里 `223.5.5.5` 解析。这些是公共 DNS 服务,我们不与他们共享任何个人信息,他们的隐私政策见各自官网。

4. **辅助请求**：公网 IP 信息查询、测速目标、App Store 版本查询、规则与 geo 数据下载会请求相应公开服务；请求目的在对应功能中显示。这些服务可看到网络请求的来源 IP 及所请求的资源，应用不会附带设备标识符或上传本地访问历史。订阅 URL 和节点凭据只用于你配置的订阅/节点服务及上文所述个人 iCloud 配置镜像。

### 五、第三方服务

本应用**不集成任何第三方 SDK**。引用的开源库均为本地编译进二进制,不进行网络通信(除上述代理与订阅功能外)。

- xray-core (Mozilla Public License 2.0) — 代理核心
- libXray (MIT) — xray-core 的 iOS / macOS binding
- Yams (MIT) — Clash YAML 解析

### 六、儿童隐私

本应用**面向 17 岁以上用户**。我们不会有针对性地收集 13 岁以下儿童的数据(因为我们对所有用户都不收集数据)。

如果你是父母或监护人,发现孩子在使用本应用,可以直接卸载应用 —— 设备上的所有本地数据会一并删除。

### 七、你的权利

开发者不持有你的配置或访问历史。你可以管理设备本地数据及个人 iCloud 配置镜像：

- **访问 / 导出数据**：配置以 JSON 保存在应用本地与个人 iCloud 文档容器中；节点与日志可通过应用相应导出入口导出
- **删除数据**：卸载应用会删除应用本地数据；个人 iCloud 文档和历史版本需在「文件」App / Finder 中单独删除
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

The following data is stored locally. Configuration may also be mirrored as described below; access and measurement histories are excluded from that mirror:

| Data | Purpose | Location |
|---|---|---|
| Subscription URLs | Refresh node lists | `~/Documents/VPN/state.json` (iOS sandbox) |
| Node info (protocol / host / port / credentials) | Establish VPN connections | same |
| Custom routing rules | Decide proxy / direct / reject | same |
| Settings (theme, log level, sort) | UI personalization | same |
| Latency measurements | Node ranking | same |

**iCloud configuration mirroring is enabled by default.** When you are signed in to iCloud with iCloud Drive enabled, subscription URLs, node configuration (including connection credentials), custom rules, and settings are mirrored to the Qingzhou document container in your personal iCloud Drive, with up to five rolling versions. You can disable mirroring in Settings. This stops future synchronization and does not automatically delete existing cloud files. To remove them, delete the configuration document and backups directory from Qingzhou in Files / Finder. The document is JSON without additional application encryption; anyone with access to it can read the node credentials. We do not operate this storage service or have access to your personal iCloud configuration.

Connection and domain access records, daily domain summaries, rule-hit counters, node measurements, observed bandwidth, and extension memory diagnostics remain local and are excluded from the configuration mirror. They support analysis, selection, and troubleshooting and are not sent to the developer. System iCloud device backup is a separate Apple feature governed by your system settings.

### 4. Data transmitted over the network

To perform proxy duties, the App makes network requests to:

1. **Your subscription URL** — HTTPS request to refresh node list. Only carries a User-Agent header.
2. **Your chosen proxy server** — Your traffic flows through this server, chosen and trusted by you. **We do not operate, monitor, or log** any traffic through it.
3. **Public DNS resolvers** — Google `8.8.8.8` and Cloudflare `1.1.1.1` by default; AliDNS `223.5.5.5` for Chinese domains in rule mode. We do not share any personal information with these services.

4. **Supporting requests** — Public IP lookups, test targets, App Store version checks, and rule / geo-data downloads contact the relevant public services. Those services may observe the source IP and requested resource. The App does not attach device identifiers or upload local browsing history. Subscription URLs and node credentials are used for your configured services and the personal iCloud configuration mirror described above.

### 5. Third-party services

The App **integrates no third-party SDKs**. Open-source libraries are statically linked and perform no network communication beyond the proxy / subscription functions described above.

- xray-core (Mozilla Public License 2.0) — proxy core
- libXray (MIT) — iOS / macOS binding for xray-core
- Yams (MIT) — Clash YAML parsing

### 6. Children's privacy

The App is intended for users **17 years of age or older**. We do not knowingly collect data from children under 13 (and we do not collect data from anyone, regardless of age).

### 7. Your rights

The developer holds no copy of your configuration or access history. You control local data and the personal iCloud configuration mirror:

- **Access / Export** — Configuration is stored as JSON locally and in your personal iCloud document container. Node and log exports are available in the App.
- **Delete** — Uninstalling removes application-local data. Remove personal iCloud documents and history separately in Files / Finder.
- **Revoke** — iOS Settings → General → VPN & Device Management → remove the VPN profile

### 8. Changes to this policy

Updates to this policy will be committed to this repository and noted in the App release notes.

### 9. Contact

GitHub Issues: https://github.com/qingzhou-app/qingzhou/issues

---

> 本政策中文版本与英文版本如有歧义,以中文版为准。
> In case of any discrepancy, the Chinese version prevails.
