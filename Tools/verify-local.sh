#!/bin/sh
# 本地非特权一键验证脚本（不运行 sudo、不干扰运行中的 VPN）。
#
# 用法：
#   sh Tools/verify-local.sh
#   sh Tools/verify-local.sh --skip-xcodebuild
#
# 覆盖步骤：
#   1. sh Tools/check-scripts.sh
#   2. sh -n 语法检查（Tools/*.sh Tools/qingzhou-guard/*.sh）
#   3. python3 scripts/extract-geosite-cn.py --check
#   4. swift test
#   5. sh Tools/qingzhou-guard/build-relay.sh <tmp>/qingzhou-relay
#   6. xcodegen generate --spec Apps/project.yml + 校验 .entitlements / Info.plist 未被意外改动
#   7. 无签名 xcodebuild（Qingzhou-iOS Simulator + Qingzhou-macOS，可通过 --skip-xcodebuild 跳过）

set -eu

SKIP_XCODEBUILD=0
for arg in "$@"; do
  case "$arg" in
    --skip-xcodebuild)
      SKIP_XCODEBUILD=1
      ;;
    -h|--help)
      cat <<'EOF'
Usage: sh Tools/verify-local.sh [--skip-xcodebuild]

Runs non-privileged local verification checks without touching VPN or sudo:
  1. sh Tools/check-scripts.sh
  2. sh -n Tools/*.sh Tools/qingzhou-guard/*.sh
  3. python3 scripts/extract-geosite-cn.py --check
  4. swift test
  5. sh Tools/qingzhou-guard/build-relay.sh <tmp>/qingzhou-relay
  6. xcodegen generate --spec Apps/project.yml (+ entitlements/Info.plist diff check)
  7. Unsigned xcodebuild (Qingzhou-iOS Simulator + Qingzhou-macOS), unless --skip-xcodebuild
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qingzhou-verify-local.XXXXXX")"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

step() {
  echo
  echo "==> $1"
}

step "1/7 脚本变量边界检查 (Tools/check-scripts.sh)"
sh Tools/check-scripts.sh

step "2/7 POSIX sh 语法检查 (sh -n)"
for script in Tools/*.sh Tools/qingzhou-guard/*.sh; do
  [ -f "$script" ] || continue
  sh -n "$script"
  echo "  OK: ${script}"
done

step "3/7 校验 geosite-cn.txt 与 geosite.dat 一致性"
python3 scripts/extract-geosite-cn.py --check

step "4/7 运行 SPM 单元测试 (swift test)"
swift test

step "5/7 编译 qingzhou-relay 到临时目录"
sh Tools/qingzhou-guard/build-relay.sh "${TMP_DIR}/qingzhou-relay"

step "6/7 校验 XcodeGen 生成与 entitlements/Info.plist 完整性"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "缺少 xcodegen，请先安装 (brew install xcodegen)" >&2
  exit 1
fi
xcodegen generate --spec Apps/project.yml
TRACKED_APPLE_META="$(git ls-files 'Apps/*.entitlements' 'Apps/*/*.entitlements' 'Apps/*/*/*.entitlements' 'Apps/*/Info.plist' 'Apps/*/*/Info.plist')"
if [ -n "$TRACKED_APPLE_META" ]; then
  # shellcheck disable=SC2086
  if ! git diff --exit-code -- $TRACKED_APPLE_META >/dev/null; then
    echo "错误：xcodegen generate 后以下 .entitlements / Info.plist 发生漂移，请检查 Apps/project.yml：" >&2
    # shellcheck disable=SC2086
    git diff --name-only -- $TRACKED_APPLE_META >&2
    exit 1
  fi
fi
echo "  OK: .entitlements 与 Info.plist 与 git 基线一致"

step "7/7 无签名 Xcode Target 构建 (Qingzhou-iOS Simulator & Qingzhou-macOS)"
if [ "$SKIP_XCODEBUILD" -eq 1 ]; then
  echo "  SKIPPED: 已指定 --skip-xcodebuild"
elif [ ! -d Frameworks/LibXray.xcframework ]; then
  echo "  SKIPPED: 缺少 Frameworks/LibXray.xcframework（如需完整构建请先跑 ./scripts/build-libxray.sh）"
else
  IOS_LOG="${TMP_DIR}/xcodebuild-ios.log"
  MAC_LOG="${TMP_DIR}/xcodebuild-macos.log"

  echo "  Building Qingzhou-iOS (generic/platform=iOS Simulator, CODE_SIGNING_ALLOWED=NO)..."
  if ! xcodebuild -project Apps/Qingzhou.xcodeproj -scheme Qingzhou-iOS \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "${TMP_DIR}/dd-ios" CODE_SIGNING_ALLOWED=NO build >"$IOS_LOG" 2>&1; then
    tail -n 80 "$IOS_LOG" >&2
    exit 1
  fi
  echo "  OK: Qingzhou-iOS (Simulator) BUILD SUCCEEDED"

  echo "  Building Qingzhou-macOS (platform=macOS, CODE_SIGNING_ALLOWED=NO)..."
  if ! xcodebuild -project Apps/Qingzhou.xcodeproj -scheme Qingzhou-macOS \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "${TMP_DIR}/dd-macos" CODE_SIGNING_ALLOWED=NO build >"$MAC_LOG" 2>&1; then
    tail -n 80 "$MAC_LOG" >&2
    exit 1
  fi
  echo "  OK: Qingzhou-macOS BUILD SUCCEEDED"

  if grep -qiE 'MinimumOSVersion|deployment target.*100\.0' "$IOS_LOG" "$MAC_LOG" 2>/dev/null; then
    echo "  NOTE: 检测到 LibXray deployment target 相关告警，真机验证时请参考 docs/ACCEPTANCE-CHECKLIST-teamwork.md"
  fi
fi

echo
echo "✅ verify-local.sh 全部检查完成。"
