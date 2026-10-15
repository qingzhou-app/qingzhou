#!/usr/bin/env bash
# 实际App择优流程的离线回放；探针与VPN应用均替换为测试适配，不访问网络或系统VPN。
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPLAY_OUTPUT_DIR="${1:-$(mktemp -d "${TMPDIR:-/tmp}/qingzhou-selection-replay.XXXXXX")}"
mkdir -p "$REPLAY_OUTPUT_DIR"
REPLAY_OUTPUT_DIR="$(cd "$REPLAY_OUTPUT_DIR" && pwd)"
cd "$REPO_ROOT"
if ! QZ_SELECTION_REPORT="$REPLAY_OUTPUT_DIR/report.json" swift test \
    --filter SelectionScenarioReplayTests/testScenarioSuiteAndOptionalJSONReport > "$REPLAY_OUTPUT_DIR/run.log" 2>&1; then
  tail -n 60 "$REPLAY_OUTPUT_DIR/run.log" >&2
  exit 1
fi
python3 - "$REPLAY_OUTPUT_DIR" <<'PY'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
reports = json.loads((out / 'report.json').read_text())
lines = ['# 择优流程合成事件回放', '',
    '驱动实际 AppState 决策流程，探针与 VPN 应用使用测试替身。恢复时间是输入事件之间的决定间隔，不含探针墙钟耗时、隧道切换耗时，也不是实测上网恢复时间。', '',
    '| 场景 | TCP握手 | 代理请求 | 选择变化 | 不可接受切换/有真值切换 | 恢复决定间隔（秒） | 未恢复事件 |',
    '|---|---:|---:|---:|---:|---|---:|']
for report in reports:
    tcp = sum(r['directRequests'] for r in report['rounds'])
    proxy = sum(r['proxyRequests'] for r in report['rounds'])
    recovery = ', '.join(str(v) for v in report['recoveryDecisionSeconds']) or '—'
    lines.append(f"| {report['name']} | {tcp} | {proxy} | {report['switchCount']} | {report['unacceptableSwitchCount']}/{report['evaluatedSwitchCount']} | {recovery} | {report['unresolvedOutages']} |")
lines += ['', '不可接受切换只按场景显式提供的 acceptable 集合判断；没有真值的切换不作好坏推断。输入默认值、格式和使用方法见 docs/SELECTION-REPLAY.md。逐轮测量、缓存复用、暂缓、复核、冷却及选择原因在 report.json 中。', '']
(out / 'report.md').write_text('\n'.join(lines))
print('\n'.join(lines))
print(f'Report: {out / "report.md"}')
PY
