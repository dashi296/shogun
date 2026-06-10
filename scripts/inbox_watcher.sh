#!/usr/bin/env bash
# 使用法: bash inbox_watcher.sh <agent_id> <tmux_pane>
# 環境変数: SHOGUN_ROOT
set -euo pipefail

AGENT_ID="${1:?Usage: $0 <agent_id> <tmux_pane>}"
PANE="${2:?}"
ROOT="${SHOGUN_ROOT:?SHOGUN_ROOT が未設定です}"

# パストラバーサル防止: エージェントIDは英数字・アンダースコア・ハイフンのみ許可
[[ "$AGENT_ID" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ERROR: 不正な agent_id: ${AGENT_ID}"; exit 1; }

INBOX="${ROOT}/.shogun/queue/inbox/${AGENT_ID}.yaml"
mkdir -p "$(dirname "$INBOX")"
[[ -f "$INBOX" ]] || echo "messages: []" > "$INBOX"

wake_up() {
  local unread
  # シェルインジェクション防止: INBOXパスを process.argv 経由で渡す
  unread=$(node -e '
const yaml = require("js-yaml");
const inbox = process.argv[1];
const data = yaml.load(require("fs").readFileSync(inbox, "utf8")) || {};
const msgs = (data.messages || []).filter(m => m.status === "unread");
process.stdout.write(String(msgs.length));
' -- "$INBOX" 2>/dev/null || echo "0")

  if [[ "$unread" -gt 0 ]]; then
    tmux send-keys -t "$PANE" \
      ".shogun/queue/inbox/${AGENT_ID}.yaml に ${unread} 件の未読メッセージがあります。確認してください。" \
      Enter 2>/dev/null || true
  fi
}

OS=$(uname -s)
if [[ "$OS" == "Darwin" ]]; then
  command -v fswatch &>/dev/null || { echo "ERROR: brew install fswatch を実行してください"; exit 1; }
  # --latency 0.5 で連続イベントをデバウンス
  fswatch -o --latency 0.5 "$INBOX" | while read -r _; do wake_up; done
else
  command -v inotifywait &>/dev/null || { echo "ERROR: sudo apt install inotify-tools を実行してください"; exit 1; }
  while inotifywait -e close_write "$INBOX" 2>/dev/null; do wake_up; done
fi
