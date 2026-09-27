#!/usr/bin/env bash
# =============================================================================
# AionUi ARM64 镜像 —— NAS 侧导入 + 启动脚本
# =============================================================================
# 在绿联 DH4300 Plus（RK3588 / ARM64）的终端里执行。
# 前提：已经拿到 GitHub Release 上的 aionui-arm64-<tag>.tar.gz（或其分卷）。
#
# 用法：
#   ./nas-load-and-deploy.sh /path/to/aionui-arm64-2.2.2.tar.gz
#   ./nas-load-and-deploy.sh /path/to/dist        # 传目录，自动处理分卷
#
# 脚本只做三件事：校验 -> docker load -> 提示下一步。
# 不会自动起容器（数据目录需要你自己先建好并填进 .env）。
# =============================================================================

set -euo pipefail

ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
  echo "!! 当前架构是 $ARCH，不是 arm64。这个镜像只能在 ARM64 机器上跑。"
  echo "   如果你在 x86 机器上导入，容器启动会报 exec format error。"
  exit 1
fi

INPUT="${1:-}"
if [ -z "$INPUT" ]; then
  echo "用法: $0 <aionui-arm64-*.tar.gz | 包含分卷的目录>"
  exit 1
fi

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
  # 分卷合并出的临时文件在 SHA256SUMS 里没有条目，跳过
  if grep -q "$BASE" "$SUMDIR/SHA256SUMS" 2>/dev/null; then
    ( cd "$SUMDIR" && grep "$BASE" SHA256SUMS | sha256sum -c - )
    echo ">> 校验通过"
  else
    echo ">> SHA256SUMS 里没有 $BASE 的条目，跳过校验"
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

echo ""
echo "=========================== 下一步 ==========================="
echo "1) 建数据目录（务必落在 SATA 卷，不要用 eMMC）："
echo "     mkdir -p /volume1/docker/aionui"
echo ""
echo "2) 进 deploy/nas 目录，复制并编辑 .env："
echo "     cp .env.example .env"
echo "     vi .env      # 把 AIONUI_DATA_DIR 改成上面的真实路径"
echo ""
echo "3) 启动："
echo "     docker compose up -d"
echo ""
echo "4) 验证："
echo "     docker compose logs -f --tail=50"
echo "     curl -I http://127.0.0.1:3000/"
echo ""
echo "5) 浏览器访问：http://<NAS的IP>:3000"
echo "=============================================================="
