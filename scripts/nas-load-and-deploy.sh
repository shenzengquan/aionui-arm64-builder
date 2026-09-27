#!/usr/bin/env bash
# =============================================================================
# AionUi ARM64 镜像 —— NAS 侧导入 + 启动一条龙
# =============================================================================
# 在绿联 DH4300 Plus（RK3588 / ARM64）的终端里执行。
# 前提：已经拿到 GitHub Release 上的 aionui-arm64-<tag>.tar.gz（或其分卷）。
#
# 用法：
#   ./nas-load-and-deploy.sh /path/to/aionui-arm64-2.2.2.tar.gz
#   ./nas-load-and-deploy.sh /path/to/dist            # 传目录，自动处理分卷
#   ./nas-load-and-deploy.sh /path/to/dist --up       # 导入后直接起容器
#   DATA_DIR=/volume2/docker/aionui ./nas-load-and-deploy.sh dist --up
#
# 默认只做：校验 -> docker load -> 打印下一步。
# 加 --up 才会起容器（会先检查/创建数据目录）。
# =============================================================================

set -euo pipefail

TAG="${AIONUI_IMAGE_TAG:-2.2.2}"
DATA_DIR="${DATA_DIR:-/volume1/docker/aionui}"
PORT="${AIONUI_PORT:-3000}"
DO_UP=0
INPUT=""

# --- 解析参数 ---
for arg in "$@"; do
  case "$arg" in
    --up) DO_UP=1 ;;
    -*) echo "未知参数: $arg"; exit 1 ;;
    *) INPUT="$arg" ;;
  esac
done

ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
  echo "!! 当前架构是 $ARCH，不是 arm64。这个镜像只能在 ARM64 机器上跑。"
  echo "   如果你在 x86 机器上导入，容器启动会报 exec format error。"
  exit 1
fi

if [ -z "$INPUT" ]; then
  echo "用法: $0 <aionui-arm64-*.tar.gz | 包含分卷的目录> [--up]"
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

ARCHIVE=""

if [ -d "$INPUT" ]; then
  # 目录模式：先看有没有单文件归档，没有再看分卷
  SINGLE=$(ls "$INPUT"/aionui-arm64-*.tar.gz 2>/dev/null | head -n 1 || true)
  if [ -n "$SINGLE" ]; then
    ARCHIVE="$SINGLE"
    echo ">> 找到单文件归档: $ARCHIVE"
  else
    PARTS=$(ls "$INPUT"/aionui-arm64-*.tar.gz.part-* 2>/dev/null || true)
    if [ -z "$PARTS" ]; then
      echo "!! 目录里既没有 aionui-arm64-*.tar.gz，也没有分卷"
      exit 1
    fi
    echo ">> 检测到分卷，开始合并"
    # 分卷由 split 生成，part-00 part-01 ... 按名字排序拼接即可
    cat "$INPUT"/aionui-arm64-*.tar.gz.part-* > "$WORKDIR/merged.tar.gz"
    ARCHIVE="$WORKDIR/merged.tar.gz"
    echo ">> 合并完成: $(ls -lh "$ARCHIVE" | awk '{print $5}')"
  fi
else
  ARCHIVE="$INPUT"
  echo ">> 使用指定归档: $ARCHIVE"
fi

# --- 校验（如果同目录有 SHA256SUMS） ---
SUMDIR=$(dirname "$ARCHIVE")
if [ -f "$SUMDIR/SHA256SUMS" ]; then
  echo ">> 发现 SHA256SUMS，执行校验"
  BASE=$(basename "$ARCHIVE")
  if grep -q "$BASE" "$SUMDIR/SHA256SUMS" 2>/dev/null; then
    ( cd "$SUMDIR" && grep "$BASE" SHA256SUMS | sha256sum -c - )
    echo ">> 校验通过"
  else
    # 单文件归档的情况：SHA256SUMS 里记的是 aionui-arm64-<tag>.tar.gz
    CANDIDATE="aionui-arm64-${TAG}.tar.gz"
    if [ "$BASE" = "$CANDIDATE" ] && grep -q "$CANDIDATE" "$SUMDIR/SHA256SUMS" 2>/dev/null; then
      ( cd "$SUMDIR" && grep "$CANDIDATE" SHA256SUMS | sha256sum -c - )
      echo ">> 校验通过"
    else
      echo ">> SHA256SUMS 里没有 $BASE 的条目，跳过校验"
    fi
  fi
