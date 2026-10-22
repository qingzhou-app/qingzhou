# 轻舟宣发文稿与六平台内容包

版本：2026-10-23；以 build33 已交付能力与 build34 恢复交互修复为依据。面向已有合法网络服务/节点配置的 iPhone、Mac 用户、AI 开发者及创作者。定位为客户端，不销售线路，不包含 Claude 等服务订阅。以下是待发布稿，未向任何平台发布；没有假定 App Store 上架、价格或下载链接已确定。

## 1. 定位与主文稿

**主标题：轻舟，适用于 AI 时代的连接管理。**

**副标题：看懂为什么选这条线路，也看清流量用在了哪里。**

**一句话介绍：** 为 iPhone 和 Mac 的 AI 工作流提供可解释的节点择优、分层连接诊断与本地月度域名流量统计。

**发布正文：**

每天在 Claude、ChatGPT、Gemini 和开发工具之间切换，我们越来越需要知道：当前连接到底有没有生效？为什么选了这条线路？上传和下载又花在了哪些域名上？

轻舟围绕这些日常问题，做了三件具体的事。

第一，让择优有解释。结合代理测量、历史稳定性、近期下载观测和已识别的节点倍率，给出综合判断；通过切换门槛减少因小幅波动产生的无谓换线，并显示本次选择或保持的原因。

第二，让排查分层。服务器 TCP 能连上，与真实代理请求能完成，是两件不同的事。轻舟分别展示诊断结果；对 Hysteria2 等 UDP 协议，不用 TCP 失败直接判定节点不可用。

第三，让流量有去向。月度域名排行区分代理、直连、上传和下载。遇到流量消耗突然加快，可以先看谁占得多、是上传还是下载。账本保存在本机，隧道运行时，即使主程序退出也能继续记录。

我们希望你把时间留给 AI 工作本身，把连接选择和流量排查变得更清楚。

轻舟目前提供 iOS 17+、macOS 14+ 客户端。实际连通性取决于节点、网络与目标服务；月度统计从启用新版后开始，统计的是经过轻舟的应用载荷，并非服务商账单。

**短版：**

轻舟，适用于 AI 时代的连接管理。为什么选这条线路，有解释；流量去了哪里，有域名账本。iPhone / Mac，可解释择优、分层连接诊断、本地月度流量排行。

**英文版：**

Qingzhou — connection management for the AI era.

Understand why a proxy node was selected. Separate TCP reachability from proxy request results. See monthly traffic by domain, with upload/download and proxy/direct breakdowns stored locally.

Built for iPhone and Mac workflows involving AI tools and everyday apps. Bring your own proxy configuration. Connectivity depends on your network, provider and destination service. Traffic totals are payload observations, not provider billing records.

## 2. “Claude 不会被封号”怎么写

