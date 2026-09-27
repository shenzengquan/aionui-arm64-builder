#!/usr/bin/env bash
# =============================================================================
# 在 Windows（Git Bash）上初始化仓库并推送到 GitHub
# =============================================================================
# 用法：
#   ./push-to-github.sh <github用户名> [仓库名] [PAT]
#
# 例：
#   ./push-to-github.sh zhangsan aionui-arm64-builder ghp_xxxxxxxxxxxx
#
# 说明：
#   - 仓库需要先在 GitHub 网页上创建（Public），本脚本只负责 push
#   - PAT 需要 repo + workflow 两个 scope
#   - PAT 通过 URL 内嵌传递，不写进 git config
# =============================================================================

set -euo pipefail

USER="${1:-}"
REPO="${2:-aionui-arm64-builder}"
TOKEN="${3:-}"

if [ -z "$USER" ]; then
  echo "用法: $0 <github用户名> [仓库名] [PAT]"
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$SCRIPT_DIR"

echo ">> 工作目录: $SCRIPT_DIR"

# --- 确保 .gitattributes 已生效，避免 CRLF 污染脚本 ---
if [ ! -f .gitattributes ]; then
  echo "!! 缺少 .gitattributes，可能导致 shell 脚本被 CRLF 污染"
  exit 1
fi

# --- 初始化仓库 ---
if [ ! -d .git ]; then
  git init
  git branch -M main
fi

git add -A
git commit -m "build: AionUi ARM64 image workflow" || echo ">> 没有新改动需要提交"

# --- 配置 remote ---
if [ -n "$TOKEN" ]; then
  REMOTE_URL="https://${USER}:${TOKEN}@github.com/${USER}/${REPO}.git"
else
  REMOTE_URL="https://github.com/${USER}/${REPO}.git"
  echo ">> 未提供 PAT，推送时可能会要求输入凭据"
fi

if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE_URL"
else
  git remote add origin "$REMOTE_URL"
fi

# --- 推送 ---
echo ">> 推送到 https://github.com/${USER}/${REPO}.git"
git push -u origin main

echo ""
echo "=========================== 完成 ==========================="
echo "1) 确认仓库是 Public（免费 ARM64 runner 的前提）"
echo "2) 打开 Actions 页面："
echo "     https://github.com/${USER}/${REPO}/actions"
echo "3) 选 build-aionui-arm64 -> Run workflow"
echo "==========================================================="
