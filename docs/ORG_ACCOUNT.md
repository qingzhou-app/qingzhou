# Apple Developer Organization 账号 — 从 Individual 升级 / 注册指南

> ✅ **已完成（2026-07-03）**：组织账号注册完成,[App Store 上架](APP_STORE.md) 的硬阻塞解除,
> 后续在新 org team 下重建签名资产的步骤见 [APP_STORE.md §10](APP_STORE.md)。
> 以下保留注册过程指南备查。
>
> 背景：个人(Individual) Apple Developer 账号无法提交 VPN 类 App,必须用 Organization 账号
> （见 [APP_STORE.md §0.1](APP_STORE.md)）。本指南整理 D-U-N-S 编号申请、Apple Org Enrollment、
> 过渡期 TestFlight 方案。

---

## 0. 你需要知道的事

1. **个人账号 ≠ 组织账号**:Apple 不支持"升级",你需要 **重新注册** 一个 Organization 账号。
   - 原 Individual 账号仍然有效,继续付 $99/年,可以做开发 / Internal TestFlight 内测
   - 新 Org 账号也是 $99/年,**两个账号付两份费**
   - 两个账号都用同一个 Apple ID 不行 —— 一个 Apple ID 同时只能绑一个开发者会员;
     **新 Org 账号必须用不同 Apple ID 注册**(可以是新建的)
2. **Org 注册周期**:
   - 自己有公司 / 个体户营业执照:1–2 周
   - 没有,需要先注册 LLC / 个体户:2–6 周(国内个体户走个体工商户最快)
