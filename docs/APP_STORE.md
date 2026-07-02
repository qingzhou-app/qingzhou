# 轻舟 / Qingzhou — App Store 上架准备

> S4 sprint 的产物。这是个 living checklist —— 每完成一项划掉,每发现新坑补上。

---

## 0. ⚠️ 必读 / 提交前致命问题

### 0.1 个人开发者账号 vs Apple Guideline 5.4

Apple App Store Review Guideline 5.4 原文：

> "Apps offering VPN services must utilize the NEVPNManager API and **must only be
> offered by developers enrolled as an organization.**"

**翻译**：VPN app 只能由 Apple Developer **Organization** 账号提交,Individual 账号会直接被拒。

**现状**：用户当前是个人开发者账号 (Team ID `UK7MME38H9`)。**需要解决**：

- 方案 A：升级 / 换到 Organization 账号 (需要 D-U-N-S 编号,免费申请,7–14 天)
- 方案 B：跟一个已有 Organization 账号的朋友 / 工作室合作,以他们名义提交
- 方案 C：先以 TestFlight 内测形式分发 —— 内测不受 5.4 限制,但只能 100 个外部测试员

**这一项不解决,后面所有文案都白写。** 推荐方案 A,先把流程跑起来。

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
| Bundle ID | `com.sbraveyoung.qingzhou.ios` | 不改,已配 entitlement |
| 主语言 | 简体中文 | 副语言 / 英文 / 日文 等待 S11 |
| 类目 | 工具 (Utilities) | **不要**选 "效率" 或 "社交" —— VPN 类一律工具 |
| 定价 | 免费,无 IAP | 不需要 IAP 合同 / 订阅条款 |
| 适用年龄 | 17+ | VPN 类必填,Apple 对未限定年龄的网络访问类 app 一律要求 17+ |
| 支持 URL | `https://github.com/qingzhou-app/qingzhou/issues` | **提交前确保 repo 是 public 状态**,否则审核打不开 |
| 营销 URL | (同上) 或留空 | 不强制,留空也行 |
| 主体 | 待定 (见 0.1) | Org 账号问题不解决,这一项填什么都会被打回 |
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

- [ ] TestFlight 跑过至少 1 周,5+ 真实用户测试,无 crash
- [ ] 主流量场景跑通：trojan / vmess / vless / ss 都能开 VPN + 上 Google
- [ ] 关 VPN 后系统设置里 VPN 配置正确清理
- [ ] 杀进程再开,VPN 状态恢复正常

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
| 5.4 | "Must be enrolled as an organization" | **见 §0.1**,这是根本拦截,必须用 Org 账号 |
| 4.0 | 无明确价值 / 功能不全 | 确保所有 tab 都有内容,空状态有引导文案 |
| 5.1.1 | 隐私政策缺失或不准确 | URL 在 App Privacy 表 + 描述里都要有 |
| 5.1.5 | 收集敏感信息但未告知 | 我们零收集,无此风险 |
| 2.3.10 | 描述提及不存在的功能 | 不要写 "智能加速 / AI 选节点" 之类未实现功能 |
| 2.1 | 提交时 crash | TestFlight 没跑够 |
| 5.6.1 | 截图 / 描述误导 | 截图必须是真实 app 界面,不能放营销图 |

---

## 10. 接下来的下一步

按顺序：

1. ☐ **解决 Org 账号问题** (申请 D-U-N-S 或找合作方)
2. ☐ 找设计师 / 自己出 App 图标 (1 周内可定稿)
3. ☐ 把 [docs/PRIVACY.md](PRIVACY.md) 部署到 GitHub Pages,拿到稳定 URL
4. ☐ 按 §3 模板填好 App Store Connect 元数据
5. ☐ 按 §4 准备 5 张截图
6. ☐ Distribution 签名 + Archive + 上 TestFlight
7. ☐ 拉 5–10 个内测员跑 1 周
8. ☐ 提交审核
