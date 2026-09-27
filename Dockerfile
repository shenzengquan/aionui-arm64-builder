# =============================================================================
# AionUi Web - ARM64 镜像构建
# =============================================================================
# 为什么不用上游自带的 Dockerfile：
#   官方 v2.2.2 的 Dockerfile 引用了一个不存在的 script：
#     RUN bun run build:renderer:web   -> package.json 里没有这个 script
#     RUN node scripts/build-server.mjs -> scripts/ 目录下没有这个文件
#   上游在 v2.2.x 重构为 monorepo 后，这份 Dockerfile 没有同步更新。
#   本 Dockerfile 依据 v2.2.2 源码里真实存在的构建链编写：
#     bun run package               -> electron-vite 打包前端 SPA 到 out/renderer
#     scripts/pack-web-cli.js       -> 把 web-cli 编译成单文件二进制 + 打包 tarball
#   pack-web-cli.js 内部会调用 prepareAioncore()，从 GitHub Release
#   下载 AionCore（Rust 后端）的 aarch64 预编译产物，不涉及 Rust 编译。
#
# 构建参数：
#   AIONUI_VERSION  AionUi 版本 tag（默认 v2.2.2）
#   AIONCORE_VERSION 由上游 package.json 的 aioncoreVersion 字段决定，
#                    交给 pack-web-cli.js 自动解析，无需手工指定
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: builder —— 在 ARM64 上原生构建 web 产物
# ---------------------------------------------------------------------------
FROM oven/bun:1.2 AS builder

ARG AIONUI_VERSION=v2.2.2
ARG DEBIAN_FRONTEND=noninteractive

# git: 拉源码 / 部分依赖可能需要
# python3 + build-essential: 原生模块（better-sqlite3 等）编译兜底
# curl + ca-certificates: prepareAioncore() 下载 AionCore 二进制
# unzip / tar: 解压上游下载的产物
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      curl \
      ca-certificates \
      python3 \
      make \
      g++ \
      unzip \
      tar \
      gzip \
      xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# 拉取指定版本的源码。--depth 1 只取该 tag 的快照，不拉 4400+ commits 历史
# 加超时与重试：runner 出网偶发抽风时会卡死在这里
RUN set -eux; \
    for i in 1 2 3; do \
      timeout 300 git clone --depth 1 --branch "${AIONUI_VERSION}" \
        https://github.com/iOfficeAI/AionUi.git src && break; \
      echo "!! git clone 第 ${i} 次失败，10s 后重试"; \
      rm -rf src; sleep 10; \
    done; \
    test -d src || { echo "!! git clone 三次均失败"; exit 1; }

WORKDIR /build/src

# 安装依赖。--frozen-lockfile 保证与上游 lockfile 一致，避免依赖漂移
# timeout 900: 超过 15 分钟未完成即视为卡死，直接失败而不是无限等待
RUN set -eux; \
    timeout 900 bun install --frozen-lockfile || { \
      echo "::error::bun install 超时或失败（15 分钟上限）"; exit 1; }

# 前端 SPA 打包 -> out/renderer
RUN set -eux; \
    timeout 900 bun run package || { \
      echo "::error::bun run package 超时或失败（15 分钟上限）"; exit 1; }

# 打包 web-cli：
#   1) prepareAioncore() 下载 AionCore aarch64 预编译包
#   2) bun build --compile --target=bun-linux-arm64 编译单文件二进制
#   3) 合并 out/renderer + bundled-aioncore/linux-arm64
#   4) 产出 dist-web-cli/aionui-web-<version>-linux-arm64.tar.gz + .sha256
# timeout 900: prepareAioncore 要下载 AionCore 产物，网络卡住时会一直挂着
ENV PACK_PLATFORM=linux
ENV PACK_ARCH=arm64
RUN set -eux; \
    timeout 900 node scripts/pack-web-cli.js || { \
      echo "::error::pack-web-cli.js 超时或失败（15 分钟上限），检查 AionCore 下载地址是否可达"; exit 1; }

# 归一化产物名，后续阶段不依赖具体版本号
RUN set -eux; \
    mkdir -p /out; \
    tarball=$(ls dist-web-cli/aionui-web-*-linux-arm64.tar.gz | head -n 1); \
    echo "packed: ${tarball}"; \
    tar -xzf "${tarball}" -C /out; \
    ls -la /out

# ---------------------------------------------------------------------------
# Stage 2: runtime —— 极简运行时，只带产物，不带构建工具链
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS runtime

ARG DEBIAN_FRONTEND=noninteractive

# 运行时依赖说明：
#   ca-certificates  -> 后端调用外部 API（模型网关等）需要
#   libicu-dev       -> AionCore / Office 预览相关组件（.NET 系）需要 ICU 数据
#   tzdata           -> 正确时区显示
#   curl             -> 容器健康检查
#   libstdc++6       -> AionCore（Rust）与 OfficeCLI 二进制的基础运行库
#   libssl3          -> TLS
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      libicu-dev \
      tzdata \
      curl \
      libstdc++6 \
      libssl3 \
    && rm -rf /var/lib/apt/lists/*

# 非 root 运行，降低风险（Agent 类应用能读文件、能起子进程，务必不要 root）
RUN groupadd -g 1000 aionui \
 && useradd -u 1000 -g 1000 -m -s /bin/bash aionui

WORKDIR /app

COPY --from=builder --chown=1000:1000 /out/ /app/

# 数据目录：必须挂到 SATA 卷，不要落在 32GB eMMC 上
RUN mkdir -p /data && chown -R 1000:1000 /data
VOLUME ["/data"]

USER 1000:1000

# 与上游 docker 封装保持一致的环境变量语义
ENV AIONUI_PORT=3000 \
    AIONUI_ALLOW_REMOTE=true \
    AIONUI_DATA_DIR=/data \
    AIONUI_LOG_DIR=/data/logs \
    TZ=Asia/Shanghai \
    NODE_ENV=production

EXPOSE 3000

# 健康检查：容器起来后 HTTP 端口可响应即视为健康
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${AIONUI_PORT}/" >/dev/null || exit 1

# aionui-web 是 pack-web-cli.js 产出的单文件二进制，自带 bun runtime
CMD ["/app/aionui-web", "start"]
