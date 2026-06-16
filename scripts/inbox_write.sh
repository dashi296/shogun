#!/usr/bin/env bash
# inbox_write.sh — MCP 移行後の互換シム
#
# 旧 YAML 版と同じ呼び出し形式を維持しつつ、実際の送信は cli.js(SQLite) に委譲する。
# エージェントの instructions が「inbox_write.sh <to> <subject> [<body>]」形式で
# 記述されている既存プロジェクトとの後方互換性のために残している。
# 新規プロジェクトでは MCP ツール inbox_send を直接使用すること。
#
# Usage: bash $SHOGUN_BIN_DIR/scripts/inbox_write.sh <to_role> <subject> [<body>]
# 環境変数:
#   SHOGUN_ROOT        .shogun/ の親ディレクトリ
#   SHOGUN_ROLE        送信元の役職名（from_role に使用）
#   SHOGUN_PROJECT_ID  プロジェクト ID（省略可）
#   SHOGUN_BIN_DIR     Shogun インストール先（cli.js 参照用）
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOGUN_BIN_DIR="${SHOGUN_BIN_DIR:-$(cd "${_SCRIPT_DIR}/.." && pwd)}"
export NODE_PATH="${_SCRIPT_DIR}/../node_modules${NODE_PATH:+:$NODE_PATH}"

to_role="${1:?Usage: inbox_write.sh <to_role> <subject> [<body>]}"
subject="${2:?}"
body="${3:-}"
root="${SHOGUN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"
from_role="${SHOGUN_ROLE:-unknown}"

[[ "$to_role"   =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ERROR: invalid to_role: ${to_role}" >&2; exit 1; }
[[ "$from_role" =~ ^[A-Za-z0-9_-]+$ ]] || from_role="unknown"

args=(
  "${SHOGUN_BIN_DIR}/packages/mcp-queue/cli.js"
  inbox_send
  "--root=${root}"
  "--from=${from_role}"
  "--to=${to_role}"
  "--subject=${subject}"
)
[[ -n "$body"                   ]] && args+=("--body=${body}")
[[ -n "${SHOGUN_PROJECT_ID:-}" ]] && args+=("--project-id=${SHOGUN_PROJECT_ID}")

node "${args[@]}"
