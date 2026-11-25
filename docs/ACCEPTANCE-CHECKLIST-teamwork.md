# 轻舟 `master/teamwork` 真机与特权环境验收清单

> **重要提醒**：在自动化流程中，**没有执行过 `git push`、没有运行过 `sudo` 安装/系统修改、也没有断开或切换你当前运行中的 VPN**。
> 请按下列顺序在你的本机终端与真机上逐项验收并勾选。

---

## 1. 本地非特权预检（不碰 VPN、无需 `sudo`）

在仓库根目录执行：

```sh
sh Tools/verify-local.sh
```

如暂不跑 `xcodebuild`，可先跑：

```sh
sh Tools/verify-local.sh --skip-xcodebuild
```

**通过标准**：
- [ ] `sh Tools/check-scripts.sh` 通过（无 `$VAR` 紧跟非 ASCII 字符）。
- [ ] `sh -n Tools/*.sh Tools/qingzhou-guard/*.sh` 全部退出码 `0`。
- [ ] `python3 scripts/extract-geosite-cn.py --check` 输出 `OK: Sources/QingzhouCore/Resources/geosite-cn.txt matches geosite.dat (domain=5675, full=40, regexp=3)`。
- [ ] `swift test` 全部通过（`1,292` 项执行、`2` 项环境门控跳过、`0` 失败，覆盖 `11` 个 target）。
- [ ] `sh Tools/qingzhou-guard/build-relay.sh` 编译成功。
- [ ] `xcodegen generate --spec Apps/project.yml` 后，15 个受跟踪 `.entitlements` 与 `Info.plist` 无漂移。
- [ ] 无签名 `xcodebuild`：`Qingzhou-iOS`（Simulator）与 `Qingzhou-macOS` 均 `** BUILD SUCCEEDED **`。

---

## 2. `sudo` `qingzhou-guard` 端到端与实机 VPN / `pf` / 时区验收

> ⚠️ 会安装 LaunchDaemon、临时切换系统时区，并在开启 `--with-pf` 时短暂测试 `com.apple/qingzhou_guard` 锚点拦截。

### 2.1 一键端到端脚本验收（推荐先不带 `--with-pf` 测安装/转发/控制口/卸载，再带 `--with-pf` 测 `pf`）

```sh
# 1) 测试编译、install.sh、10808 SOCKS5 转发、10809 AUTH/SET-TZ/切回原时区/RESTORE、uninstall.sh 还原与清理
sudo sh Tools/verify-guard-e2e.sh --yes-i-know

# 2) （在 App 内开启「分流方案」+「经 root 中继出网」并连接 VPN 后）测试 pf 启用与锚点清理：
sudo sh Tools/verify-guard-e2e.sh --yes-i-know --with-pf --keep-installed
```

**通过标准**：
- [ ] `/Library/Application Support/qingzhou-guard/relay-auth` 权限 `600`，含独立的 `forward:` 与 `control:` 凭据；App Group `guard-relay.json` 同步成功（`600`）。
- [ ] `127.0.0.1:10808` SOCKS5 转发成功返回 HTTP 200/30x；控制口 `127.0.0.1:10809` 拒绝转发凭据，接受控制凭据 `AUTH`。
- [ ] `SET-TZ` 切换系统时区、`SET-TZ <原时区>` 切回原时区、`RESTORE` 与 `uninstall.sh` 均能正确通过 `systemsetup` 还原系统时区。
- [ ] `off.sh` 仅清空 `com.apple/qingzhou_guard` 锚点并释放轻舟自身 `pf-token`，不调用全局 `pfctl -d`，不破坏其它 `pf` 状态。

### 2.2 实机 VPN 启停 / 断网不漏 / 重连 `utun` 手动检查

```sh
# 确认已安装且保留在系统中（或单独跑 install.sh）
sudo sh Tools/qingzhou-guard/install.sh
```

在轻舟 macOS App：设置 → 分流方案 → 开启「国内直连、其余全走海外出口」、选定「海外出口」+「跳板」、开启「经 root 中继出网」与「跟随出口地区」，连接 VPN 后运行：

```sh
sudo sh "/Library/Application Support/qingzhou-guard/enable.sh"
```

