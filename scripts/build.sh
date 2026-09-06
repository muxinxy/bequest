#!/usr/bin/env sh
# 托孤(bequest)服务器交叉编译脚本(仓库根目录执行: ./scripts/build.sh)
# 共 9 个平台: linux/{amd64,arm64,arm,riscv64,loong64} windows/{amd64,arm64} darwin/{amd64,arm64}
# 产物输出到 dist/bequest-server-<VERSION>-<os>-<arch>[.exe]
#
# 用法:
#   ./scripts/build.sh                 # 版本 dev
#   VERSION=1.0.0 ./scripts/build.sh   # 注入 main.version
#   GOPROXY=https://goproxy.cn,direct ./scripts/build.sh  # 国内网络
set -e

VERSION="${VERSION:-dev}"

# 仓库根目录与 server 模块目录
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_DIR="$ROOT/server"
DIST_DIR="$ROOT/dist"
mkdir -p "$DIST_DIR"

# CI 默认走官方代理; 本地可用 GOPROXY 覆盖(如 goproxy.cn)
: "${GOPROXY:=https://proxy.golang.org,direct}"
export GOPROXY
export CGO_ENABLED=0
# GOARM 仅对 GOARCH=arm 生效(v7: 树莓派 32 位系统/旧 NAS), 其余架构忽略
export GOARM=7

build() {
  os="$1"
  arch="$2"
  ext=""
  [ "$os" = "windows" ] && ext=".exe"
  out="$DIST_DIR/bequest-server-$VERSION-$os-$arch$ext"
  echo "==> $out"
  (cd "$SERVER_DIR" && GOOS="$os" GOARCH="$arch" \
    go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o "$out" .)
}

build linux amd64
build linux arm64
build linux arm
build linux riscv64
build linux loong64
build windows amd64
build windows arm64
build darwin amd64
build darwin arm64

echo "==> done: VERSION=$VERSION -> $DIST_DIR"
