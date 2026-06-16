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
  # allowed_sources はカンマ区切り role リスト。各要素を検証する
  if [[ -n "$allowed_sources" ]]; then
    local _src
    IFS=',' read -ra _src_arr <<< "$allowed_sources"
    for _src in "${_src_arr[@]}"; do
      [[ "$_src" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ERROR: invalid source in allowed_sources: $_src" >&2; exit 1; }
    done
  fi
  mkdir -p "$(_mcp_dir "$root")"

  # StdioServerTransport はバックグラウンドで /dev/null stdin を渡すと stdin EOF を
  # 検知して即終了するため、サーバプロセスを shogun 側で起動しない。
  # Claude Code が --mcp-config で渡された .json を読み、必要時にサーバを自己管理する。

  # .shogun/mcp/<role>.json を生成（Claude Code が起動時に読み込む）
  # 環境変数経由で値を渡すことで node -e へのコマンドインジェクションを防ぐ
  local cfg_file; cfg_file="$(_cfg_file "$role" "$root")"
  _MCP_SERVER="$MCP_SERVER" _ROLE="$role" _ROOT="$root" \
  _ALLOWED="$allowed_sources" _CFG="$cfg_file" \
  node -e '
const fs = require("fs");
const { _MCP_SERVER: srv, _ROLE: role, _ROOT: root, _ALLOWED: allowed, _CFG: cfg } = process.env;
const args = [srv, "--role=" + role, "--root=" + root];
if (allowed) args.push("--allowed-sources=" + allowed);
const data = { mcpServers: { ["shogun-mcp-queue-" + role]: { command: "node", args } } };
fs.writeFileSync(cfg, JSON.stringify(data, null, 2) + "\n");
'
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