**通过标准**：
- [ ] `enable.sh` 5/5 检查全部通过（包含 `xray-config.json` 结构化校验与 `/var/log/qingzhou-relay.log` 120s 流量证据）。
- [ ] 正常上网验证：`curl -s https://api.ipify.org` 返回住宅出口 IP；国内直连站点返回国内 200；`/var/log/qingzhou-relay.log` 无 `198.18.x.x`/`198.19.x.x` 假 IP。
- [ ] 断开 VPN 后验证 fail-closed：外部 `curl` 在 `<= 1s` 内被 `pf` 拦断（超时），同时局域网网关 `ping` 仍然通畅；重连 VPN 后 `guard-run.sh` 在 `<= 1s` 内感知新 `utunN` 并恢复代理通畅。
- [ ] 时区跟随验证：连接海外出口后 `date` / `systemsetup -gettimezone` 切为出口时区；断开 VPN 后自动还原为本机原时区。
- [ ] 急停恢复验证：
  ```sh
  sudo sh "/Library/Application Support/qingzhou-guard/off.sh"
  ```
  执行后普通流量立刻恢复，且正在连接的 VPN 不断线。
- [ ] （已知产品待决项，非阻塞当前代码）：确认是否需要在后续版本为中继补充 `UDP ASSOCIATE`（`CMD=3`）或 `uot` 以支持分流 + 中继下的国内 UDP 应用。

---

## 3. Xcode 真机签名构建 & App Store Connect（S4/S5）

参考 `docs/BUILD.md` 与 `docs/APP_STORE_STEP_BY_STEP.md`：

```sh
cd Apps
xcodegen generate
open Qingzhou.xcodeproj
```

- [ ] **Qingzhou-iOS（真机签名）**：选择 Team `UK7MME38H9` + 真机 iPhone → ⌘B / ⌘R 构建并安装成功；开关 VPN 验证隧道建立与流量转发。
- [ ] **Qingzhou-macOS（真机签名）**：选择 `My Mac` → ⌘B / ⌘R 构建并安装成功；运行 `pluginkit -m -v -i com.sbraveyoung.qingzhou.mac.tunnel` 确认仅注册当前 App 内嵌扩展。
- [ ] **`LibXray.xcframework` deployment target 告警核查**：检查 Xcode 构建日志中关于 `LibXray` `MinimumOSVersion = 100.0` / `minos` 的链接器告警；若目标最低系统版本（iOS 17 / macOS 14）真机运行有异常，按 `scripts/build-libxray.sh` 重新打包校验。
- [ ] **App Store Connect（S4/S5 手工操作，见 `docs/APP_STORE_STEP_BY_STEP.md`）**：
  - [ ] 归档并上传合并后最新 build（`1.0(38)`+）至 ASC（Apple ID `6787037928`）。
  - [ ] 部署 GitHub Pages（`main /docs`）发布 `docs/PRIVACY.md`（按审核需要确认仓库可见性）。
  - [ ] 补齐 ASC 元数据：App 隐私（全 No）、导出合规（`ITSAppUsesNonExemptEncryption = false`）、EU DSA 交易商状态或取消勾选欧盟地区、排除中国大陆、17+ 分级、6.9"/6.5" 真机截图、审核备注（附稳定测试节点/订阅）。
  - [ ] 完成 TestFlight 外部测试（≥1 周、Crash-free ≥99%）后 **Submit for Review**。

---

## 4. 真机 NetworkExtension 50 MiB 内存实测

在 iPhone 真机启用分流方案并触发一次「更新名单」（加载经 `geosite:cn` 去重 + `SplitExitListsLimits` `30,000 / 2,000 / 8,000` 抽样后的 `split-exit-lists.json` + 内置 `geosite.dat` / `geoip.dat`）：

- [ ] 连接后连续访问国内外混合网站 5–10 分钟（含视频/图片并发）。
- [ ] 在设置页「诊断」查看隧道扩展内存读数（或 Xcode Debug Navigator Memory / `memorystatus`），确认扩展 `phys_footprint` 稳定留有安全余量（远低于 iOS NE 50 MiB jetsam 上限，无被系统强杀现象）。

---

## 5. Build 38 与历史待真机核对项（不可用本地单测替代）

