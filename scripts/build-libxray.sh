#!/usr/bin/env bash
# 构建 LibXray.xcframework（Apple iOS / iossimulator / macOS / maccatalyst slices）。
#
# 用法：
#   ./scripts/build-libxray.sh         # 重新编译
#   ./scripts/build-libxray.sh --clean # 先清理 build 缓存再编
#
# 产物：Frameworks/LibXray.xcframework （~150 MB，不入库 —— 见 .gitignore）

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBXRAY_DIR="${LIBXRAY_DIR:-$HOME/code/libXray}"
LIBXRAY_REPO="https://github.com/XTLS/libXray.git"

# libXray 锁定的上游 commit —— 升级 xray-core 时通常要一起动（binding 与 core API 配对）。
# 2026-07-07 升级批：73bb811（含 Invoke 响应模型对齐 #132）。
LIBXRAY_REF="73bb811"

# 1) 确保 libXray repo clone 好了，并锁到指定 commit（浅 clone 不更新会悄悄停在老版本）
if [ ! -d "$LIBXRAY_DIR/.git" ]; then
  echo "==> Cloning libXray to $LIBXRAY_DIR"
  git clone "$LIBXRAY_REPO" "$LIBXRAY_DIR"
fi
echo "==> Pinning libXray to $LIBXRAY_REF"
git -C "$LIBXRAY_DIR" fetch --depth 200 origin main
# 上一轮构建留下的生成物（go.mod/go.sum）和拷入的补丁文件会挡住 checkout——
# 全部丢弃即可，它们每轮都会重新生成/重新拷贝。
git -C "$LIBXRAY_DIR" reset --hard -q
git -C "$LIBXRAY_DIR" clean -fdq
git -C "$LIBXRAY_DIR" checkout -q "$LIBXRAY_REF"

# 2) 工具链就绪
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
if ! command -v go >/dev/null; then
  echo "ERROR: go not in PATH. Run 'brew install go' first." >&2
  exit 1
fi
if ! command -v python3 >/dev/null; then
  echo "ERROR: python3 not available." >&2
  exit 1
fi

# go install 的落点：尊重用户的 GOBIN / GOPATH（比如本机 GOPATH=~/code → 二进制在
# ~/code/bin），不能硬编码 ~/go/bin —— 之前硬编码导致 gomobile 装好了却 command not found
GOBIN_DIR="$(go env GOBIN)"
[ -z "$GOBIN_DIR" ] && GOBIN_DIR="$(go env GOPATH)/bin"
export PATH="$GOBIN_DIR:$PATH"

# 3) gomobile（libXray 用 Apple 官方 gomobile，不是 sing-box 的 sagernet/gomobile 分支）
if ! command -v gomobile >/dev/null; then
  echo "==> Installing gomobile + gobind (into $GOBIN_DIR)"
  go install golang.org/x/mobile/cmd/gomobile@latest
  go install golang.org/x/mobile/cmd/gobind@latest
fi

# 4) 可选 --clean
if [ "${1:-}" = "--clean" ]; then
  echo "==> Cleaning libXray go.mod / build artifacts"
  rm -f "$LIBXRAY_DIR/go.mod" "$LIBXRAY_DIR/go.sum"
  rm -rf "$LIBXRAY_DIR/LibXray.xcframework"
fi

# 5) 准备 Go env（手动跑 libXray 的 init_go_env + download_geo，省去走 python 入口）
# xray-core 必须在 tidy **之前**锁 commit：v26.* tag 不是合法 Go 模块版本（主版本 ≥2
# 要 /vN 路径），tidy 自行解析会退回最新的 v1 tag（=旧版 v1.260327.0），而新 libXray
# 已 import 新版才有的包（common/geodata），直接 tidy 必失败。
XC_COMMIT="45cf2898ab12e97a55dd8f1f3d78d903340bdc9e"   # v26.6.27
echo "==> Preparing Go module env"
cd "$LIBXRAY_DIR"
rm -f go.mod go.sum
go mod init github.com/xtls/libxray
go get "github.com/xtls/xray-core@$XC_COMMIT"
go mod tidy
# go 1.26+ 的 gomobile 要求 golang.org/x/mobile 在模块依赖图里（tool directive），
# 而本脚本每次重建 go.mod，必须显式加回去，否则 bind 直接报 missing dependency
go get -tool golang.org/x/mobile/cmd/gobind
go run download_geo/main.go

# 5.5) macOS 内存压制 patch —— 上游只给 iOS（//go:build ios）内置了
# GOMEMLIMIT/GOGC/FreeOSMemory 压制，macOS slice 走 memory_other.go 的 no-op，
# Go 堆会无约束增长（实测扩展 RSS 爬到 1.6GB）。这里在 bind 前把本仓库
# scripts/patches/libxray/ 下的两个文件覆盖进去：
#   memory_macos.go  darwin && !ios：SetMemoryLimit(192MiB) + GOGC=30 + 10s FreeOSMemory
#   memory_other.go  !ios && !darwin：no-op（收窄上游的 !ios，避免重复定义）
# build tag 互斥，iOS 构建（memory_ios.go）完全不受影响。取值理由见 patch 文件头注释。
# 若上游改动 memory/ 包导致编译失败，先看 patches/ 与上游是否需要同步。
echo "==> Applying macOS memory-suppression patch (scripts/patches/libxray/)"
cp "$REPO_ROOT/scripts/patches/libxray/memory_macos.go" "$LIBXRAY_DIR/memory/memory_macos.go"
cp "$REPO_ROOT/scripts/patches/libxray/memory_other.go" "$LIBXRAY_DIR/memory/memory_other.go"

