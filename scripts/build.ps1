# 托孤(bequest)服务器 Windows 构建脚本(在仓库根目录执行: .\scripts\build.ps1)
# 默认构建 windows/amd64 + linux/amd64, 产物输出到 dist\
#
# 用法:
#   .\scripts\build.ps1                        # 版本 dev, 默认 goproxy.cn
#   $env:VERSION = "1.0.0"; .\scripts\build.ps1   # 注入 main.version
#   $env:GOPROXY = "https://proxy.golang.org,direct"; .\scripts\build.ps1  # 覆盖代理
$ErrorActionPreference = "Stop"

$Version = if ($env:VERSION) { $env:VERSION } else { "dev" }

# 国内网络默认走 goproxy.cn; 可用 $env:GOPROXY 覆盖
if (-not $env:GOPROXY) {
    $env:GOPROXY = "https://goproxy.cn,direct"
}

$Root     = Split-Path -Parent $PSScriptRoot
$ServerDir = Join-Path $Root "server"
$DistDir  = Join-Path $Root "dist"
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

$env:CGO_ENABLED = "0"
$ldflags = "-s -w -X main.version=$Version"

Push-Location $ServerDir
try {
    foreach ($t in @(@("windows", "amd64"), @("linux", "amd64"))) {
        $os, $arch = $t
        $ext  = if ($os -eq "windows") { ".exe" } else { "" }
        $out  = Join-Path $DistDir "bequest-server-$os-$arch$ext"
        Write-Host "==> $out"
        $env:GOOS   = $os
        $env:GOARCH = $arch
        & go build -trimpath -ldflags $ldflags -o $out .
        if ($LASTEXITCODE -ne 0) { throw "go build failed for $os/$arch" }
    }
}
finally {
    Pop-Location
}
Write-Host "==> done: VERSION=$Version -> $DistDir"
