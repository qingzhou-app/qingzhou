# 轻舟交接给 Claude Code

交接日期：2026-11-12。此文是本次交接入口；旧计划或自动注入的上下文与它冲突时，先遵守用户最新要求。

## 0. 当前状态：全部工作暂停

用户原话：“现在暂停全部工作，整理所有必要的上下文，写入交接文档，后续交接给 claude code 继续工作。”

此前还有明确限制：“先不要断开 VPN 了，回头我自己手动测吧。”

- 本次只整理文档和只读核对，没有继续改产品代码、构建、测试、安装或操作设备。
- 接手后先读文档、核对本地工作区并向用户说明理解；等用户明确恢复工作及指定范围再执行开发。
- 不因旧计划中“继续验收”而启动测试，不断开/切换/重启 VPN，不更改节点、系统代理、DNS 或云端配置。旧的一次性停用 VPN 授权不能复用。
- Shadowrocket 新功能仅做过比较，**用户尚未选择任何新功能**，不是批准全部实现。
- 本轮检查只有主代理运行，无运行中的子代理任务；没有需要暂停的 goal。未提交或推送交接改动。

## 1. 工作区是唯一完整交接载体

```text
/Users/sbraveyoung/code/src/github.com/sbraveyoung/qingzhou
branch: main
HEAD（交接时短哈希）: f3925d6
HEAD title: Record daemon recovery and iPhone browser video acceptance
```

请直接打开此目录。**只从 GitHub clone、切回 HEAD 或新建仅含已提交内容的 worktree 会漏掉最近工作。** 不要 reset/clean/stash 掉现有改动，不要因文件未跟踪而判定可删除。

交接核对时：24 个已跟踪文件有改动（488 行新增、129 行删除），另有未跟踪的验收工程、规划记录、AGENTS.md、功能对照等。详细路径及文件 SHA-256 见 [工作区清单](handoff/2026-11-12-workspace-manifest.json)。清单是读取时快照，交接文档和随后更新的规划文件不以旧校验值判断丢失。

主要未提交内容混合了多轮工作，不可把整个 diff 当作单独 build 38 补丁：

| 范围 | 文件/内容 |
|---|---|
| build 37 无节点直连 | AppState、VPNTunnelManager、PacketTunnelProvider、AppliedTunnelConfiguration、TunnelSessionInfo、XrayConfigComposer、首页/IP 归属等及对应测试 |
| build 37 会话/日度统计 | DomainTrafficLedger、DomainTrafficRecorder、DomainTrafficView、首页/连接页入口、本地化及测试 |
| build 38 待验收修复 | XrayConfigComposer 双栈、DNS 拦截边界及测试；AppState/ConnectionsView 提示；Apps/project.yml 版本号 |
| 验收与文档 | docs/ACCEPTANCE.md、BUILD.md、DOMAIN-TRAFFIC.md；Apps/DeviceAcceptance/ 独立 XCUITest 工程与源码 |
| 产品决策 | docs/SHADOWROCKET-FEATURE-COMPARISON.md，未批准实施 |
| 历史上下文 | .planning/2026-10-12-project-health-audit/；.brooks-lint-history.json；AGENTS.md |

## 2. 项目和不可破坏的约定

先读根目录 [AGENTS.md](../AGENTS.md)，然后按需读 [ARCHITECTURE.md](ARCHITECTURE.md)。