# 5.6) xray-core 版本锁定 + fakedns 防御纵深补丁。
# 版本：v26.* 的 tag 不是合法 Go 模块版本（主版本 ≥2 要 /vN 路径），下游只能按
# commit 锁 pseudo-version —— XC_COMMIT 即上游 release tag 指向的 commit。
# 2026-07-07 升级批：45cf2898 = v26.6.27（含 #6275 TUN 启动时序根因修复）。
# fakedns 补丁：查询入口 nil 防护（我们 issue #6442 的 start 侧竞态）。上游 #6275 修了
# TUN 主路径后这层降级为防御纵深 —— 保护 TUN 之外的早查询路径（第二 probe 实例等），
# 成本≈0。升级 xray-core 时：改 XC_COMMIT + 用上游新版 fake.go 重铺补丁底（只保留
# initialized() + 四处 guard + 发布顺序注释三件事）。
# ⚠️ 本脚本每次重建 go.mod，replace 必须在这里重加，否则构建产物悄悄退回无补丁原版。
# （XC_COMMIT 的 go get 在第 5 节、tidy 之前——原因见那里的注释。）
XC_VER="$(go list -m -f '{{.Version}}' github.com/xtls/xray-core)"
echo "==> Resolved xray-core pseudo-version: $XC_VER"
XC_PATCHED="$LIBXRAY_DIR/.xray-core-patched-$XC_VER"
# 判据用关键文件而非目录：中断过的 cp -R 会留下半拉子目录，按目录判会跳过重建
if [ ! -f "$XC_PATCHED/app/dns/fakedns/fake.go" ]; then
  echo "==> Creating patched xray-core copy ($XC_VER)"
  go mod download github.com/xtls/xray-core
  XC_CACHE="$(go env GOMODCACHE)/github.com/xtls/xray-core@$XC_VER"
  [ -d "$XC_CACHE" ] || { echo "ERROR: $XC_CACHE not in module cache (版本对不上？改 XC_COMMIT)" >&2; exit 1; }
  rm -rf "$XC_PATCHED"
  mkdir -p "$XC_PATCHED"
  cp -R "$XC_CACHE/." "$XC_PATCHED/"
  chmod -R u+w "$XC_PATCHED"
fi
echo "==> Applying fakedns guard patch (scripts/patches/xray-core/) + go.mod replace"
cp "$REPO_ROOT/scripts/patches/xray-core/fake.go" "$XC_PATCHED/app/dns/fakedns/fake.go"
go mod edit -replace "github.com/xtls/xray-core=$XC_PATCHED"
go mod tidy

# 5.7) 无感换节点 patch —— 轻舟自定义 libXray 导出 SwitchOutbound：在运行中的
# xray 实例上热替换 "proxy" outbound handler（隧道/路由/DNS 全不动，换节点零断流）。
# Swift 侧对应 XrayCore.switchOutbound → 扩展 handleAppMessage "switchNode"。
echo "==> Applying switch-outbound patch (scripts/patches/libxray/qingzhou_switch*.go)"
cp "$REPO_ROOT/scripts/patches/libxray/qingzhou_switch.go" "$LIBXRAY_DIR/xray/qingzhou_switch.go"
cp "$REPO_ROOT/scripts/patches/libxray/qingzhou_switch_wrapper.go" "$LIBXRAY_DIR/qingzhou_switch_wrapper.go"

# 6) gomobile bind
# 注意：不要带 maccatalyst —— gomobile + Xcode 26 在 maccatalyst 上有
# "duplicate framework path" bug（详见 docs/ROADMAP.md "S1 已知坑"）。
# iossimulator 也只 keep arm64（M1/M2 Mac 走 sim）。
echo "==> Running gomobile bind (this is the long step, 20-40min)"
gomobile bind \
    -target=ios,iossimulator,macos \
    -iosversion=15.0

# 6) 把产物挪到本仓库
SRC="$LIBXRAY_DIR/LibXray.xcframework"
DST="$REPO_ROOT/Frameworks/LibXray.xcframework"
if [ ! -d "$SRC" ]; then
  echo "ERROR: build succeeded but $SRC missing" >&2
  exit 1
fi

mkdir -p "$REPO_ROOT/Frameworks"
rm -rf "$DST"
echo "==> Moving xcframework to $DST"
mv "$SRC" "$DST"

echo "==> Done. Size:"
du -sh "$DST"

cat <<EOF

下一步：
  1. 取消 Package.swift 里 XrayCore product + binaryTarget + target 的注释
  2. swift build  → 应该看到 XrayCore 编译过
  3. 在主 app 入口加  Text("xray \(XrayCore.version)")  验证 link 通了

EOF
