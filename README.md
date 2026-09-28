# aionui-arm64-builder

在 **GitHub Actions 的 ARM64 runner** 上构建 AionUi Web 的 `linux/arm64` Docker 镜像，
产出通过 Release 下载，在绿联 DH4300 Plus（RK3588 / ARM64 / 8GB 板载内存）上 `docker load` 运行。

**目标机不参与构建** —— 绕开 8GB 内存 OOM 风险，也不需要 QEMU 跨架构模拟。

---

## 为什么不用上游自带的 Dockerfile

AionUi v2.2.2 源码里的 `Dockerfile` 是**坏的**，第二步就会失败：

| 上游 Dockerfile 写的 | 实际情况 |
|---|---|
| `RUN bun run build:renderer:web` | `package.json` 里**没有**这个 script |
| `RUN node scripts/build-server.mjs` | `scripts/` 目录下**没有**这个文件 |

上游在 v2.2.x 重构成 monorepo（`packages/*`）后，这份 Dockerfile 没有跟着更新。
本仓库的 `Dockerfile` 依据 v2.2.2 源码里**真实存在**的构建链重写：

```
bun install
bun run package                    → electron-vite 打包前端 SPA 到 out/renderer
node scripts/pack-web-cli.js       → 编译单文件二进制 + 下载 AionCore + 打 tarball
```

`pack-web-cli.js` 内部会调 `prepareAioncore()`，从 `iOfficeAI/AionCore` 的 Release
下载 **aarch64 预编译产物**（`aioncore-{tag}-aarch64-unknown-linux-gnu.tar.gz`），
**不需要在构建时编译 Rust**，也不需要在 NAS 上装 Rust 工具链。

---

## 目录结构

```
.
├── Dockerfile                              # 两阶段构建：builder(bun) → runtime(debian-slim)
├── .github/workflows/
│   └── build-aionui-arm64.yml              # GitHub Actions 工作流（核心）
├── deploy/nas/
│   ├── docker-compose.yml                  # NAS 侧运行编排
│   └── .env.example                        # 环境变量模板
├── scripts/
│   ├── nas-fetch-release.sh                # NAS 侧下载 Release 产物（自动走国内加速镜像）
│   ├── nas-load-and-deploy.sh              # NAS 侧导入脚本（校验 + docker load + 可选 --up）
│   ├── watch-build.sh                      # 盯梢构建，成功后自动下载 Release 产物
│   ├── fetch-build-logs.sh                 # 拉取并打印 run 的完整日志（需 admin PAT）
│   └── push-to-github.sh                   # 初始化仓库并推送
├── .gitattributes                          # 强制 .sh/.yml 用 LF
├── .gitignore
└── .dockerignore
```

---

## 使用流程

### 第 1 步：在 GitHub 上建仓库并推送

```bash
git init
git add .
git commit -m "build: AionUi ARM64 image workflow"
git branch -M main
git remote add origin https://github.com/<你的用户名>/aionui-arm64-builder.git
git push -u origin main
```

> **仓库要设为 Public** —— 公开仓库的 ARM64 runner 免费不限量；
> 私有仓库会消耗你账号的 Actions 分钟数。

### 第 2 步：触发构建

仓库页面 → **Actions** → 左侧选 `build-aionui-arm64` → **Run workflow** → 填参数：

| 参数 | 说明 | 默认 |
|---|---|---|
| `aionui_version` | AionUi 版本 tag | `v2.2.2` |
| `image_tag` | 构建出的镜像 tag | `2.2.2` |

构建流程（约 8-15 分钟）：

1. 拉取 `ubuntu-24.04-arm` runner（4 核 / 16GB / 原生 ARM64）
2. `docker build` —— clone 源码 → `bun install` → `bun run package` → `pack-web-cli.js`
3. **冒烟测试** —— 起容器，轮询 60 秒等 HTTP 就绪，失败直接判定构建失败
4. `docker save | gzip` 导出，超过 1900MB 自动分卷
5. 上传 artifact + 发布到 Release

### 第 3 步：下载产物

构建完成后，**Releases** 页面会出现 `aionui-arm64-2.2.2`，包含：

```
aionui-arm64-2.2.2.tar.gz          # 单文件归档（< 1.9GB 时）
  — 或 —
aionui-arm64-2.2.2.tar.gz.part-00  # 分卷（> 1.9GB 时）
aionui-arm64-2.2.2.tar.gz.part-01
SHA256SUMS                          # 校验和
```

