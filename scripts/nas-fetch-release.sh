#!/usr/bin/env bash
# =============================================================================
# AionUi ARM64 镜像 —— 在 NAS（或任意国内主机）上下载 Release 产物
# =============================================================================
# 为什么需要这个脚本：
#   国内直连 GitHub Release 资产（release-assets.githubusercontent.com）
#   实测只有 ~6 KB/s，221MB 要下 ~9.5 小时，不可用。
#   本脚本自动走国内加速镜像，实测可达 ~760 KB/s（约 5 分钟）。
#
# 用法：
#   ./nas-fetch-release.sh                       # 用默认 tag 2.2.2，下到 ./dist
#   ./nas-fetch-release.sh -t 2.2.2 -o /volume1/docker/aionui/dist
#   ./nas-fetch-release.sh -r shenzengquan/aionui-arm64-builder -t 2.2.2
#
# 特性：
#   - 多镜像自动降级（gh-proxy.com -> ghproxy.net -> 直连 GitHub）
#   - 断点续传（-C -），中断后重跑即可接着下
#   - 下载完自动用 SHA256SUMS 校验
# =============================================================================

set -euo pipefail

REPO="${REPO:-shenzengquan/aionui-arm64-builder}"
TAG="${TAG:-2.2.2}"
OUT_DIR="${OUT_DIR:-./dist}"

# 加速镜像前缀（按实测速度排序，直连放最后兜底）
MIRRORS=(
  "https://gh-proxy.com/https://github.com"
  "https://ghproxy.net/https://github.com"
  "https://github.com"
)

while getopts "r:t:o:h" opt; do
  case "$opt" in
    r) REPO="$OPTARG" ;;
    t) TAG="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    h) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数，用 -h 看用法"; exit 1 ;;
  esac
done

ASSET="aionui-arm64-${TAG}.tar.gz"
REL_PATH="${REPO}/releases/download/aionui-arm64-${TAG}/${ASSET}"
SUM_PATH="${REPO}/releases/download/aionui-arm64-${TAG}/SHA256SUMS"

mkdir -p "$OUT_DIR"

# --- 校验和先下（很小，直连也行） ---
echo ">> 下载校验和 SHA256SUMS"
if curl -sL --fail --retry 3 --max-time 60 -o "${OUT_DIR}/SHA256SUMS" "https://gh-proxy.com/https://github.com/${SUM_PATH}"; then
  echo "   已获取："
  sed 's/^/     /' "${OUT_DIR}/SHA256SUMS"
else
  echo "   !! 校验和下载失败，稍后将跳过校验"
fi

# --- 主产物：多镜像降级 + 断点续传 ---
TARGET="${OUT_DIR}/${ASSET}"
OK=0

for M in "${MIRRORS[@]}"; do
  HOST=$(echo "$M" | sed -E 's#https://([^/]+).*#\1#')
  echo ""
  echo ">> 尝试通道: ${HOST}"
  # 直连通道加 --noproxy 无用（NAS 上没代理），这里统一正常走
  if curl -L --fail --retry 3 --retry-delay 3 --retry-all-errors \
       -C - --connect-timeout 15 --max-time 3600 \
       -o "$TARGET" \
       -w "   完成: HTTP=%{http_code} 平均速度=%{speed_download} B/s\n" \
       "${M}/${REL_PATH}"; then
    OK=1
    break
  fi
  echo "   通道 ${HOST} 失败，换下一个"
done

if [ "$OK" -ne 1 ]; then
  echo ""
  echo "!! 所有通道都失败了。可尝试："
  echo "   1) 手动下载后 scp/SMB 拷到 NAS"
  echo "   2) 改用 GHCR 方式：docker pull ghcr.nju.edu.cn/<你的GHCR路径>:${TAG}"
  exit 1
fi

echo ""
echo ">> 产物大小: $(ls -lh "$TARGET" | awk '{print $5}')"

# --- 校验 ---
if [ -f "${OUT_DIR}/SHA256SUMS" ]; then
  echo ">> 校验 SHA256"
  if ( cd "$OUT_DIR" && sha256sum -c SHA256SUMS ); then
    echo ">> 校验通过 ✅"
  else
    echo "!! 校验失败 —— 文件可能不完整，删掉重下："
    echo "     rm -f ${TARGET} && $0 -t ${TAG} -o ${OUT_DIR}"
    exit 1
  fi
fi

echo ""
echo ">> 下一步（导入并启动）："
echo "     DATA_DIR=/volume1/docker/aionui ./scripts/nas-load-and-deploy.sh ${OUT_DIR} --up"
