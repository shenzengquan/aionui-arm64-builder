#!/usr/bin/env bash
# =============================================================================
# 拉取并打印 GitHub Actions run 的完整日志
# =============================================================================
# 为什么需要单独写这个：
#   GitHub 的 logs API 要求 token 具备 repo admin 权限，
#   connector / 默认 GCM 凭据都不够，必须显式传一个有权限的 PAT。
#
# 用法：
#   GH_TOKEN=ghp_xxx ./fetch-build-logs.sh [run_id] [步骤名过滤]
#   GH_TOKEN=ghp_xxx ./fetch-build-logs.sh 36307008891 "Build ARM64 image"
#
# 不带参数默认拉最新一次 run。
# =============================================================================

set -uo pipefail

OWNER="shenzengquan"
REPO="aionui-arm64-builder"
RUN_ID="${1:-}"
FILTER="${2:-}"

if [ -z "${GH_TOKEN:-}" ]; then
  # 兼容常见的 GITHUB_TOKEN 变量名
  GH_TOKEN="${GITHUB_TOKEN:-}"
fi

if [ -z "$GH_TOKEN" ]; then
  cat <<'MSG'
!! 需要 GH_TOKEN 环境变量（具备 repo admin 权限的 PAT）

用法：
  GH_TOKEN=ghp_xxxx ./fetch-build-logs.sh <run_id> ["步骤名过滤"]

说明：
  GitHub 的 workflow run logs API 要求 admin 权限，
  普通 connector 凭据会返回 403 "Must have admin rights to Repository"。
  在 https://github.com/settings/tokens 生成 classic PAT，
  scope 勾选 repo + workflow 即可。
MSG
  exit 1
fi

API="https://api.github.com/repos/${OWNER}/${REPO}"
AUTH=(-H "Authorization: token ${GH_TOKEN}" -H "Accept: application/vnd.github+json")

# --- 没给 run_id，就取最新一次 ---
if [ -z "$RUN_ID" ]; then
  echo ">> 未指定 run_id，获取最新一次 run"
  RUN_ID=$(curl -s "${AUTH[@]}" "${API}/actions/runs?per_page=1" \
    | grep -o '"id": *[0-9]*' | head -n1 | grep -o '[0-9]*')
  echo ">> 最新 run: ${RUN_ID}"
fi

echo ">> run 页面: https://github.com/${OWNER}/${REPO}/actions/runs/${RUN_ID}"

# --- 状态速览 ---
echo ""
echo "=== run 状态 ==="
curl -s "${AUTH[@]}" "${API}/actions/runs/${RUN_ID}" \
  | grep -E '"(status|conclusion|run_started_at|updated_at)"' | head -n 6

# --- 步骤进度 ---
echo ""
echo "=== 步骤进度 ==="
curl -s "${AUTH[@]}" "${API}/actions/runs/${RUN_ID}/jobs" \
  | grep -E '"(name|status|conclusion)"' | head -n 50

# --- 日志正文 ---
echo ""
echo "=== 日志正文 ==="
TMPLOG=$(mktemp -d)
trap 'rm -rf "$TMPLOG"' EXIT

HTTP=$(curl -s -L "${AUTH[@]}" -o "$TMPLOG/logs.zip" \
  -w '%{http_code}' "${API}/actions/runs/${RUN_ID}/logs")

if [ "$HTTP" != "200" ]; then
  echo "!! 日志下载失败，HTTP ${HTTP}"
  echo "   响应内容："
  head -c 500 "$TMPLOG/logs.zip"
  echo ""
  echo ""
  echo "   常见原因：token 缺少 repo admin 权限，或 run 还没产生日志。"
  exit 1
fi

echo ">> 日志已下载，解压中"
cd "$TMPLOG" && unzip -q logs.zip 2>/dev/null || {
  # 没有 unzip 时用 python 兜底
  "C:/Users/申增权/.workbuddy/binaries/python/versions/3.13.12/python.exe" \
    -c "import zipfile;zipfile.ZipFile('logs.zip').extractall('.')"
}

if [ -n "$FILTER" ]; then
  echo ">> 按关键字过滤: ${FILTER}"
  echo ""
  # 找出匹配的文件，打印其内容
  grep -rl "$FILTER" . 2>/dev/null | while read -r f; do
    echo "########## ${f} ##########"
    cat "$f"
    echo ""
  done
else
  # 打印所有日志（按路径排序，大致对应执行顺序）
  find . -type f -name '*.txt' | sort | while read -r f; do
    echo "########## ${f} ##########"
    cat "$f"
    echo ""
  done
fi