不能把它写成产品承诺，也没有证据支持“降低封号率”。官方说明列出的封禁原因包括使用政策、服务条款及不支持地区注册等；客户端不能控制平台的账号处置。依据：[Claude 官方封禁与申诉说明](https://support.claude.com/en/articles/8241253-safeguards-warnings-and-appeals)。

| 不采用的说法 | 可直接使用的替代表述 |
|---|---|
| Claude 永不封号／保证不封号 | 为 Claude 等 AI 工具的日常使用，提供更清楚的连接管理与排查信息 |
| AI 防封算法／降低封号概率 | 可解释的节点择优与切换门槛，减少小幅波动导致的无谓换线 |
| 固定纯净 IP、住宅 IP | 支持已有节点配置；出口 IP 及线路质量由你的服务商决定 |
| 全球都能用 Claude／解除地区限制 | 服务可用性、支持地区和账号使用须遵守目标平台规则 |
| 不断流、零中断、永远最快 | 可查看线路测量和保持原因；切换可能需要重建连接 |
| AI 自动训练最优线路 | 使用综合评分、时效与防抖策略；当前不是机器学习模型 |

**评论区回答：**

“能保证 Claude 不封号吗？”——不能。轻舟管理的是连接和流量，不是 Claude 的账号规则。它能帮助你区分线路连接问题与代理请求问题，也能减少小幅波动导致的无谓换线；平台地区、账号与使用政策仍需遵守。

“Claude 连接异常是不是账号被封？”——不一定。先区分网络连通和账号状态；轻舟的诊断不能认定或解除账号封禁。

## 3. 与竞品比较：突出我们的产品组合，不编造独占能力

核对日期为2026-10-23。以下比较特定文档描述的策略，不代表完整产品功能、速度排名或同环境性能测试。

| 对比对象 | 官方已公开的能力 | 轻舟可强调的差异与边界 |
|---|---|---|
| Surge Smart | 从真实连接首响应时间、TCP重传等评估质量，具有按站点的记忆与重试；文档也描述UDP信号和分批测试 | 我们侧重综合择优解释、倍率因素和本地月度域名账本的统一体验。当前全局选一个节点，不具备同等的逐站点自动选路；不能宣称算法全面领先。依据：[Surge Smart](https://manual.nssurge.com/policy-groups/smart.html) |
| Stash url-test | 定期检测并选择低延迟节点，跳过不健康节点 | 我们在单一延迟之外结合多个评分因素，呈现选择/保持理由；这不是对Stash全部策略与功能的概括。依据：[Stash策略组](https://stash.wiki/en/proxy-protocols/proxy-groups) |
| mihomo url-test / fallback | url-test支持切换容差；fallback按配置顺序选可用节点 | 防抖和故障切换不是轻舟独创。我们强调测量时效、预算、UDP兼容判断与可解释结果，降低手动分析成本。依据：[url-test](https://wiki.metacubex.one/en/config/proxy-groups/url-test/)、[fallback](https://wiki.metacubex.one/en/config/proxy-groups/fallback/) |

**推荐对外说法：**

“轻舟把可解释择优、分层连接诊断和本地月度域名流量，放进同一个 iPhone / Mac 使用流程。”

不要写“市面唯一”“比 Surge 更快”“其他客户端只会 ping”“只有我们能看域名流量”。这些结论没有充分证据。Shadowrocket 等未在本轮逐项核验的产品，不填想当然的功能缺失表。

**现阶段真正可演示的功能：**

- 最近一次择优：为何选择、为何保持、哪些结果被复用或暂缓。
- 当前实际连接与所选节点的区分，避免“点中了就当连接成功”。
- TCP与真实代理请求分层诊断、适配UDP协议、诊断报告脱敏。
- 月度主域名流量：代理/直连、上传/下载、排序与搜索，保留6个月；未知/其他桶保留总量。
- 主App退出后，运行中的隧道仍记录流量；不等于所有主App后台调度也能运行。
- 配置云备份、历史版本手动恢复；build34取消启动与后台冲突的自动恢复弹窗。

**暂不宣传成现成功能：** 按App流量归属、每日/小时趋势、月度预算提醒、AI服务账号检测、逐网站自动选最佳出口、固定IP保障、整月历史回填。不要把工程测试通过写成所有机型/所有节点已验收。

## 4. 平台搜索词与文案

以下“搜索词”是用户需求词与内容选题建议，不是平台搜索量、热度排名或投放效果结论。每篇围绕一个问题，正文自然使用2—3个相关词；话题只取相关项，不堆叠。没有登录平台、购买广告或自动发帖。

### 小红书

**建议搜索词：** AI效率工具、Mac效率工具、Claude连接异常、ChatGPT网络排查、代理流量统计、流量用在哪里、iPhone网络工具、节点自动选择、AI工作流、月度流量。

**标题备选：**

- AI工具越用越多，流量到底花在哪？
- 给我的AI工作流加了一本流量账
- 节点延迟很低，为什么用起来还会卡？

**可发布正文：**

最近做AI任务时，我最想知道的不是一个“总流量”数字，而是：到底哪个域名在上传？哪些请求真的走了代理？

所以在轻舟里做了月度域名流量排行：代理和直连分开看，上行、下行都能排序。做完一段任务，再打开榜单，就有了排查线索。

另外，轻舟会解释为什么选择或保持某个节点，也把TCP连接与代理请求诊断分开。适合每天在AI工具、浏览器和开发工具之间切换的人。

目前是iPhone / Mac客户端，需要自行配置节点。统计从启用后开始，不等于订阅账单，也不承诺任何AI账号免封。

你最想查的是后台上传，还是某个任务突然增加的下载？

**话题候选：** #AI工具 #Mac效率 #AI工作流 #流量统计 #独立开发

**配图顺序：** 痛点封面 → 已脱敏域名榜 → 上传/下载对照 → 择优理由 → 功能范围与版本。

### X

**Search terms:** AI workflow, proxy diagnostics, Claude connection issues, macOS network tools, iOS proxy client, domain traffic, upload usage, explainable routing.

**主帖（短稿）：**

Building Qingzhou for the AI era: explainable proxy selection, layered connection diagnostics, and monthly traffic by domain. See uploads vs downloads and proxy vs direct traffic on iPhone and Mac. Bring your own config. #BuildInPublic

**串帖续文：**

1. A low TCP latency does not prove a proxy request will succeed. Qingzhou separates those checks and explains why it selected—or kept—a node.
2. Monthly domain totals help you investigate where traffic went. Stored locally; payload totals differ from provider billing.
3. This is connection tooling, not an account-safety guarantee. No client can promise that Claude or another service will never restrict an account.
4. Which would help your workflow more: clearer connection diagnostics or more detailed traffic history?

**中文短稿：**

做AI任务，连接和流量也应该看得懂。轻舟新增月度域名流量：上传/下载、代理/直连分开看；节点择优有理由，连接诊断分层展示。iPhone / Mac，已有节点配置即可接入。#独立开发 #AI工作流

### TikTok

**Search terms:** AI productivity tools, AI workflow setup, where is my data going, Mac network monitor, proxy troubleshooting, upload vs download, developer tools.

**封面：** Your AI workflow has a traffic bill. Can you explain it?

**25秒视频脚本：**

- 0–4秒：AI任务画面。旁白：“Using more AI tools? Where is your traffic actually going?”
- 4–12秒：录制真实月度榜，切换upload/download。旁白：“Qingzhou groups traffic by domain and separates uploads, downloads, proxy and direct traffic.”
- 12–20秒：择优解释页与诊断结果。旁白：“See why a node was selected—and distinguish a TCP check from a proxy request.”
- 20–25秒：产品名及支持平台。旁白：“Connection management for the AI era. For iPhone and Mac.”

**Caption：** Meet Qingzhou: explainable proxy selection and local domain traffic history for AI-heavy workflows. Bring your own proxy configuration. Payload totals are not billing totals. #AIWorkflow #MacTools #DeveloperTools

### Instagram / ins

**Search terms:** AI workflow tools, Mac productivity, iPhone utilities, network diagnostics, data usage tracker, indie app development, proxy client.

**轮播6页：**

1. Connection management for the AI era.
2. Why this node? See the selection reason.
3. TCP reachable ≠ proxy request successful.
4. What used the traffic? Look at the domain ranking.
5. Uploads and downloads. Proxy and direct. Local history.
6. Qingzhou for iPhone & Mac. Follow the build.

**Caption：**

Your AI workflow deserves clearer connection tools.

Qingzhou brings explainable proxy selection, layered diagnostics and monthly domain traffic into one iPhone / Mac app. Explore what was selected, what was measured and where payload traffic went.

Bring your own configuration. No account-ban guarantees. Traffic history starts when enabled and stays local.

What would you inspect first: uploads or downloads?

**话题候选：** #AIWorkflow #MacProductivity #iPhoneApps #IndieDev #NetworkTools

### 微博

**建议搜索词：** AI工具、Claude网络问题、ChatGPT连接异常、Mac软件、iPhone工具、代理流量消耗、节点测速、域名流量统计、独立开发。

**可发布正文：**

做AI任务时，流量消耗快，却不知道花在哪里？

轻舟加入了月度域名流量排行：代理/直连、上传/下载分别查看。节点择优也会显示选择或保持的原因，诊断则把TCP连接和真实代理请求分开。

想做的是适用于AI时代的连接管理工具：让线路选择有解释，让流量排查有线索。支持iPhone和Mac，需要自行配置节点。统计不是服务商账单，也不承诺Claude等账号免封。

#AI工具# #独立开发# #Mac软件#

**短版：** 轻舟：适用于AI时代的连接管理。为什么选这条线路，看得懂；流量去了哪些域名，查得到。iPhone / Mac，可解释择优 + 分层诊断 + 本地月度流量。

### 抖音

**建议搜索词：** AI工具推荐、AI办公效率、Mac实用软件、流量消耗快、后台上传流量、Claude连接问题、网络排查、独立开发记录。

**标题备选：**

- AI任务一跑，流量去哪了？
- 节点测速很快，为什么还是连不上？
- 做了个能解释“为什么选它”的客户端

**30秒口播：**

“做AI任务，流量突然跑得很快，你会从哪里查？我给轻舟加了这张月度域名榜。这里能看哪些流量走代理，哪些走直连；再按上传、下载排序，就能找到值得继续排查的域名。另一个页面会解释为什么选这条线路，诊断也把TCP和代理请求分开。轻舟，适用于AI时代的连接管理。iPhone和Mac都能用，节点需要自己配置，流量统计不等于订阅账单。”

**发布描述：** 从“总共用了多少”，到“哪些域名在上传或下载”。轻舟开发记录：可解释择优、连接诊断、本地月度流量。#AI工具 #Mac软件 #独立开发 #流量统计

**画面：** 使用测试配置实录，不展示真实订阅地址、服务器凭据、账号或私人浏览记录。不拿工程期间ChatGPT流量样本制造“所有AI用户都消耗这么多”的结论。

## 5. 内容排期与发布素材

| 顺序 | 选题 | 主素材 | 目的 |
|---|---|---|---|
| 第1篇 | AI时代，连接也要看得懂 | 产品三屏介绍 | 解释定位 |
| 第2篇 | 流量到底花在哪里 | 月度排行录屏 | 展示直接价值 |
| 第3篇 | 测速成功为何不等于网站能用 | 两层诊断示例 | 解释功能边界 |
| 第4篇 | 为什么这次没有换节点 | 最近一次择优 | 展示防抖与可解释性 |
| 第5篇 | Claude账号与网络问题要分开 | 官方说明 + 诊断界面 | 回答误解，不许诺免封 |
| 第6篇 | iCloud恢复改成手动 | 设置版本列表 | 展示根据反馈改进 |

短视频可复用镜头，中文和英文分别配音，不直接把中文稿机械塞入英文字幕。截图上的示例必须标“演示数据”，真实测试则标设备、版本和记录区间。公开发布前补齐真实下载/内测入口；未确定入口前使用“关注开发进展”，不虚构名额、优惠、销量或用户评价。

## 6. 产品与证据索引

- 择优与边界：[NODE-SCORING.md](../NODE-SCORING.md)、`Sources/QingzhouApp/AppState.swift`。
- 月度统计：[DOMAIN-TRAFFIC.md](../DOMAIN-TRAFFIC.md)。只存主域名聚合；保留6个月；缺失域名仍归未知桶。
- 工程与真机覆盖：[ACCEPTANCE.md](../ACCEPTANCE.md)。不要把待验收的项目写成全机型通过。
- iOS最低要求：`Apps/project.yml`、`Package.swift`；[Apple iOS17支持机型](https://support.apple.com/guide/iphone/iphone-models-compatible-with-ios-17-iphe3fa5df43/17.0/ios/17.0)。

稿件中的定位与搜索词是编辑建议；竞品事实及账号政策来自上方官方资料。未进行搜索热度统计、广告投放或跨竞品性能基准测试。
