#!/usr/bin/env bash
# =============================================================================
# 后台盯梢 GitHub Actions 构建 + 自动下载 Release 产物
# =============================================================================
# 轮询 workflow run 状态，构建成功后自动从 Release 下载 tar.gz / SHA256SUMS
# 到本地 dist/ 目录。构建失败则列出失败步骤名并退出。
#
# 用法：
#   GH_TOKEN=ghp_xxx ./watch-build.sh <run_id> [tag] [输出目录]
#   GH_TOKEN=ghp_xxx ./watch-build.sh 36318133655 2.2.2 ./dist
#
# 说明：
#   - 用 Python 解析 JSON（比 grep 稳，API 空响应不会误判成"未知状态"刷屏）
#   - 轮询期间遇限流/空响应会静默重试
# =============================================================================

set -uo pipefail

RUN_ID="${1:?用法: $0 <run_id> [tag] [输出目录]}"
TAG="${2:-2.2.2}"
OUT_DIR="${3:-./dist}"
INTERVAL=60

OWNER="shenzengquan"
REPO="aionui-arm64-builder"
API="https://api.github.com/repos/${OWNER}/${REPO}"
PY="C:/Users/申增权/.workbuddy/binaries/python/versions/3.13.12/python.exe"

if [ -z "${GH_TOKEN:-}" ]; then
  echo "!! 需要 GH_TOKEN（具备 repo 权限的 PAT）"
  exit 1
fi

AUTH=(-H "Authorization: token ${GH_TOKEN}")
mkdir -p "$OUT_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "开始盯梢 run ${RUN_ID}（tag ${TAG}），轮询间隔 ${INTERVAL}s"

CC=""
while true; do
  STATUS=$(curl -s -m 30 "${AUTH[@]}" "${API}/actions/runs/${RUN_ID}" \
    | "$PY" -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('status') or '', d.get('conclusion') or '')
except Exception:
    print('', '')
" 2>/dev/null)

  ST=$(echo "$STATUS" | awk '{print $1}')
  CC=$(echo "$STATUS" | awk '{print $2}')

  case "$ST" in
    in_progress|queued|requested|waiting|pending)
      log "状态: ${ST} ... 等待中"
      sleep "$INTERVAL"
      ;;
    completed)
      log "构建结束，结论: ${CC}"
      break
      ;;
    *)
      log "（API 无响应，稍后重试）"
      sleep "$INTERVAL"
      ;;
  esac
done

if [ "$CC" != "success" ]; then
  log "!! 构建未成功（${CC}），失败/异常步骤："
  curl -s -m 30 "${AUTH[@]}" "${API}/actions/runs/${RUN_ID}/jobs" | "$PY" -c "
import json,sys
d=json.load(sys.stdin)
for j in d.get('jobs',[]):
    for s in j.get('steps',[]):
        if s.get('conclusion') in ('failure','timed_out','cancelled'):
            print('   -', s.get('number'), s.get('name'), '->', s.get('conclusion'))
"
  log "拉日志：GH_TOKEN=xxx ./scripts/fetch-build-logs.sh ${RUN_ID} \"Build ARM64 image\""
  exit 1
fi

# --- 构建成功，下载产物 ---
BASE="https://github.com/${OWNER}/${REPO}/releases/download/aionui-arm64-${TAG}"
log "下载 Release 产物到 ${OUT_DIR}"
cd "$OUT_DIR" || exit 1

CODE=$(curl -s -o /dev/null -m 30 -w '%{http_code}' -L -I "${BASE}/aionui-arm64-${TAG}.tar.gz")
if [ "$CODE" = "200" ]; then
  log "单文件归档模式"
  curl -L -m 1800 -o "aionui-arm64-${TAG}.tar.gz" "${BASE}/aionui-arm64-${TAG}.tar.gz"
else
  log "分卷模式，逐个下载 part-*"
  for i in 00 01 02 03 04 05 06 07 08 09; do
    P="aionui-arm64-${TAG}.tar.gz.part-${i}"
    C=$(curl -s -o /dev/null -m 30 -w '%{http_code}' -L -I "${BASE}/${P}")
    [ "$C" = "200" ] || break
    log "  下载 ${P}"
    curl -L -m 1800 -o "${P}" "${BASE}/${P}"
  done
fi

curl -s -L -m 60 -o SHA256SUMS "${BASE}/SHA256SUMS" || true

log "产物清单："
ls -lh
log "完成"