3. **关键前置**:**D-U-N-S 编号**(Dun & Bradstreet 给的全球企业唯一识别号)。Apple 注册 Org
   时必填,但 Apple 接受免费申请的 D-U-N-S(走 [Apple 专用入口](https://developer.apple.com/enroll/duns-lookup/))。

---

## 1. D-U-N-S 编号 — 免费申请

### 1.1 先查你公司是否已经有

去 https://developer.apple.com/enroll/duns-lookup/ ,填**法定公司名 + 地址 + 国家**,直接搜。

- 如果搜到匹配条目 → 已经有,记下 9 位 D-U-N-S 编号(8 字开头一般是中国大陆主体)
- 没搜到 → 走下面 1.2 申请

> 上面这个 Apple 入口比直接去 Dun & Bradstreet 官网快得多。D&B 官网走 30 天,Apple 入口 通常 3–7 个工作日。

### 1.2 申请新 D-U-N-S(免费)

在上面那个 lookup 页面没搜到匹配后,会出现 "Request a D-U-N-S Number" 按钮。点进去填：

| 字段 | 怎么填 |
|---|---|
| Legal Entity Name | **跟你营业执照上的中文 / 英文名严格一致**。少一个字符都会被退 |
| DBA / Trade Name | 商号(如果有别名)。没有就填法定名 |
| Address | 营业执照地址。中国大陆一般写英文化格式 |
| Phone | 工商登记电话 |
| Contact Name & Email | 公司联系人(可以是你自己) |
| Industry | 软件 / 信息技术(Software / IT) |
| Annual Revenue | 估算填,允许范围:"$0–$100K" 都行 |
| Employees | 1 也可以填 |

Apple 会把请求转给 D&B 审核。3–7 个工作日内邮件通知 D-U-N-S 编号。

### 1.3 没有公司怎么办

D-U-N-S 必须有"合法商业实体"。三种思路:

- **注册个体工商户**(中国大陆):线上可办,300–500 元代办费,7–14 天拿照
- **注册有限公司 / LLC**:走当地工商,1–4 周,根据地区不同费用 0–5000 元
- **借朋友的公司**(不推荐):后续 Org 账号实名认证 / 银行账户都跟主体绑死,以后转让很麻烦

> 个体工商户最快最便宜,选这个就行。

---

## 2. Apple Developer Organization Enrollment

拿到 D-U-N-S 后,在 https://developer.apple.com/enroll/ 走注册。

### 2.1 准备资料

- **D-U-N-S 编号**(刚拿到的)
- **新的 Apple ID**(原 Individual 账号那个 Apple ID 不能复用)
- **新 Apple ID 必须开了双重认证**(System Settings → Apple ID → Security → Two-Factor)
- **Legal Entity Name 完全跟 D-U-N-S 注册时一致**
- **你是该实体的 Legal Authority** —— 你需要有权代表公司签合同(法人 / 授权代表)
- **付款方式**:支持中国境内信用卡 / 借记卡 + Apple ID 已绑银联

### 2.2 提交后

- Apple 自动验证 D-U-N-S 是否生效(2–3 天)
- 验证通过后会**打个国际电话过来**确认你的身份和组织身份 —— 接到陌生英文电话别挂,会说自己 Apple
- 电话核实后审批通常 2–7 个工作日

总时长:从开始到能登录 App Store Connect 大约 **2–4 周**。

### 2.3 注册成功后立刻做的事

1. 把新 Team ID(类似 `UK7MME38H9` 这种 10 位字符串)记下来,这是新的开发团队 ID
2. 在 App Store Connect 创建一个 App Record,Bundle ID 仍然是 `com.sbraveyoung.qingzhou.ios`(Bundle ID
   是全球唯一的,但**只跟一个开发者账号绑死** —— 如果你原来在 Individual 账号下也注册了同一个 ID,**先 unregister**)
3. 把 Apps/project.yml 里 `DEVELOPMENT_TEAM` 改成新 Team ID,重跑 xcodegen
4. 重新生成 Distribution profile

> 项目里要改的地方:
> `Apps/project.yml` 里有 5 处 `DEVELOPMENT_TEAM: UK7MME38H9` 要换。
> Production 签名也要重新做。

---

## 3. 过渡期 / 等账号期间能干的事

新 Org 账号还在审核期间(2–4 周),你不能正式提交 VPN App,但可以:

| 能做 | 怎么做 |
|---|---|
| 继续用旧 Individual 账号做开发 | 当前的 `UK7MME38H9` 还能正常 build / 装真机 |
| Internal TestFlight 内测 | Internal Testers(最多 25 人,都是你 App Store Connect Team 里的人)不受 Guideline 5.4 限制 |
| 整理 App 文案 / 截图 / 图标 | 这些都跟账号性质无关 |
| 部署 Privacy Policy / Support URL | 见 [GitHub Pages 准备](APP_STORE.md#102-把-docsprivacymd-部署到-github-pages) |
| 找种子用户 | 在朋友圈 / 微信群 / Telegram 收集"愿意内测的人",拿到 Apple ID 邮箱 |
| 跑回归测试 | 跑通 trojan / vmess / vless / ss 四种节点 |

**不能做**:External TestFlight(对外公开邀请),正式审核提交。

---

## 4. 注册过程踩坑提醒

- **D-U-N-S 申请阶段 Legal Entity Name 跟营业执照对得上一字不差**。中文带英文要把所有空格 / 标点对齐,Apple
  自动对比时严格匹配
- **银行账号信息**:Org 账号最终在 App Store Connect 里收款时,需要绑公司银行账户(不能是个人卡)。
  现在用 Free pricing 暂时不用管,以后想加 IAP / 卖钱要补
- **Tax form W-8BEN-E**:Apple 美国总部要你填这张表证明你不是美国纳税居民(避免双重扣税)。
  Org 账号必填,Individual 也填过,流程一样。
- **续费别忘**:每年 $99,断了过 30 天 App 会下架。设个日历提醒
- **Org 账号下原 Individual 账号开发的 App 不会自动迁移** —— 我们这个 App 本来就还没上架,无所谓;
  但如果你以后要把已上架的 app 从 Individual 转 Org,要走 [App Transfer](https://developer.apple.com/help/app-store-connect/transfer-an-app/overview-of-app-transfer/)
  ,流程稍麻烦

---

## 5. 快速 FAQ

**Q: 我能不能跳过 Org,只走 TestFlight 公开内测?**
A: External TestFlight 也算 "向公众提供 VPN 服务",依然会卡 5.4。Internal TestFlight(25 人内)不卡,但用户数太少不能算 "上架"。

**Q: 借朋友的 Org 账号代提呢?**
A: 技术上可行 —— Apple 不禁止代理提交。但 App 在 App Store 上**显示的开发者名字**就是朋友的公司名,
不是你。以后想拿回所有权要走 App Transfer。短期可行,长期不建议。

**Q: 中国地区注册的 Org 账号能在国际 App Store 上架吗?**
A: 能。Org 账号在哪个国家注册不影响 App 上架地区。

**Q: $99 + $99 + 注册公司的钱,总成本多少?**
A: Apple 个人会员 $99/年 + Org 会员 $99/年 + 个体工商户 ¥300–500 一次性(以后年报 0–300/年)。
首年大概 ¥1700–2500。

---

## 6. 你今天能做的最小可行动作

1. 去 https://developer.apple.com/enroll/duns-lookup/ 搜你的法人名 → 看有没有现成 D-U-N-S
2. 没有 → 同页面 Request 一个,3–7 天到位
3. 没注册公司 → 决定用个体工商户还是 LLC,网上找代办或自己跑工商
4. 同时回到 [APP_STORE.md](APP_STORE.md) 把图标 / 截图 / 文案这些**跟账号无关**的物料先做了