### 第 4 步：传到 NAS 并导入

> **⚠️ 国内网络必看：不要直连 GitHub 下载。**
> 实测直连 Release 资产（`release-assets.githubusercontent.com`）只有 **~6 KB/s**，
> 221MB 要下 **约 9.5 小时**；走加速镜像可达 **~3 MB/s，约 70 秒**。

在 NAS 终端里（SSH 或 UGOS 自带终端）：

```bash
# 方式 A（推荐）：用仓库里的脚本自动走加速镜像 + 断点续传 + 校验
./scripts/nas-fetch-release.sh -t 2.2.2 -o /volume1/docker/aionui/dist

# 方式 B：手动用镜像下载
curl -L -O https://gh-proxy.com/https://github.com/<你的用户名>/aionui-arm64-builder/releases/download/aionui-arm64-2.2.2/aionui-arm64-2.2.2.tar.gz
curl -L -O https://gh-proxy.com/https://github.com/<你的用户名>/aionui-arm64-builder/releases/download/aionui-arm64-2.2.2/SHA256SUMS

# 方式 C：在 Windows 上下好（同样走镜像），用 UGOS 文件管理器传上去

# 导入（脚本会先校验架构和 sha256，再 docker load）
./scripts/nas-load-and-deploy.sh ./aionui-arm64-2.2.2.tar.gz
```

> 镜像前缀可按需替换：`gh-proxy.com`（实测最快）→ `ghproxy.net`（备用）。
> 这类服务只转发**公开**资源，不要用来传带 token 的私有下载链接。
>
> 如果是分卷，把整个目录传给脚本即可：`./nas-load-and-deploy.sh ./dist`
> 脚本会自动 `cat part-*` 合并。

### 第 5 步：起容器

```bash
cd deploy/nas
cp .env.example .env
vi .env      # 【必须】把 AIONUI_DATA_DIR 改成你的 SATA 卷路径

docker compose up -d
docker compose logs -f --tail=50
```

浏览器访问 `http://<NAS的IP>:3000`。

---

## NAS 侧的关键约束

### 数据目录必须落在 SATA 卷

绿联 DH4300 Plus 的系统盘只有 **32GB eMMC**，Docker 数据写进去很快会满。

`.env` 里的 `AIONUI_DATA_DIR` 要指向 SATA 卷，例如：

```
AIONUI_DATA_DIR=/volume1/docker/aionui
```

先确认挂载点（在 NAS 上执行）：

```bash
df -h | grep -E "volume|mnt"
```

### 内存分配

RK3588 是 **8GB 板载内存、不可扩展**，且大概率还跑着别的 Docker 服务。
`docker-compose.yml` 里给了 AionUi **2GB 上限 + 512MB 保底**。

> **为什么是 2G 而不是 3G**：实测 NAS 上 `free -h` 常常只剩 3~4G available，
> 且 swap 已经在用（`Swap used ≈ 2.5G`）。给太大反而更容易触发系统级 OOM，
> 把别的容器一起拖死。AionUi 空载实测只占 ~75MB，2G 上限绰绰有余。
> 如果 NAS 上还有别的大内存服务，可以进一步调到 `1.5g`。

### ⚠️ 运行用户必须是 root（绿联 UGOS 特有问题）

这是**本项目在绿联 NAS 上最容易踩的坑**，症状具有误导性：

```
[aionui-web] fatal: EACCES: permission denied, mkdir '/data/logs'
```

看起来是权限不足，但 `ls -ld` 会发现数据目录已经是 **`drwxrwxrwx`（777）**，
容器内 `touch` 测试文件**成功**，只有 `mkdir` 被拒。

**根因**：绿联 UGOS 的卷用 `ugacl` 挂载：

```
/dev/mapper/ug_...-volume1 on /data type btrfs (rw,...,ugacl,...)
```

`ugacl` **不按 POSIX 的 other 位判定写权限**，只认属主和显式 ACL 条目。
目录属主是 `18380401399:admin`（uid **1001**），而镜像内建的非 root 用户是
uid **1000** → 既不是属主，又没有 ACL 条目 → `mkdir` 被拒。
（`touch` 能过是因为它走的是另一条判定路径。）