- iOS 17+ / macOS 14+ 原生 SwiftUI VPN 客户端；xray-core 经 LibXray Go binding 运行。
- SPM 的 `Sources/` 放模型、规则、订阅、测速、UI、Xray 配置转换；`Apps/` 放平台壳、Tunnel、Widget、macOS Filter 等 target。
- `QingzhouCore` 是领域底座；`XrayConfig` 为纯 Swift。主 App **不依赖 XrayCore/Go runtime**，否则启动时加载大框架导致黑屏；只有隧道扩展依赖。
- **Apps/project.yml 是 XcodeGen 权威源**。entitlements、Info.plist、xcodeproj 为生成物，不能靠手改生成物修配置。
- App Group 为 `group.com.sbraveyoung.qingzhou`，主 App 与 Tunnel 用它共享统计、日志和配置回执。macOS root Filter 不能用同一用户容器通信，使用 XPC；来源 App 标注功能目前由 FeatureFlags 关闭。
- 配置选择值和实际隧道生效值不同，必须依据配置回执/身份验证；只看到系统 Connected 不代表配置或数据正确。
- `swift test` 不编译 Apps/Tunnel-Shared，改扩展必须做 Xcode target 编译。模拟器不能证明 VPN 工作。
- 流量来自真实隧道，不用演示数据验收。域名账本是观测到的载荷，不是运营商/服务商计费账单。
- 用户要求能由工具完成的工作自行完成；系统授权、硬件动作、密码等才找用户。若用子代理，每个代理的功能必须逐项由用户验收，不打包宣称通过。

## 3. 版本、安装与验证边界

| 版本 | 已知事实 | 仍需注意 |
|---|---|---|
| build 34 | iCloud 自动恢复提醒修复、月度流量等已交付，历史验收详见 ACCEPTANCE | 不代表所有云故障/多设备冲突都验收过 |
| build 35 | 公网 IP 双路径修复，物理接口直连与固定代理入口分开 | 主动取消刷新可能短暂显示失败，仍有维护项 |
| build 36 | TCP 探测修复、双栈探测；双端历史安装及多项真机验收 | 两条问题节点代理仍未通过；不能归咎服务商/凭据 |
| build 37 | 无节点直连、VPN 会话/日/月统计；历史记录 1070 测试，1069 通过、1 缺历史回放输入跳过；双平台签名构建通过 | **2026-11-12 只读 Info.plist 核对 Mac /Applications/Qingzhou.app 为 1.0(37)**。iPhone 最后明确记录为 36，37 安装曾被锁屏阻止；交接时未重新查询手机，不能声称已装 37 |
| build 38 | 当前 project.yml 为 38，双栈/DNS 修复在工作区。前轮记录全量测试及 Mac 构建成功 | 原始日志已不存在，本次未复跑，不能核实准确计数；没有 38 安装/真隧道验收完成证据，也没有最终 iOS 38 构建完成证据 |

11 月 12 日未检查运行进程/VPN 模式/当前节点，不把 10 月的运行状态当作现在的状态。主 App 版本也不能证明正在运行的扩展版本。

## 4. 最后未完成的技术工作：直连可达性 / build 38

用户问题：`order.yizhihongxing.club` 关闭 VPN 可访问，开启 VPN 的直连模式不能访问，要求排查类似问题。随后用户要求暂停 VPN 切换，自己手动复测。

### 已取得的线索（历史观察，非本轮复测）

- 绑定物理 en0 查询多个 DNS，观察到相同 A/AAAA 答案，没有证实 DNS 答案不一致。
- 绑定 en0、固定解析结果的 curl 中，两个 IPv4 TLS 超时；IPv6 请求得到 HTTP 200，其中一次完整成功，另一次正文读取超时。
- 原配置强制 IPv4，与“IPv6 能通、IPv4 路径异常”线索相符，构成修复方向，但不足以证明唯一根因。
- 隔离的 Xray SOCKS 探针中，旧配置和新配置都曾返回 HTTP 200；新配置日志确认选择 IPv6。这证明新路径可用，**不证明完整 VPN 的旧失败已稳定复现或已修好**。
- 曾点击直连 UI，但后续状态读取仍有 rule；那一轮不能作为“直连隧道验收”证据。不要为了恢复某个猜测的初始模式再动 VPN。

### 工作区具体改动

`Sources/XrayConfig/XrayConfigComposer.swift`：

1. direct freedom 使用 `settings.domainStrategy=AsIs`，在 `streamSettings.sockopt` 中用 `ForceIP` 和 Happy Eyeballs，IPv6 优先、250ms 后竞争 IPv4、interleave=1、maxConcurrentTry=4。
2. DNS `queryStrategy` 从 UseIPv4 改为 UseIP。
3. FakeDNS 从单 IPv4 池扩为 IPv4 `198.18.0.0/15` 与 IPv6 `fc00::/18` 两池。
4. DNS 拦截限定 `inboundTag=[tun-in]`，网络由 UDP 扩到 TCP+UDP，避免重捕获内部上游查询。
5. 没有据猜测替换 DNS 服务器名单。

