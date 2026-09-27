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

# ---------------------------------------------------------------------------
# 关键修复：让容器内的 CI 语义与上游 CI 一致
# ---------------------------------------------------------------------------
# 上游 package.json 的 postinstall（scripts/postinstall.js）会判断：
#     isCI = process.env.CI === 'true' || process.env.GITHUB_ACTIONS === 'true'
#   - isCI 为真 → 跳过重建，直接用预编译二进制（上游 CI 走的就是这条路）
#   - isCI 为假 → 执行 bunx electron-builder install-app-deps
#                并带 npm_config_build_from_source=true（从源码重建原生模块）
#
# 坑：docker build 不会把宿主机的环境变量带进容器，
#     所以在 Actions runner 里跑 docker build 时，容器内 CI/GITHUB_ACTIONS 都是空的，
#     postinstall 会误判为"本地环境"，去跑 electron-builder 从源码重建 —— 
#     这一步在 ARM64 上会长时间静默卡死（实测挂满 900s 无任何输出）。
#
# 显式设 CI=true，让容器内行为与上游 CI 对齐。
ENV CI=true

# 优先走 IPv4：GitHub runner 上 registry.npmjs.org 有时只解析出 IPv6，
# 而 IPv6 出口不通会造成"连接建立后静默挂起"（无报错、无超时）。
RUN echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

# 我们只构建 web CLI，不需要 Electron 运行时；
# 跳过 Electron 二进制下载，避免另一个大体积下载成为挂死源。
ENV ELECTRON_SKIP_BINARY_DOWNLOAD=1

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

# 容器内出网自检：确认 registry 可达，并打印实际使用的出口 IP 版本
# （若 remote_ip 是 IPv6 且随后安装挂死，即可确认是 IPv6 出口问题）
RUN set -eux; \
    echo "=== in-container 出网自检 ==="; \
    getent ahosts registry.npmjs.org | head -n 6 || true; \
    curl -sS -o /dev/null -m 20 \
      -w 'registry.npmjs.org -> HTTP %{http_code}, remote_ip=%{remote_ip}\n' \
      https://registry.npmjs.org/ || true

# 安装依赖。--frozen-lockfile 保证与上游 lockfile 一致，避免依赖漂移
# --verbose: 打印每个包的解析/下载细节 —— 万一再挂死，日志能直接指出卡在哪个包
# 重试 2 次：网络偶发挂起时给一次重来的机会
# timeout 600: 单次超过 10 分钟无进展即判定挂死
RUN set -eux; \
    for i in 1 2; do \
      timeout 600 bun install --frozen-lockfile --verbose && break; \
      echo "!! bun install 第 ${i} 次超时/失败，20s 后重试"; \
      sleep 20; \
    done; \
    test -d node_modules || { \
      echo "::error::bun install 两次均失败（见上方 verbose 输出定位卡点）"; exit 1; }

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
#
# 重要：pack-web-cli.js 用 `tar -C stagingDir aionui-web` 打包，
# 所以 tarball 里的结构是：
#     aionui-web/                     <- 顶层目录
#       ├── aionui-web                <- 真正的单文件可执行二进制
#       ├── package.json
#       ├── static/                   <- SPA 前端资源
#       └── bundled-aioncore/linux-arm64/
# 解压后必须取内层 `aionui-web/` 的内容作为应用根，
# 否则 /app/aionui-web 会是个目录，启动时报
#     exec: "/app/aionui-web": is a directory: permission denied
RUN set -eux; \
    mkdir -p /out; \
    tarball=$(ls dist-web-cli/aionui-web-*-linux-arm64.tar.gz | head -n 1); \
    echo "packed: ${tarball}"; \
    tar -xzf "${tarball}" -C /out; \
    echo "=== tarball 解压后的顶层结构 ==="; \
    ls -la /out; \
    ls -la /out/aionui-web; \
    test -f /out/aionui-web/aionui-web || { \
      echo "::error::未找到可执行文件 /out/aionui-web/aionui-web，tarball 结构与预期不符"; exit 1; }; \
    chmod +x /out/aionui-web/aionui-web; \
    echo "=== 可执行文件确认（架构 + 大小） ==="; \
    file /out/aionui-web/aionui-web 2>/dev/null || true; \
    ls -lh /out/aionui-web/aionui-web

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

# 注意源路径末尾的 `aionui-web/`：
# 把 tarball 内层目录的【内容】铺到 /app，
# 使得可执行文件落在 /app/aionui-web（而不是 /app/aionui-web/aionui-web）
# 同级的 static/ 与 bundled-aioncore/ 也一并落在 /app 下，保持相对路径不变。
COPY --from=builder --chown=1000:1000 /out/aionui-web/ /app/

# 数据目录：必须挂到 SATA 卷，不要落在 32GB eMMC 上
RUN mkdir -p /data && chown -R 1000:1000 /data
VOLUME ["/data"]

# 构建期自检：确保入口文件和关键产物都就位。
# 放在这里可以让问题在 docker build 阶段就暴露，而不是拖到冒烟测试
# （曾因 /app/aionui-web 是目录而非文件，导致容器启动报
#   exec: "/app/aionui-web": is a directory: permission denied）
RUN set -eux; \
    test -f /app/aionui-web || { echo "::error::缺少入口文件 /app/aionui-web"; exit 1; }; \
    test -x /app/aionui-web || { echo "::error::/app/aionui-web 不可执行"; exit 1; }; \
    test -d /app/static || { echo "::error::缺少前端资源 /app/static"; exit 1; }; \
    test -d /app/bundled-aioncore || { echo "::error::缺少后端 /app/bundled-aioncore"; exit 1; }; \
    echo "=== runtime 产物自检通过 ==="; \
    ls -la /app

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