else
  echo ">> 未找到 SHA256SUMS，跳过校验（建议手动核对）"
fi

# --- 导入 ---
echo ">> 开始 docker load（大镜像可能需要 1-3 分钟）"
gunzip -c "$ARCHIVE" | docker load

echo ""
echo ">> 当前本地镜像："
docker images | grep -E "REPOSITORY|aionui" || true

# --- 架构复核 ---
echo ""
if docker image inspect "aionui:${TAG}" --format '{{.Architecture}}' 2>/dev/null | grep -q arm64; then
  echo ">> 镜像架构确认: arm64"
else
  echo "!! 警告：镜像架构不是 arm64，或 tag aionui:${TAG} 不存在"
  docker images | grep aionui || true
fi

# --- 可选：直接起容器 ---
if [ "$DO_UP" -eq 1 ]; then
  echo ""
  echo ">> --up 已指定，准备启动容器"

  # 数据目录必须落在 SATA 卷
  case "$DATA_DIR" in
    /volume*|/mnt/*|/sata*)
      echo ">> 数据目录: $DATA_DIR"
      ;;
    *)
      echo "!! 数据目录 $DATA_DIR 看起来不在 SATA 卷上。"
      echo "   绿联 DH4300 Plus 系统盘只有 32GB eMMC，写满会导致系统异常。"
      echo "   请用 /volume1/... 或 /mnt/... 路径。确认继续请重新执行并显式设置 DATA_DIR。"
      exit 1
      ;;
  esac

  if [ ! -d "$DATA_DIR" ]; then
    echo ">> 创建数据目录: $DATA_DIR"
    mkdir -p "$DATA_DIR"
  fi
  # 容器内以 uid 1000 运行
  chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || echo "（chown 失败，可能权限不足，容器可能无法写入）"

  cd "$SCRIPT_DIR/deploy/nas"
  if [ ! -f .env ]; then
    cp .env.example .env
    echo ">> 已生成 .env，请确认以下两行后重新执行 --up："
    echo "     AIONUI_DATA_DIR=$DATA_DIR"
    echo "     AIONUI_IMAGE_TAG=$TAG"
    exit 0
  fi

  DATA_DIR="$DATA_DIR" AIONUI_IMAGE_TAG="$TAG" AIONUI_PORT="$PORT" docker compose up -d
  echo ""
  docker compose ps
  echo ""
  echo ">> 浏览器访问: http://<NAS的IP>:${PORT}"
  echo ">> 查看日志:   docker compose logs -f --tail=50"
  exit 0
fi

echo ""
echo "=========================== 下一步 ==========================="
echo "1) 确认 SATA 卷挂载点："
echo "     df -h | grep -E 'volume|mnt'"
echo ""
echo "2) 建数据目录（务必落在 SATA 卷，不要用 eMMC）："
echo "     mkdir -p ${DATA_DIR}"
echo ""
echo "3) 进 deploy/nas 目录，复制并编辑 .env："
echo "     cd ${SCRIPT_DIR}/deploy/nas"
echo "     cp .env.example .env"
echo "     vi .env      # 把 AIONUI_DATA_DIR 改成上面的真实路径"
echo ""
echo "4) 启动："
echo "     docker compose up -d"
echo ""
echo "5) 验证："
echo "     docker compose logs -f --tail=50"
echo "     curl -I http://127.0.0.1:${PORT}/"
echo ""
echo "6) 浏览器访问：http://<NAS的IP>:${PORT}"
echo ""
echo "或者直接一条命令搞定（自动建目录 + 起容器）："
echo "     DATA_DIR=${DATA_DIR} $0 ${INPUT} --up"
echo "=============================================================="