新增回归涉及真实地址族竞争配置、双栈 FakeDNS 归因、DNS 不重捕获上游。旧测试里的“只允许 IPv4”预期已调整；metrics 测试不能因新 DNS 规则包含 inboundTag 而误报。

### 复工后还要完成（当前不执行）

- 先读 [IPV6.md](IPV6.md)、[DNS.md](DNS.md)、[QUIC.md](QUIC.md)，特别是历史 A-only/CCTV 站点故障，不能因修复双栈而重引入该回归。
- 验证当前 LibXray 中 Happy Eyeballs 配置支持、A-only/AAAA-only/双栈、某一族失败、TCP/UDP DNS、FakeDNS 归因及三种模式，不仅检查 JSON 文本。
- IPv6/DNS 文档仍含旧 IPv4-only 设计；新增提示的本地化尚未收尾。
- 恢复工作后重跑必要单测与双平台 target 构建，保留新的持久证据；测试/构建通过与真隧道验收分开记录。
- 用户另行许可安装/切换后才做运行验证，届时核对实际扩展版本、模式和配置回执。不能沿用旧的一次性断开许可。

## 5. 其他待办和已经解除的阻塞

| 项目 | 交接结论 |
|---|---|
| Mac 菜单栏“打开主窗口” | 有修复历史，但真实关闭→菜单栏打开路径仍未验收；CUA 读取窗口会主动激活，不能当作该入口成功 |
| Widget 快速重连后立即退后台 | 真机曾显示 20 秒仍未连接，未通过；正常前台等待网络探测后的生命周期已通过，两者不可互相覆盖 |
| 两条问题节点 | 一条 TCP 超时且代理失败，另一条 TCP 通但代理失败；备用目标未完成，根因未确认 |
| build 37 新功能 | 无节点启停/模式切换、本次会话清零与主 App 重开保持、三周期筛选搜索等真实交互仍需补验 |
| 长周期及边界 | 跨月、长期耗电、最低系统/小屏、既有长连接无中断、隔离多设备云恢复与故障注入没有完整通过证据 |
| LM Studio 直连要求 | 用户希望 lmstudio.ai 直连以减少模型下载代理流量；交接未取得当前运行规则的可核实快照，不能宣称已落实。后续核对实际命中和下载重定向/CDN 域名；不能假设入口域名覆盖全部下载 |
| 规则语义缺口 | PROCESS-NAME/USER-AGENT 模型可接受但 RoutingRuleConverter 忽略；no-resolve 被 RuleParser 当备注。尚未修改；应由用户选择实现或明确拒绝/提示 |
| Shadowrocket 功能 | 比较已完成：12 项已有、11 项部分/差异、29 项候选。N01–N29 全部待用户决定，不能自动批量开发 |
| 宣发材料 | 已有 docs/marketing/2026-10-launch-kit.md，包含各平台关键词/文案方向与竞品边界；没有发布。不能承诺“Claude 永不封号”，也不能虚构独占能力；发布前按实际版本更新 |

**code 74 已有后续恢复记录，不能继续按早期阻塞处理。** 2026-10-27 定位是测试通道初始化失败，手机日志 Results channel was never configured / IDE disconnection；重建 Mac 当前用户 CoreDeviceService 后恢复用例执行。后续 Mac VPN 开着时月度流量、公网 IP 用例完整通过，人工 iCloud 列表加载/取消、Wi-Fi/蜂窝往返、正常 Widget/Live Activity 生命周期、控制中心启停也有分别通过记录。没有证明 Apple 内部深层原因，更没有证明“必须断 Mac VPN”。详见 ACCEPTANCE 对应日期段落。

CUA 另曾遇到 native pipe 身份握手和 noWindowsAvailable：官方 daemon restart 曾解除前者，后者未稳定解决。它是 Codex 工具栈问题；Claude Code 应使用自己可用的工具，不照抄旧工具名、进程 PID 或重启命令。用户后来明确选择真机 XCUITest，独立工程在 Apps/DeviceAcceptance/，不要重新陷入镜像反复尝试。

