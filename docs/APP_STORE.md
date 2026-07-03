# 轻舟 / Qingzhou — App Store 上架准备

> S4 sprint 的产物。这是个 living checklist —— 每完成一项划掉,每发现新坑补上。

---

## 0. ⚠️ 必读 / 提交前致命问题

### 0.1 个人开发者账号 vs Apple Guideline 5.4 — ✅ 已解决（2026-07-03 组织账号注册完成）

Apple App Store Review Guideline 5.4 原文：

> "Apps offering VPN services must utilize the NEVPNManager API and **must only be
> offered by developers enrolled as an organization.**"

**翻译**：VPN app 只能由 Apple Developer **Organization** 账号提交,Individual 账号会直接被拒。

**状态**：✅ **组织版 Apple Developer 账号已注册完成（2026-07-03）**,硬阻塞解除。
注册过程记录见 [ORG_ACCOUNT.md](ORG_ACCOUNT.md)。当时的三个候选方案：

- [x] 方案 A：升级 / 换到 Organization 账号 (D-U-N-S 编号 2026-07-01 拿到,注册完成) ✅
- ~~方案 B：跟一个已有 Organization 账号的朋友 / 工作室合作,以他们名义提交~~（不再需要）
- ~~方案 C：先以 TestFlight 内测形式分发~~（不再需要作为替代方案；TestFlight 仍是正式提审前的内测环节）

**注意**：新 Org 账号 = **新 Team ID**,所有签名资产（Bundle ID / App Group / NE capability /
iCloud 容器 / 证书 / profile）都要在新 team 下重建,踩坑点见 §10。

### 0.2 中国 App Store 现实

中国大陆 App Store 自 2017 年起几乎不接受任何 VPN 类 app —— 即使提交成功也会很快被下架。

可行的目标市场：

- 国际 App Store(美区为主,日区 / 港区次之)
- 用户用**非中国 Apple ID** 下载
- 不在中国地区做 ASO / 推广

这是 "目标用户在中国但 App 不在中国 App Store" 的常规打法,所有同类 app 都这样。

### 0.3 加密出口合规 (Encryption Export Compliance)

App 用了 TLS / xray-core,触发美国出口合规审查。但**99% 的情况能走 "Mass Market" 豁免**：

- App Store Connect 提交时需要填 "Uses Non-Exempt Encryption" → **No**
- 理由：用的是 Apple 系统标准 TLS,以及开源算法 (xray-core 内置的加密都是标准算法)
- 不需要单独提交 Year-End Self Classification Report (因为 No-exempt)

