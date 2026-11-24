# Mac窗口、测速可靠性与节点诊断 Implementation Plan

> 执行方式：root按superpowers:executing-plans连续实施；用户已要求先做完再统一验收。沿用已授权main checkout及本目录progress.md记录，不新建工作树。

**Goal:** 修复Mac窗口/语言问题，查明TCP异常可证明的部分，补节点分层诊断和脱敏报告，统一交付下一build。
**Architecture:** 继续Swift/SPM分层，窗口用SwiftUI场景生命周期；探针保留直连与代理测量边界；报告只存结构化测量结果，不储存凭据。
**Tech Stack:** Swift 6、SwiftUI/AppKit、Network.framework、既有Xray扩展通信。
**Spec:** 2026-10-20用户最新指令与task_plan.md Phase30–33；具体有界feature选择为agent判断。

## Global Constraints
- iOS17+ / macOS14+；主App不依赖XrayCore；生成配置只改Apps/project.yml。
- 旧待验收项全部保留，工程验证不能改为用户验收通过。
- 不用无绑定经VPN探测冒充物理直连延迟；未知/取消/环境错误不冒充节点失败。
- 诊断有界、可取消，遵守节点身份/网络上下文/用户意图保护；不新增周期后台探测。
- 配置先备份，保留10/20当前Mac32节点/HY2，不能恢复10/15旧配置。私有材料只存临时目录权限600。

## Review Focus
- 主窗口已销毁/最小化/只剩设置窗口：打开主窗口要创建或激活指定主场景。
- 语言运行时切换：侧栏和标题跟随，不能重建整棵导航树丢掉用户草稿。
- VPN/FakeDNS环境：不把虚拟地址的物理TCP超时当成节点故障。
- 诊断期间换网络/删节点/停VPN/取消：结果不覆盖新状态。
- 复制报告只含允许字段；错误字符串、节点名/域名、凭据、订阅URL不泄露。

### Task 1: Mac窗口与语言
Files: Apps/macOS/Sources/VPNMacApp.swift、Sources/QingzhouApp/StatusBarMenu.swift、Localization.swift、RootView.swift及主页面navigationTitle；Tests/QingzhouAppTests/LocalizationTests.swift。
- [x] 查用户路径/旧源码与官方Window/openWindow语义；旧代码只枚举已有窗口，无创建路径。
- [ ] 单主Window注册稳定ID，状态栏用openWindow；增加同一动作的⌘1入口。
- [ ] 写语言切换回归：独立bundle翻译中文/英文，AppSection标题依赖显式language，不依赖全局旧值；先RED后GREEN。
- [ ] 侧栏与七个主页面标题使用显式语言，保持导航/草稿状态。
- [ ] 定向测试、Mac原生构建及可执行UI复验；无法完成的原生交互留待统一验收。

### Task 2: TCP路径诊断与修复
Files: Sources/QingzhouSpeedTest/LatencyProber.swift、PhysicalInterfacePicker.swift、NodeSelector.swift；AppState测量消费；对应Tests。
- [x] 公共1.1.1.1绑定/不绑定对照：unbound ready3ms，en0 timeout；默认路由utun6，轻舟Connected。
- [ ] 同一物理接口进一步比较本地网关/国内公网/节点，区分DNS与路径，不凭一次超时改路由。
- [ ] 针对确认缺陷先加失败回归，实施最小修复；保留未知/超时/拒绝/取消类别和直连边界。
- [ ] 定向与真实有界对照验证；无法归因的实际线路失败明确保留，不谎称全部节点可用。

### Task 3: 分层诊断与脱敏报告
Files: QingzhouCore诊断值类型、QingzhouApp诊断协调与节点详情入口、Localizable.xcstrings、相关Tests。
- [ ] 在现有测量结果基础上提供TCP与代理层结果及下一步提示；按用户动作运行，不增加后台探测。
- [ ] 增加复制脱敏报告，字段白名单，原始错误/节点地址/名字/凭据/订阅URL不进入报告。
- [ ] 测取消、节点身份变化、上下文变化、报告脱敏；先RED后GREEN。

### Task 4: 验证与交付
- [ ] ./scripts/verify.sh全量SPM+iOS/macOS App/Tunnel/Widget；日志存/private/tmp。
- [ ] 一次独立代码审查，修重要问题并补回归；不让用户逐项中途验收。
- [ ] project.yml升级build；最终签名构建、Mac安装复验，iOS准备统一安装包；按设备可用性记录实际安装结果。
- [ ] 更新ACCEPTANCE/ROADMAP与本轮进度，保留未验收/未解决项，提交本地代码，不推送发布。

官方参考： https://developer.apple.com/documentation/swiftui/window 、 https://developer.apple.com/documentation/network/nwparameters 。