**为什么不能 chown 解决**：NAS 上普通用户执行
`chown -R 1000:1000 <dir>` 会直接报
`chown: changing ownership ...: Operation not permitted`，
而 `sudo` 需要密码（非免密）。

**解决**：在 compose 里显式指定 `user: "0:0"`。

```yaml
user: "0:0"     # 见 docker-compose.yml 的注释说明
```

> 这与 NAS 上既有的 `czyt/aionui` 容器做法一致 —— 它同样以 root 运行
> （`docker inspect` 的 `.Config.User` 为空 = uid 0）。
>
> 安全性权衡：镜像本身**设计了**非 root（uid 1000）运行，这是更好的做法；
> 但在 UGOS 的限制下，要么用 root，要么得先拿到 root 权限 chown。
> 容器只挂载 `/data` 一个目录、只暴露一个端口，风险面可控。

**判断当前容器是不是踩了这个坑**：

```bash
docker inspect aionui --format '{{.Config.User}}'          # 应为 0:0
docker logs aionui 2>&1 | grep EACCES                       # 应为空
```

### 端口冲突检查

绿联 NAS 上很可能已经跑着第三方 AionUi 镜像（如 `czyt/aionui`）。
部署前先确认：

```bash
docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep -E 'aionui|3000'
```

两者可以并存（映射到不同宿主端口即可），但**数据目录不要共用**。

### 架构校验

`nas-load-and-deploy.sh` 会先检查 `uname -m` 是不是 `aarch64`。
在 x86 机器上导入这个镜像不会报错，但**容器启动时会 `exec format error`** ——
脚本提前把这种情况拦掉。

---

## 排查

### 下载产物慢到不可用（国内网络）

症状：`curl` 下载 Release 的 tar.gz，速度只有几 KB/s，进度条显示要几十小时。

原因：GitHub Release 资产实际由 `release-assets.githubusercontent.com` 提供，
国内直连被严重限速。

实测数据（同一台机器、同一时间）：

| 通道 | 实测速度 | 221MB 耗时 |
|---|---|---|
| 直连 `github.com` / `release-assets.githubusercontent.com` | ~6.5 KB/s | ~9.5 小时 |
| `ghproxy.net` | ~240 KB/s | ~15 分钟 |
| `gh-proxy.com` | ~3 MB/s | ~70 秒 |

解决：用 `scripts/nas-fetch-release.sh`，它会自动按 `gh-proxy.com` → `ghproxy.net` → 直连
的顺序降级，并支持断点续传和 sha256 校验。

> 注意：`ghproxy.net` 之外的几个常见镜像（`ghfast.top`、`gh.llkk.cc`、`github.moeyy.xyz`）
> 在测试时**不可达**，不要盲试。
>
> 另一个备选是走 GHCR：把镜像 push 到 GHCR，NAS 上 `docker pull ghcr.nju.edu.cn/<路径>:<tag>`。
> 南京大学 GHCR 镜像 `ghcr.nju.edu.cn` 实测可达（`/v2/` 返回 200）。

### 忘记 / 拿不到管理员密码

首次启动会生成随机密码并打印在日志里：

```bash
docker logs aionui 2>&1 | grep -A2 "Generated initial admin password"
```

**如果日志已经滚掉、或者拿不到密码**，用 `resetpass` 重置：

```bash
# ⚠️ 必须先停容器！运行中执行会失败
docker compose stop

docker run --rm --user 0:0 \
  -v /volume1/docker/aionui/data:/data \
  -e AIONUI_DATA_DIR=/data \
  --entrypoint /app/aionui-web \
  aionui:2.2.2 resetpass

docker compose start
```

> **为什么必须先停容器**：AionUi 对数据目录有 `instance_guard` 独占锁。
> 在运行中执行 `resetpass`，它会试图再起一个 aioncore，
> 但拿不到锁 → 反复重试 `BOOTSTRAP_PEER_ALREADY_RUNNING` →
> 最终 `fatal: aioncore exited before health check passed`，
> **重置失败且看不出原因**。停容器后执行即可，输出里的
> `new password: xxxxx` 就是新密码。

### 构建卡死不动（长时间 in_progress）

症状：`Build ARM64 image` 步骤跑了几十分钟甚至几小时仍不结束，Release 不出现。

工作流已做的防御：

