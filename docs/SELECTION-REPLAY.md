# 择优流程事件回放

build30 新增测试侧回放：直接运行 `AppState.autoSelectBestNode`，因此候选预算、TCP缓存、代理双目标复核、冷却、网络变化、评分和连续领先都走生产实现。替换的只有时钟、探针与最终 VPN 应用。没有真实出网、没有读写系统 VPN 配置，临时本地存储在结束时清理；工具不打包进 App。

## 运行

```bash
./scripts/replay-selection.sh /private/tmp/qingzhou-replay
QZ_SELECTION_SCENARIOS="$PWD/docs/fixtures/selection-scenarios.example.json" \
  ./scripts/replay-selection.sh /private/tmp/qingzhou-replay-example
```

依赖与 `swift test` 相同（含本地 LibXray framework）；测试不会调用真实内核探针。输出 `run.log`、`report.json` 和 `report.md`。不指定输入就运行内置六组场景：故障/冷却到期、主目标故障、全失败/资源不足、网络变化重置连续领先、大节点池预算、小幅抖动。其余独立回归覆盖在途路径变化、UDP、别名等边界。

## 输入约定

输入是场景数组，参考 [示例 JSON](fixtures/selection-scenarios.example.json)。只能放匿名符号 ID 和观测，不需要真实地址、密码、分享链接或订阅。`name` / 节点 `id` 只接受不超过64字节的英文字母、数字、下划线、短横线。

- `nodes`：`id` 必填。`udp: true` 模拟 Hysteria2，否则模拟 Trojan；`aliasOf` 引用前面已定义的同配置节点；`rate` 倍率默认1；`excluded` 默认false。
- `initialChoice`：初始选择的 ID，或 null。`frames` 按 `at` 非递减排列，单位为场景秒，内部映射到固定虚拟日期。
- `directMs`：按 ID 指定直连毫秒数；`directFailures` 指定握手失败。未指定者默认50ms；每次实际调用均返回该帧值，因此目前不能表示一个 burst 内不同的三次延迟。UDP不调用TCP。别名共享显式值，成功/失败或显式数值冲突直接拒绝。
- `primary` / `backup`：按 ID 指定代理结果，每项只能含 `ms` 或 `failure` 之一；`primaryDefault` / `backupDefault` 可设缺省。实际调用缺少观测时整个回放失败，不能将缺数据误当节点坏。别名共享显式观测，冲突拒绝。
- 失败分类与生产一致：`probeFailed`、`invalidConfiguration`、`resourceLimited`、`invalidTarget`、`unavailable`、`cancelled`、`superseded`。
- `networkChanged` 在轮前建立新上下文；`changeNetworkDuringProxy` 在首个代理响应前切换上下文。`manual` 默认false；`vpnRunning` 初始为true，指定时更新状态并保持至后续帧。
- `available` 是出口可用真值；`acceptable` 是可接受选择集。可用性按完整配置身份共享到所有别名，acceptable 保留行级选择含义；两者都只提供给报告统计，策略不可见。省略代表未知。`outageStartedAt` 可指定已知故障开始的场景时间，不晚于当前帧；未指定则以首次观察到旧选择不可用的帧为起点。

## 指标与边界

`directRequests` 是真实经过假探针的握手调用数；代理计数同理。`switchCount` 统计已有选择的变化，初始空选择不算切换。只有有 `acceptable` 的变化才计入 `evaluatedSwitchCount`，新选择不在该集合才算 `unacceptableSwitchCount`。没有真值不能声称“零误切”。

`recoveryDecisionSeconds` 是从给定故障起点到选择可用出口的输入时间差，`unresolvedOutages` 记录结尾仍未恢复的事件。若旧选择可用、但新选择不可用，故障从当帧决定开始计时，不回溯套用 `outageStartedAt`。**它不含真实探测、扩展或VPN切换耗时，不能解释为真实断网恢复速度。** 没有带宽样本的这些场景使用生产中性分；并未模拟真实下载计数归属、系统挂起、网络路径识别遗漏或设备资源压力。

内置80个节点/4轮/间隔60秒的场景，旧全量方式理论需要960次握手；预算及缓存方式预期249次（80个身份各3次，加当前节点后续3轮各3次），减少约74%。这是这组场景的请求数，不能等同于省电74%或普遍减少74%。正常默认30分钟周期下缓存通常过期，主要收益来自每轮24身份上限；完整覆盖需要多轮，首次发现大池末尾好节点会变慢，用户可手动全量测速。

旧 `QingzhouCore.SelectionReplay` 仍用于纯评分/黏性分析和历史测量文件，不是完整调度回放，也不是任何竞品的复刻。新场景需要明确的失败类型/目标/事件；旧历史没有这些信息，不能凭空补成真实输入。真实设备的策略质量和能耗仍待统一安装验收。