### 5.1 Build 38 双栈 IPv6 真机实网回归（`XrayConfigComposer`）

在普通模式（非分流）下连接真实 VPN，分别验证 `.rule`、`.global`、`.direct` 三模式：

- [ ] **仅 A 记录站点不回归**：浏览器访问 `https://cbs-u.sports.cctv.com` 可达（无假 IPv6 死路）。
- [ ] **仅 AAAA 记录站点可达**：支持 IPv6 出口环境下访问 `https://thiswebsiteisipv6only.com` 可达。
- [ ] **特定直连站点可达**：访问 `order.yizhihongxing.club`（直连 / 规则模式下可达性）及双栈大站正常。
- [ ] **连接页与域名账本**：连接页正确展示嗅探/FakeDNS 反查域名（非裸 IP），会话 / 日度 / 月度域名流量账本在杀进程重开后保留。
- [ ] **无节点直连**：Build 37 无节点直连模式启停、模式切换正常。

### 5.2 历史遗留手工核对项

- [ ] **两条问题节点诊断**：复测历史上一条 TCP 超时+代理失败、一条 TCP 409ms+代理失败的节点，确认分层诊断提示与不回退行为符合预期。
- [ ] **Widget 快速后台重连同步**：重连 VPN 后立即将 App 切到后台，确认桌面/锁屏小组件状态及时刷新为已连接（不再停留在 20 秒「未连接」）。
- [ ] **Mac 状态栏重开主窗口**：关闭 macOS 主窗口后，手工点击菜单栏图标「打开主窗口」，确认主窗口正确弹出并获焦。

---

## 6. 远端 `git push` 与临时存档 tag 后续清理（需你确认后手动执行）

> **再次确认**：`master/teamwork` 尚未推送到远端。请先检查状态、完成上述至少第 1–2 节与必要真机验证后，再自行决定是否推送。
>
> ⚠️ **切勿运行 `git push --tags`**：本地存有 4 个临时本地 `archive/*` 标签（仅用于暂存 2026-07 未合入历史提交）。远端推送命令**仅推送 `master/teamwork`**（以及验收通过后可选的 `main`），避免将临时本地标签推送到远端。

### 6.1 远端 `git push` 命令

```sh
# 1) 检查工作区干净度与提交历史
git status
git log --oneline -n 10

# 2) 仅推送集成分支 master/teamwork 到远端并建立跟踪（严禁附加 --tags）
git push -u origin master/teamwork

# 3) （可选）若验收全部通过、决定将 master/teamwork 合入 main（同样严禁附加 --tags）：
# git checkout main
# git merge --ff-only master/teamwork   # 若需保留合并节点可改用 git merge --no-ff master/teamwork
# git push origin main
```

### 6.2 临时本地 `archive/*` 标签后续复查与清理 TODO

清理旧 worktree 时，2026-07 的 4 个未合入历史提交已暂存为本地临时 `archive/*` 标签。请后续择机复查内容（合入/摘取或直接丢弃）并删除标签，避免长期滞留：

- [ ] 复查并处置 `archive/2026-07-02-roadmap-research`（`fbdb7f77`）
- [ ] 复查并处置 `archive/2026-07-03-ai-spike`（`baccd23d`）
- [ ] 复查并处置 `archive/2026-07-03-first-run-guide`（`c28c021a`）
- [ ] 复查并处置 `archive/2026-07-03-sni-sniffer`（`35cc92f0`）
- [ ] 确认上述 4 个临时标签全部处理完毕并执行本地删除（`git tag -l 'archive/*'` 返回为空）

参考检查与清理命令：

```sh
# 查看单个临时标签的提交信息与文件变更统计
git show --stat archive/2026-07-02-roadmap-research
git show --stat archive/2026-07-03-ai-spike
git show --stat archive/2026-07-03-first-run-guide
git show --stat archive/2026-07-03-sni-sniffer

# 确认无需保留或已合入/摘取后，删除临时本地标签
git tag -d \
  archive/2026-07-02-roadmap-research \
  archive/2026-07-03-ai-spike \
  archive/2026-07-03-first-run-guide \
  archive/2026-07-03-sni-sniffer
```
