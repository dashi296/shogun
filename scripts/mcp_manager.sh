#!/usr/bin/env bash
# MCP サーバの起動・停止・PID 管理
# Usage:
#   bash mcp_manager.sh start <role> <root> <allowed_sources_csv>
#   bash mcp_manager.sh stop  <role> <root>
#   bash mcp_manager.sh stop_all <root>
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOGUN_BIN_DIR="$(cd "${_SCRIPT_DIR}/.." && pwd)"
MCP_SERVER="${SHOGUN_BIN_DIR}/packages/mcp-queue/src/server.js"

cmd="${1:?Usage: mcp_manager.sh <start|stop|stop_all> ...}"
shift

_mcp_dir() { echo "${1}/.shogun/mcp"; }
_pid_file() { echo "$(_mcp_dir "$2")/${1}.pid"; }
_cfg_file() { echo "$(_mcp_dir "$2")/${1}.json"; }

mcp_start() {
  local role="$1" root="$2" allowed_sources="${3:-}"
  [[ "$role" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ERROR: invalid role: $role" >&2; exit 1; }
  mkdir -p "$(_mcp_dir "$root")"

  # 既存プロセスが残っていれば停止
  mcp_stop "$role" "$root" 2>/dev/null || true

  # サーバ起動
  node "$MCP_SERVER" \
    "--role=${role}" \
    "--root=${root}" \
    ${allowed_sources:+"--allowed-sources=${allowed_sources}"} \
    </dev/null >>"${root}/.shogun/mcp/${role}.log" 2>&1 &
  local pid=$!
  echo "$pid" > "$(_pid_file "$role" "$root")"

  # .shogun/mcp/<role>.json を生成（役職専用サーバのみを列挙）
  local cfg_file; cfg_file="$(_cfg_file "$role" "$root")"
  node -e "
const fs = require('fs');
const args = ['${MCP_SERVER}', '--role=${role}', '--root=${root}'];
if ('${allowed_sources}') args.push('--allowed-sources=${allowed_sources}');
const cfg = { mcpServers: { 'shogun-mcp-queue-${role}': { command: 'node', args } } };
fs.writeFileSync('${cfg_file}', JSON.stringify(cfg, null, 2) + '\n');
"
}

mcp_stop() {
  local role="$1" root="$2"
  local pid_file; pid_file="$(_pid_file "$role" "$root")"
  if [[ -f "$pid_file" ]]; then
    local pid; pid="$(cat "$pid_file")"
    kill "$pid" 2>/dev/null || true
    rm -f "$pid_file"
  fi
}

mcp_stop_all() {
  local root="$1"
  local mcp_dir; mcp_dir="$(_mcp_dir "$root")"
  if [[ -d "$mcp_dir" ]]; then
    for pid_file in "${mcp_dir}"/*.pid; do
      [[ -f "$pid_file" ]] || continue
      local pid; pid="$(cat "$pid_file")"
      kill "$pid" 2>/dev/null || true
      rm -f "$pid_file"
    done
  fi
}

case "$cmd" in
  start)    mcp_start "$@" ;;
  stop)     mcp_stop  "$@" ;;
  stop_all) mcp_stop_all "$@" ;;
  *) echo "ERROR: unknown command: $cmd" >&2; exit 1 ;;
esac
