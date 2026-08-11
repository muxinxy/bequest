# syntax=docker/dockerfile:1
# 托孤(bequest)服务器多阶段构建镜像(含 Flutter Web 客户端)
# 构建(需在仓库根执行, 先构建 web): 
#   cd app && flutter build web
#   cd .. && docker build -t ghcr.io/muxinxy/bequest:latest --build-arg VERSION=1.0.0 -f server/Dockerfile .

# ---------- 构建阶段:Go 服务端 ----------
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ .
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/bequest-server .

# ---------- 构建阶段:Flutter Web 客户端 ----------
# 复用本地已构建产物(仓库根 app/build/web), 避免镜像构建内跑 Flutter。
FROM scratch AS web
COPY app/build/web /web/

# ---------- 运行阶段 ----------
FROM alpine:3.20
RUN apk add --no-cache ca-certificates \
    && adduser -D -u 10001 appuser
COPY --from=build /out/bequest-server /usr/local/bin/bequest-server
COPY --from=web /web /web
# 数据卷挂载点:预建并授权给 appuser。
# 使用命名卷(compose 默认)时,首次初始化会继承这里的属主与权限,appuser 可直接写入;
# 使用 bind mount 时,宿主机目录需可被 uid 10001 写入(Linux: chown -R 10001:10001 ./data)。
RUN mkdir -p /data && chown appuser:appuser /data
USER appuser
# 服务器在 CWD 下打开 "data/bequest.db"; WORKDIR=/data 使相对路径落在卷上
WORKDIR /data
ENV DATA_DIR=/data WEB_DIR=/web
EXPOSE 8080
VOLUME ["/data"]
ENTRYPOINT ["bequest-server"]
