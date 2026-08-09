# syntax=docker/dockerfile:1
# 托孤(bequest)服务器多阶段构建镜像
# 构建: docker build -t ghcr.io/muxinxy/bequest:latest --build-arg VERSION=1.0.0 .

# ---------- 构建阶段 ----------
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/bequest-server .

# ---------- 运行阶段 ----------
FROM alpine:3.20
RUN apk add --no-cache ca-certificates \
    && adduser -D -u 10001 appuser
COPY --from=build /out/bequest-server /usr/local/bin/bequest-server
USER appuser
# 服务器在 CWD 下打开 "data/bequest.db"; WORKDIR=/data 使相对路径落在卷上
WORKDIR /data
ENV DATA_DIR=/data
EXPOSE 8080
VOLUME ["/data"]
ENTRYPOINT ["bequest-server"]
