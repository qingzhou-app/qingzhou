#!/usr/bin/env bash
# 可在本机或macOS CI执行：包测试 + iOS/macOS真实target编译。
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY_OUTPUT_DIR="${QINGZHOU_VERIFY_OUTPUT_DIR:-${TMPDIR:-/tmp}/qingzhou-verify}"
mkdir -p "$VERIFY_OUTPUT_DIR"
cd "$REPO_ROOT"

if [ ! -d Frameworks/LibXray.xcframework ]; then
  echo "Missing Frameworks/LibXray.xcframework; build scripts/build-libxray.sh first." >&2
  exit 1
fi

run_check() {
  local name="$1"
  shift
  echo "Running $name"
  if ! "$@" > "$VERIFY_OUTPUT_DIR/$name.log" 2>&1; then
    tail -n 80 "$VERIFY_OUTPUT_DIR/$name.log" >&2
    exit 1
  fi
  echo "$name passed ($VERIFY_OUTPUT_DIR/$name.log)"
}

run_check generate xcodegen generate --spec Apps/project.yml
run_check swift-tests swift test
run_check ios xcodebuild -project Apps/Qingzhou.xcodeproj -scheme Qingzhou-iOS \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "$VERIFY_OUTPUT_DIR/ios" CODE_SIGNING_ALLOWED=NO build
run_check macos xcodebuild -project Apps/Qingzhou.xcodeproj -scheme Qingzhou-macOS \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath "$VERIFY_OUTPUT_DIR/macos" CODE_SIGNING_ALLOWED=NO build
echo "All package and target checks passed. Device VPN behavior requires separate acceptance."
