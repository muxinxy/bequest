#!/usr/bin/env sh
# 托孤(bequest)服务器交叉编译脚本(仓库根目录执行: ./scripts/build.sh)
# 产物输出到 dist/bequest-server-<os>-<arch>[.exe]
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

build() {
  os="$1"
  arch="$2"
  ext=""
  [ "$os" = "windows" ] && ext=".exe"
  out="$DIST_DIR/bequest-server-$os-$arch$ext"
  echo "==> $out"
  (cd "$SERVER_DIR" && GOOS="$os" GOARCH="$arch" \
    go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o "$out" .)
}

build linux amd64
build linux arm64
build windows amd64
build darwin amd64
build darwin arm64

echo "==> done: VERSION=$VERSION -> $DIST_DIR"
