#!/usr/bin/env bash
# =============================================================================
# 后台盯梢 GitHub Actions 构建 + 自动下载 Release 产物
# =============================================================================
# 轮询 workflow run 状态，构建成功后自动从 Release 下载 tar.gz / SHA256SUMS
# 到本地 dist/ 目录。构建失败则输出日志尾部并退出。
#
# 用法：
#   ./watch-build.sh [run_id] [输出目录]
#   ./watch-build.sh 36307008891 ./dist
# =============================================================================

set -uo pipefail

RUN_ID="${1:-36307008891}"
OWNER="shenzengquan"
REPO="aionui-arm64-builder"
OUT_DIR="${2:-./dist}"
INTERVAL=60

mkdir -p "$OUT_DIR"
API="https://api.github.com/repos/${OWNER}/${REPO}/actions/runs/${RUN_ID}"

echo "[$(date '+%H:%M:%S')] 开始盯梢 run ${RUN_ID}"
echo "[$(date '+%H:%M:%S')] 轮询间隔: ${INTERVAL}s"

while true; do
  JSON=$(curl -s "$API")
  STATUS=$(echo "$JSON" | grep -o '"status": *"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')
  CONCLUSION=$(echo "$JSON" | grep -o '"conclusion": *"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')

  case "$STATUS" in
    in_progress|queued|requested|waiting|pending)
      echo "[$(date '+%H:%M:%S')] 状态: ${STATUS} ... 继续等待"
      sleep "$INTERVAL"
      ;;
    completed)
      echo "[$(date '+%H:%M:%S')] 构建结束，结论: ${CONCLUSION}"
      if [ "$CONCLUSION" != "success" ]; then
        echo "[$(date '+%H:%M:%S')] !! 构建未成功，拉取失败日志尾部："
        curl -s "https://api.github.com/repos/${OWNER}/${REPO}/actions/runs/${RUN_ID}/jobs" \
          | grep -o '"name": *"[^"]*"' | head -n 20
        exit 1
      fi
      break
      ;;
    *)
      echo "[$(date '+%H:%M:%S')] 未知状态: ${STATUS}，继续等待"
      sleep "$INTERVAL"
      ;;
  esac
done

# --- 构建成功，从 Release 下载产物 ---
TAG="aionui-arm64-2.2.2"
BASE="https://github.com/${OWNER}/${REPO}/releases/download/${TAG}"

echo "[$(date '+%H:%M:%S')] 下载 Release 产物到 ${OUT_DIR}"
cd "$OUT_DIR"

# 先探一下是单文件还是分卷
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -I "${BASE}/aionui-arm64-2.2.2.tar.gz")
if [ "$HTTP_CODE" = "200" ]; then
  echo "[$(date '+%H:%M:%S')] 单文件归档模式"
  curl -L -o "aionui-arm64-2.2.2.tar.gz" "${BASE}/aionui-arm64-2.2.2.tar.gz"
else
  echo "[$(date '+%H:%M:%S')] 分卷模式，逐个下载 part-*"
  for i in 00 01 02 03 04 05; do
    P="aionui-arm64-2.2.2.tar.gz.part-${i}"
    CODE=$(curl -s -o /dev/null -w '%{http_code}' -I "${BASE}/${P}")
    if [ "$CODE" = "200" ]; then
      echo "  下载 ${P}"
      curl -L -o "${P}" "${BASE}/${P}"
    else
      break
    fi
  done
fi

curl -L -o SHA256SUMS "${BASE}/SHA256SUMS" || true

echo "[$(date '+%H:%M:%S')] 下载完成，产物清单："
ls -lh
echo "[$(date '+%H:%M:%S')] 校验："
if [ -f SHA256SUMS ]; then
  sha256sum -c SHA256SUMS 2>&1 | tail -n 20 || echo "（部分条目校验失败或为分卷，需 NAS 侧合并后校验）"
fi
echo "[$(date '+%H:%M:%S')] 全部完成"