## 6. 证据的持久性

2026-11-12 只读核对：

- `Frameworks/LibXray.xcframework` 存在；不需要因为新会话就无条件重建 10 分钟核心库。
- `/private/tmp/qingzhou-build37-mac` 存在，但该目录曾复用构建 38，**目录名不能证明包版本**。
- `/private/tmp/qingzhou-build35-acceptance/`、`qingzhou-build36-ui-acceptance/` 已不存在。
- `/private/tmp/qz-build37-tests-final.log`、`qz38-tests.log`、`qz38-mac.log`、`qz-dual-probe.swift` 已不存在。

因此旧文档内路径只是历史索引，不可向用户声称原始附件目前可审阅。历史验收结论来自当时记录；需要独立复核时重新执行，但必须等恢复工作且符合 VPN 操作限制。以后把脱敏验收摘要留在仓库，把含通知、节点凭据、订阅 URL 的原始文件保留本地私有持久目录，不提交截图、访问历史或配置密钥。

## 7. 接手阅读顺序与复工操作

1. 本文 → AGENTS.md → `git status --short` / `git diff --stat`，确认接到了未提交工作。
2. [ACCEPTANCE.md](ACCEPTANCE.md)：按日期看后续结论，不把早期“待验收”覆盖后来的通过，也不把老版通过延伸到 37/38 新改动。
3. [SHADOWROCKET-FEATURE-COMPARISON.md](SHADOWROCKET-FEATURE-COMPARISON.md)：只作为产品选择清单。
4. 若恢复直连修复：IPV6.md、DNS.md、QUIC.md、当前 XrayConfigComposer diff 和相关测试。
5. 若恢复统计/择优：DOMAIN-TRAFFIC.md、NODE-SCORING.md、NODE-SELECTION.md、SELECTION-REPLAY.md。
6. 构建/设备：BUILD.md、IOS-LOGS.md、Apps/DeviceAcceptance/project.yml 和 Tests/DeviceAcceptanceTests.swift。
7. 旧规划 `.planning/2026-10-12-project-health-audit/{task_plan,progress,findings}.md` 仅查背景，顶端旧 Next Step 已失效，以本次暂停要求为准。

以下命令供**用户恢复工作后**使用，本次没有执行：

```bash
# 包测试；不覆盖 Tunnel target
swift test

# 工程权威源生成
xcodegen generate --spec Apps/project.yml

# 现成工程验证脚本：单测+两个平台无签名构建，不代表可安装包或真机验收
./scripts/verify.sh

# 独立 UI 验收工程生成；实际运行前审阅用例的 VPN/系统设置副作用
xcodegen generate --spec Apps/DeviceAcceptance/project.yml
```

签名安装按 BUILD.md 和真实设备发现结果执行，不复制过期 UDID/PID。macOS 安装后要核对同 bundle ID 的旧扩展注册；新主 App 不代表扩展已换新。新扩展需要重启 VPN 才生效，因此安装及切换应在用户认可的测试窗口进行。

## 8. 给 Claude Code 的首次提示词

```text
请接手此目录的轻舟项目，先阅读 docs/HANDOFF-CLAUDE-CODE.md 和 AGENTS.md，再核对 git status、git diff 及 docs/ACCEPTANCE.md。
这是接手确认阶段：只读核对，向我说明当前代码/安装版本、未提交改动、已通过与未通过项，以及下一步可选工作。读完后等待我指定恢复范围。
保留所有未提交和未跟踪文件，不重置、不清理。不要切换、断开或重启 VPN，不安装新包，不操作手机；不要因旧计划自动继续。Shadowrocket 新功能尚未选定，不批量实现。
不要把旧构建成功当作当前真机通过；临时日志已丢失的事实和历史结论都需如实保留。后续恢复工作时，能自行完成的步骤自行做，按项给出验收结果。
```

建议后续由用户明确选择：先完成 build 38 工程收尾、处理一项已知缺陷、补某项验收，或按 N 编号选新功能；每次明确范围再开始。