详见 [App Store Connect → App 信息 → 加密合规](https://help.apple.com/app-store-connect/#/dev88f5c7bf9)。

---

## 1. 决策摘要

| 维度 | 决定 | 备注 |
|---|---|---|
| App 名 (显示) | 轻舟 | CFBundleDisplayName,已在 `Apps/project.yml` 设好 |
| App 名 (App Store) | 轻舟 Qingzhou | 副标题用拼音,提高 ASCII 搜索覆盖 |
| Bundle ID | `com.sbraveyoung.qingzhou.ios` | 沿用;需在**新 org team** 下重新注册（见 §10 identifier 迁移注意） |
| 主语言 | 简体中文 | 副语言 / 英文 / 日文 等待 S11 |
| 类目 | 工具 (Utilities) | **不要**选 "效率" 或 "社交" —— VPN 类一律工具 |
| 定价 | 免费,无 IAP | 不需要 IAP 合同 / 订阅条款 |
| 适用年龄 | 17+ | VPN 类必填,Apple 对未限定年龄的网络访问类 app 一律要求 17+ |
| 支持 URL | `https://github.com/qingzhou-app/qingzhou/issues` | **提交前确保 repo 是 public 状态**,否则审核打不开 |
| 营销 URL | (同上) 或留空 | 不强制,留空也行 |
| 主体 | ✅ 组织账号 (2026-07-03 注册完成) | 硬阻塞已解除,见 §0.1 |
| 隐私政策 URL | (待生成 GitHub Pages 链接) | 文案见 [docs/PRIVACY.md](PRIVACY.md);**Apple 强制必填** |

---

## 2. 上架前 Checklist

### 代码 / 构建侧

- [ ] App 图标 1024×1024 PNG (不能带透明、不能圆角)
- [ ] iOS app icon set (`Assets.xcassets/AppIcon.appiconset`) 全尺寸
- [ ] macOS app icon set (S6 才管)
- [ ] LaunchScreen.storyboard 或 Launch Screen Info.plist 设置
- [ ] 真机上 Archive 出 `.ipa` 没 warning
- [ ] 关闭所有 `print()` / 多余 log (生产环境用 `Logger.minimumLevel = .warn`)
- [ ] `DEBUG` 块要确认不会在 Release build 编进二进制
- [ ] Crash 测试 (随便点几页,杀掉重开 5 次)

### App Store Connect 侧

- [ ] 应用名称 (中 / 英): 轻舟 / Qingzhou
- [ ] 副标题 (中 / 英): 见 [§3.2](#32-副标题)
- [ ] 关键词列表 (100 字符): 见 [§3.3](#33-关键词)
- [ ] 描述 (4000 字符): 见 [§3.4](#34-描述模板)
- [ ] 新功能 (What's New): 首版填 "首次发布" 即可
- [ ] 截图: 6.9" / 6.7" / 6.5" iPhone 各一组,iPad 12.9" / 11" 各一组 (见 [§4](#4-截图清单))
- [ ] App 图标 1024×1024
- [ ] 适用年龄: 17+
- [ ] 隐私清单 (App Privacy): 见 [§5](#5-app-privacy-填写)
- [ ] 加密合规: Uses Non-Exempt Encryption → **No**
- [ ] 内容版权声明: 自己持有 (用了 MIT / MPL 开源,无版权问题)
- [ ] 价格: 免费 (Free)
- [ ] 上架地区: 美区 + 港区 + 日区 + 韩区 + 新加坡 + 台湾 + 加拿大 + 澳洲 + 英国 + 欧盟 (**不勾**中国大陆)

### 提交前最后一道

- [ ] **审核测试节点**：Review Notes 里**必须**提供一个审核期间可用的节点 / 订阅（demo 用）,
  否则审核员无法验证核心功能,大概率 2.1 打回。节点要稳定（审核可能跨 2–3 天,期间不能挂）,
  审核结束后可作废轮换。附一段「粘贴此链接 → 添加节点 → 开启 VPN → 访问网页」的操作说明
- [ ] TestFlight 跑过至少 1 周,5+ 真实用户测试,无 crash
- [ ] 主流量场景跑通：trojan / vmess / vless / ss 都能开 VPN + 上 Google
- [ ] 关 VPN 后系统设置里 VPN 配置正确清理
- [ ] 杀进程再开,VPN 状态恢复正常
- [ ] [ACCEPTANCE.md](ACCEPTANCE.md) 待验收清单全部勾完（TestFlight / 开发版真机即可,不必等正式版）

---

## 3. App Store 文案模板

### 3.1 应用名称

```
中文：轻舟
英文：Qingzhou
```

> 名称栏 30 字符上限,这俩都很短没问题。
> Apple 不允许在名称里加 "Free" / "Pro" / "VPN" / "Best" 之类词。

### 3.2 副标题

副标题 30 字符,会显示在搜索结果列表里。

```
中文：节点订阅与网络配置工具
英文：Subscription & network config
```

> 避开 "VPN" / "翻墙" / "代理" 这种关键词,主打 "工具" 属性。

### 3.3 关键词

100 字符上限,逗号分隔,不要重复名称里的词。

```
节点,订阅,网络,配置,trojan,vmess,vless,hysteria2,xray,clash,shadowsocks,shortcuts,widget,proxy tool
```

> 关键词不要写完整句子。覆盖搜节点协议名的用户。

### 3.4 描述模板

```
轻舟是一款轻量的网络配置工具,帮助你管理各类节点订阅、自定义路由规则,
通过系统 VPN 框架(NetworkExtension) 转发本机流量。

特性
• 多协议支持: trojan / vmess / vless / shadowsocks / hysteria2,支持 Clash YAML 导入
• 订阅自动刷新、节点并发测速、一键择优、按地区优先 / 排除
• 智能分流: 中国域名直连、海外走代理,可自定义 GEOIP / IP-CIDR / DOMAIN 规则
• 流量洞察: 实时流量波形 + 域名分析(走代理 / 直连、命中规则、优化建议)
• 顺手体验: 切换节点 / 模式自动热重启、快捷指令与 Siri 一键开关
• 完全本地化: 节点 / 订阅 / 规则全部保存在本机,不上传任何服务器
• 不收集个人信息、不接入第三方分析、不放广告

工作原理
1. 你提供节点订阅链接,App 拉取节点信息保存在本地
2. 选择一个节点开启 VPN,系统弹出标准 VPN 授权对话框
3. xray-core 在后台 Extension 进程中运行,按你的规则路由流量

数据隐私
• App 不收集任何用户身份信息
• 你的订阅源 / 节点凭据存在 iPhone 本地,不会上传
• VPN 流量直接发往你自己选的节点,我们看不到、不记录
• 详见隐私政策: https://qingzhou-app.github.io/qingzhou/PRIVACY

注意事项
• App 不提供任何节点。你需要自己拥有节点或订阅源。
• 17 岁以上用户使用。本工具不应用于违反当地法律的用途。
```

**English version (for US / international store):**

```
Qingzhou is a lightweight network configuration utility that helps you manage proxy node
subscriptions, customize routing rules, and forward device traffic through Apple's system
VPN framework (NetworkExtension).

Features
• Multi-protocol: trojan / vmess / vless / shadowsocks / hysteria2, with Clash YAML import
• Auto-refreshing subscriptions, concurrent latency tests, one-tap best-node selection
• Smart routing: China domains direct, overseas via proxy; custom GEOIP / IP-CIDR / DOMAIN rules
• Traffic insight: live traffic waveform + per-domain analytics (proxy/direct, matched rule, tips)
• Niceties: hot-restart on node/mode switch, Shortcuts & Siri toggles
• Fully local: nodes / subscriptions / rules stay on your device, never uploaded
• No personal data collected, no third-party analytics, no ads

How it works
1. You provide subscription or share links; the app stores node info locally.
2. Pick a node and start the VPN — the system shows the standard VPN permission dialog.
3. xray-core runs in a background Extension process, routing traffic by your rules.

Privacy
• No user identity information is collected.
• Your subscription sources / node credentials stay on-device, never uploaded.
• VPN traffic goes straight to the node you chose — we can't see it and don't log it.
• Privacy policy: https://qingzhou-app.github.io/qingzhou/PRIVACY

Notes
• The app provides no nodes. You need your own nodes or subscription source.
• For users 17+. Do not use this tool for purposes that violate local laws.
```

> 4000 字符上限。**强烈建议在 "数据隐私" 一段照搬这个结构** —— Apple 审核很在意 VPN 类
> app 是否清晰声明数据政策。

### 3.5 新功能 (What's New) — 首版

```
首次发布。
• 多协议节点订阅(含 hysteria2)与智能分流
• 实时流量波形 + 域名分析
• 自动测速择优、切换节点 / 模式自动重启
• 快捷指令 / Siri 一键开关
```

---

## 4. 截图清单

### 4.1 必需尺寸

App Store 截图最新规则 (2024–2025)：

| 设备 | 像素 (竖屏) | 数量 |
|---|---|---|
| iPhone 6.9" (15 Pro Max / 16 Pro Max) | 1290 × 2796 | **必填** ≥ 3 张 |
| iPhone 6.5" (XS Max / 11 Pro Max) | 1242 × 2688 | 可继承 6.9" 自动缩放,但建议单独提供 |
| iPad Pro 12.9" / 13" | 2048 × 2732 | iPad 版本时必填,纯 iPhone 上架可不填 |

> 6.7" / 6.5" 尺寸 Apple 现在允许 6.9" 自动 fit。但首次上架建议都准备一套,降低被打回风险。

### 4.2 推荐截图场景 (按顺序排版)

1. **首页 — 节点列表 + 一个节点延迟绿色 + 当前 VPN 已连**
2. **订阅页 — 1 条订阅 + 进度条 + "节点 47" 等数字**
3. **节点页 — 测速进行中 / 自动择优进度**
4. **规则页 — 新加的下拉表单 (中文显示)**
5. **设置页 — "完全免费、无广告、无追踪" 视觉强调**

> 截图上叠 "卖点 caption" (1 句话标题 + 副标题) 比纯界面截图转化高 2–3 倍。
> 工具：[Screenshots.pro](https://screenshots.pro) / Figma 模板 / [Previewed](https://previewed.app)。

### 4.3 截图工作流(本地)

1. 在 iPhone 模拟器跑 Release build,选 "iPhone 15 Pro Max" / 16 Pro Max
2. Xcode → Devices → 模拟器右键 → "Save Screen Recording" 或 ⌘S 截图
3. 截图自动落 Desktop,导入 Figma / Screenshots.pro 加 caption + 设备 frame
4. 导出 1290×2796 PNG / JPEG (Apple 接受这两种)

---

## 5. App Privacy 填写

App Store Connect → App Privacy 是个必填表单,问 12 类数据。基于当前架构,标准答案是：

| 类别 | 是否收集 | 说明 |
|---|---|---|
| Contact Info | No | App 不要求邮箱 / 电话 / 名字 |
| Health & Fitness | No | — |
| Financial Info | No | — |
| Location | No | — |
| Sensitive Info | No | — |
| Contacts | No | — |
| User Content | No | 节点 / 订阅 / 规则全部本地存储,不上传 |
| Browsing History | No | App 不记录访问历史 |
| Search History | No | — |
| Identifiers | No | 不用 IDFA / IDFV / advertisingIdentifier |
| Purchases | No | 没 IAP |
| Usage Data | No | 不接入 Firebase / Google Analytics / 第三方统计 |
| Diagnostics | No | crash log 由 iOS 系统自己采集,App 不主动上传 |
| Other Data | No | — |

> **重要**：第三方 SDK 如果之后加了 (例如 Sentry / Bugsnag),要重新过这张表。

---

## 6. App 图标设计要求

| 用途 | 尺寸 | 备注 |
|---|---|---|
| App Store 列表 | 1024 × 1024 | PNG,**不能透明**,**不能圆角** (Apple 自动加),不能带 alpha 通道 |
| iOS 应用图标集 | 多个 (放 `AppIcon.appiconset/Contents.json` 里) | 用 Xcode 内置图标生成器或 [appicon.co](https://appicon.co) 一键生成 |
| iOS 设置 | 87 × 87 | 自动从 AppIcon 缩放 |
| iPad | 167 × 167 | 同上 |

### 设计建议 (针对 "轻舟" 主题)

- **主元素**：一艘极简风格的小舟剪影,水平线之上,或一片清雅的水波纹
- **配色**：浅蓝 + 米白,或深蓝 + 浅金 (避开红色 —— 红色在中国市场某些场景有禁忌)
- **风格**：扁平 / 拟物折中,跟 iOS 17+ 系统风格契合
- **避坑**：图标里**不要**出现 "网络 / 地球 / 锁 / 防火墙" 这类暗示 VPN 用途的元素

> 找设计师建议预算 ¥500–2000。或者自己用 Figma / Sketch + Apple HIG 模板做一个。

---

## 7. TestFlight 流程

### 7.1 准备 Distribution Build

```bash
# 在 Xcode 里 Product → Archive (用 Apple Distribution profile 而非 Development)
# 或命令行:
xcodebuild archive \
  -project Apps/Qingzhou.xcodeproj \
  -scheme Qingzhou-iOS \
  -archivePath build/Qingzhou.xcarchive \
  -destination 'generic/platform=iOS' \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=UK7MME38H9
```

Archive 完成后从 Organizer 上传到 App Store Connect (按 "Distribute App" → "App Store Connect" → "Upload")。

### 7.2 配 TestFlight

1. App Store Connect → 进入 App → 左侧 TestFlight 标签
2. 新版本上传后等 5–30 分钟做内部处理 (Processing)
3. 加 **Internal Testers** (你自己 + Apple ID 团队成员,无审核)
4. 内测稳定后加 **External Testers** (邮件邀请或邀请链接,首次需 Apple **Beta App Review**,通常 1–2 个工作日)

> External TestFlight 链接是公开的,可分享 —— 这是初期吸引种子用户最方便的渠道。

### 7.3 内测周期 (推荐 ≥ 1 周)

- 找 5–10 个真实用户用 1 周
- 关注 crash report (App Store Connect → TestFlight → Crashes)
- 收集反馈 (邮件 / 群聊 / GitHub Issues 都行)
- 至少经历 1 次 "杀进程后重开 / 切换网络环境 / 长时间运行" 全场景

---

## 8. 正式提交流程

1. App Store Connect → App → 准备提交版本 → 把所有元数据填全
2. 选择 build (TestFlight 上传的某一版)
3. 点 **Submit for Review**
4. 等审核 (近两年平均 24–72 小时,VPN 类可能更长)
5. 如被拒,看 Resolution Center 里 Apple 给的具体引用条款 → 改 → 重提

---

## 9. 常见拒绝点 (VPN 类高发)

| 编号 | 内容 | 应对 |
|---|---|---|
| 5.4 | "Must be enrolled as an organization" | ✅ 已解决 —— 组织账号已注册（见 §0.1）,用新 org team 提交即可 |
| 2.1 | 审核员无法验证功能（没有可用节点） | Review Notes 里提供**审核测试节点**（见 §2「提交前最后一道」与 §10 材料清单） |
| 4.0 | 无明确价值 / 功能不全 | 确保所有 tab 都有内容,空状态有引导文案 |
| 5.1.1 | 隐私政策缺失或不准确 | URL 在 App Privacy 表 + 描述里都要有 |
| 5.1.5 | 收集敏感信息但未告知 | 我们零收集,无此风险 |
| 2.3.10 | 描述提及不存在的功能 | 不要写 "智能加速 / AI 选节点" 之类未实现功能 |
| 2.1 | 提交时 crash | TestFlight 没跑够 |
| 5.6.1 | 截图 / 描述误导 | 截图必须是真实 app 界面,不能放营销图 |

---

## 10. 接下来的下一步（组织账号已就位,2026-07-03 更新）

> 前提已达成：✅ 组织账号注册完成（见 §0.1）。下面按顺序走,每步做完勾掉。
> 贯穿注意：**新 Org 账号是全新 Team ID**,原个人账号 (Team `UK7MME38H9`) 下的所有
> 签名资产都不通用,要在新 team 下重建。

### 10.1 新 team 下重建 identifier / capability

1. ☐ 用新 org 账号登录 [developer.apple.com](https://developer.apple.com) → Certificates, Identifiers & Profiles
2. ☐ **注册 Bundle ID**（现有 4 个 + 后续 Widget 扩展的）：
   - `com.sbraveyoung.qingzhou.ios` / `.macos` / 两个 Tunnel 扩展 id（以 `Apps/project.yml` 为准）
   - ⚠️ **identifier 全局唯一性**：Bundle ID / App Group / iCloud 容器这类 identifier 是
     **跨 team 全局唯一**的。旧个人账号已注册的同名 identifier,新 team 直接注册会**冲突**。
     两条路：**先在旧账号后台删除（释放）这些 identifier** 再到新 team 注册同名（推荐,
     代码零改动）；或改用新命名（代价大：要同步改 `Apps/project.yml` 的 bundle id、
     `entitlements.properties` 里的 App Group、代码里的常量如
     `CloudVaultStore.containerIdentifier`,再 `xcodegen generate`）
   - ⚠️ 释放旧 identifier 前确认旧账号没有还想保留的 TestFlight 构建绑在上面
3. ☐ **App Group** `group.com.sbraveyoung.qingzhou`：新 team 下注册 + **Edit 关联到全部 App ID**
   （主 App ×2 + Tunnel ×2；漏了 = 流量波形 / 连接列表 / 域名分析全部无数据,老坑）
4. ☐ **Network Extensions capability**：给 4 个 App ID 勾上 NE（packet tunnel 是自助勾选,
   无需特批;macOS content filter 的 system extension 同理）
5. ☐ **iCloud 容器** `iCloud.com.sbraveyoung.qingzhou`：新 team 下注册 + 关联到主 App
   的 App ID（iCloud 保险柜同步用,见 `project.yml` 的 icloud-container 注释）
6. ☐ `Apps/project.yml` 里 5 处 `DEVELOPMENT_TEAM: UK7MME38H9` 全部换成**新 Team ID**
   → `cd Apps && xcodegen generate`（记住:改 project.yml,别手改工程文件）

### 10.2 证书 / Profile

7. ☐ 新 team 创建 **Apple Distribution** 证书（Xcode → Settings → Accounts 里也可自动管理）
8. ☐ 为每个 Bundle ID 生成 **App Store provisioning profile**（用 Xcode 自动签名的话,
   登录新账号 Apple ID 后选新 team 即自动处理;手动签名则逐个建）
9. ☐ 真机 ⌘R 用新 team 签名跑一次全功能回归（VPN 开关 / 流量 / iCloud 同步都要动一下,
   验证 App Group 与 iCloud 容器在新 team 下真的通）

### 10.3 App Store Connect 建 App + 元数据

10. ☐ App Store Connect（新 org 账号）→ My Apps →「+」New App：
    平台 iOS、名称「轻舟」、主语言简体中文、Bundle ID 选 10.1 注册的、SKU 自定（如 `qingzhou-ios-001`）
11. ☐ 把 [PRIVACY.md](PRIVACY.md) **生效日期填上** → 部署 GitHub Pages,拿到稳定 URL
    （**提交前确认 repo 是 public**,否则审核打不开支持 URL / 隐私 URL）
12. ☐ 按 [§3](#3-app-store-文案模板) 填名称 / 副标题 / 关键词 / 描述 / What's New
13. ☐ 按 [§5](#5-app-privacy-填写) 填 App Privacy（全 No）;加密合规选 **No**（见 §0.3）
14. ☐ 上架地区按 [§2](#2-上架前-checklist)（**不勾**中国大陆）;年龄 17+;价格免费

### 10.4 图标 / 截图 / 素材

15. ☐ 1024×1024 图标导出（源 `docs/icon/*.svg`,无透明无圆角）+ appiconset 全尺寸确认
16. ☐ 按 [§4](#4-截图清单) + [§11 宣发素材需求清单](#11-宣发素材需求清单) 拍截图（VPN 连接态必须真机）

### 10.5 Archive → TestFlight → 提审

17. ☐ Archive + 上传（§7.1 命令里 `DEVELOPMENT_TEAM` 换新 Team ID;Release 配置确认
    没把 `DEBUG` 块编进去）
18. ☐ TestFlight：先 Internal（自己的设备全场景过一遍）→ 再 External
    （首次需 Beta App Review,1–2 工作日;External 链接可公开分享拉种子用户）
19. ☐ 内测期间同步完成 [ACCEPTANCE.md](ACCEPTANCE.md) 全部待验收项（TestFlight / 开发版真机即可）
20. ☐ 内测 ≥1 周、5+ 用户、无 crash（§7.3）
21. ☐ **提审材料清单**（Review Notes 一次备齐,别挤牙膏）：
    - **审核测试节点 / 订阅**（关键!见 §2「提交前最后一道」）：稳定可用的 demo 节点链接 +
      「粘贴 → 添加 → 开 VPN → 打开网页」的分步说明
    - 说明信要点：App 不预设 / 不运营任何节点,用户自带订阅;不涉及 IAP;
      数据零收集(与 App Privacy 表一致);17+;隐私政策 URL
    - 截图 / 元数据与实际功能一致(别提未上线的功能,防 2.3.10)
22. ☐ Submit for Review;被拒看 Resolution Center 引用条款 → 对照 [§9](#9-常见拒绝点-vpn-类高发) 修 → 重提

---

## 11. 宣发素材需求清单

> 服务两处：App Store 截图（§4 规格）+ 社区宣发（[MARKETING.md](MARKETING.md) 的 GitHub /
> Telegram / Product Hunt 等）。**谁来拍**的原则：凡是要 **VPN 连接态 / 真实流量数据** 的,
> 只能**用户在真机上拍**（模拟器跑不了 VPN 扩展）;纯静态页面模拟器可出。

### 11.1 截图清单（谁拍 / 哪台设备）

| # | 场景 | 用途 | 谁拍 / 设备 |
|---|---|---|---|
| 1 | 首页 · VPN 已连接（波形有真数据 + 双公网 IP + 代理/直连占比） | App Store 首图 + 社区 | **用户 · iPhone 真机** |
| 2 | 节点列表 · 延迟 chip 绿色（含经代理延迟第二 chip） | App Store + 社区 | **用户 · iPhone 真机**（需开 VPN） |
| 3 | 批量测速进行中 / 自动择优 toast | App Store | **用户 · iPhone 真机** |
| 4 | 域名分析页（真实域名聚合 + 规则建议） | App Store + 社区 | **用户 · iPhone 真机**（需真实流量积累） |
| 5 | 规则页（含完整版 geo 一键下载控件） | App Store | 模拟器可（Claude/脚本可出） |
| 6 | 订阅页（1 条订阅 + 节点数） | App Store | 模拟器可（用演示订阅数据） |
| 7 | 设置页（零收集 / 无广告视觉强调） | App Store | 模拟器可 |
| 8 | macOS 主窗口全貌 | 社区 / 后续 macOS 上架 | **用户 · Mac 真机**（连接态） |
| 9 | 小组件 / 控制中心开关 | App Store 更新版 + 社区 | **用户 · iPhone 真机**（等 Widget 实现合并） |

> 规格按 §4.1（6.9" 1290×2796 必备 ≥3 张）;真机截图注意用 6.9" 机型或后期放进设备 frame。
> 加 caption 的排版工具见 §4.2 注。

### 11.2 录屏 / GIF 场景列表（社区宣发用,GitHub README / PH / 电报群）

| # | 场景（≤15 秒 / 条） | 卖点回扣（MARKETING §2 编号） | 谁录 |
|---|---|---|---|
| 1 | 一键批量测速 → 自动择优切换 toast | ① 自动择优 | **用户 · 真机** |
| 2 | 粘贴分享链接秒加节点 / Clash YAML 一键导入 | ⑪ 快速迁移 | 模拟器可 |
| 3 | macOS 开 VPN → 终端直接 `curl google.com` 通（无需 export 代理变量） | ⑧ TUN 模式 | **用户 · Mac 真机** |
| 4 | 定时关闭：设 30 分钟 → 到点自动断开 | ② 定时关闭 | **用户 · 真机**（可快进） |
| 5 | 域名分析页滚动浏览 + 点开趋势详情 + 一键加规则 | ⑤ 域名分析 | **用户 · 真机** |
| 6 | 锁屏 / 控制中心小组件开关 VPN | ⑦ 小组件自动化 | **用户 · 真机**（等 Widget 合并） |
| 7 | Siri / 快捷指令喊一句开 VPN | ⑦ 自动化 | **用户 · 真机** |
| 8 | iCloud 历史版本找回（误删订阅 → 恢复） | ⑩ iCloud 同步 | **用户 · 双设备** |

> 录屏用 iOS 自带屏幕录制 / macOS QuickTime;转 GIF 可用 `ffmpeg` 或 Gifski,
> GitHub README 建议单条 <5MB。