| 措施 | 作用 |
|---|---|
| `timeout-minutes: 60`（job 级） | 卡死 60 分钟自动失败，不再无限干等 |
| `--progress=plain` + 逐行时间戳 | 关掉折叠进度条，实时看到停在哪个 `RUN` |
| `Network reachability check` 步骤 | 构建前先探 npm/github/AionCore 三个关键端点 |
| Dockerfile 内 `timeout 300/900` | `git clone` / `bun install` / `bun run package` / `pack-web-cli.js` 各自限时 |
| `ENV CI=true` | **关键** —— 让上游 `postinstall.js` 走预编译分支，不触发 ARM64 上会卡死的本地重编译 |

> `ENV CI=true` 这一条最容易被忽略：`docker build` **不会继承宿主机的环境变量**，
> 容器里 `CI` 是空的，上游 `scripts/postinstall.js` 就会走
> `bunx electron-builder install-app-deps` 的重量级本地重编译分支 ——
> 在 ARM64 上表现为**静默挂起、无任何输出**（GitHub 侧日志 API 都返回 `BlobNotFound`，
> 因为 job 压根没产生输出）。

定位卡点最直接的方式 —— **在本地拉日志**：

```bash
# 需要一个具备 repo admin 权限的 PAT（classic，scope: repo + workflow）
GH_TOKEN=ghp_xxxx ./scripts/fetch-build-logs.sh 36307008891 "Build ARM64 image"
```

> GitHub 的 run logs API 要求 admin 权限，普通 connector 凭据会返回
> `403 Must have admin rights to Repository`，所以必须显式传 PAT。

如果日志显示卡在 `bun install`，通常是 npm registry 偶发抽风 —— 重跑即可。
如果卡在 `pack-web-cli.js`，检查 AionCore 的 Release 资产命名是否变化。

### 构建阶段失败

| 现象 | 原因 | 处理 |
|---|---|---|
| `bun install` 失败 | 上游 lockfile 与依赖树不一致 | 把 Dockerfile 里的 `--frozen-lockfile` 去掉重跑 |
| `prepareAioncore()` 下载失败 | AionCore Release 地址变更 / 网络 | 看 CI 日志里的下载 URL，核对 `iOfficeAI/AionCore` 的 release assets |
| `bun build --compile` 失败 | bun 版本与上游不匹配 | 调整 Dockerfile 首行 `FROM oven/bun:<版本>` |
| 冒烟测试超时 | 二进制能编译但跑不起来 | 看 CI 日志里 `docker logs aionui-smoke` 的输出 |

### 运行阶段失败

```bash
# 容器起不来 / 反复重启
docker compose logs --tail=100 aionui

# 确认镜像架构
docker image inspect aionui:2.2.2 --format '{{.Architecture}}'   # 应为 arm64

# 进容器看二进制是否存在
docker run --rm --entrypoint sh aionui:2.2.2 -c 'ls -la /app'

# 数据目录权限（容器内以 uid 1000 运行）
ls -la /volume1/docker/aionui
```

### 关于 Office 预览功能

上游为 Office 预览装了 `libicu-dev`，对应的是 .NET 系二进制。
`iOfficeAI/OfficeCLI` 的 Release 里有 `officecli-linux-arm64` 资产，**arm64 是有的**，
但这条链路能否在 RK3588 上完整跑通，**只能实际点击 Office 预览才知道**。
如果这个功能报错，其余功能不受影响。

---

## 升级到新版本

上游发新版时：

1. Actions → Run workflow → `aionui_version` 填新 tag（如 `v2.2.3`）、`image_tag` 填 `2.2.3`
2. 如果新版本改了构建链（`pack-web-cli.js` 路径变了、AionCore 命名规则变了），
   Dockerfile 需要同步调整 —— 先 diff 上游的 `package.json` scripts 段和 `scripts/` 目录
3. NAS 侧重新 `docker load` + 改 `.env` 里的 `AIONUI_IMAGE_TAG` + `docker compose up -d`

---

## 已知限制

- 镜像基于 `debian:bookworm-slim`，体积约 **400-600MB**（含 AionCore 后端 + bun 单文件二进制）
- 首次启动会初始化 SQLite 数据库，需要几十秒
- 不使用 `czyt/aionui` 等第三方镜像 —— 来源与版本均不可控
- 不使用上游 Dockerfile —— 已确认损坏
