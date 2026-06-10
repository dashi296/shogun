#!/usr/bin/env bash
# 使用法: bash inbox_write.sh <recipient> "<subject>" "<body>"
# 環境変数: SHOGUN_ROOT（.shogun/の親ディレクトリ）, SHOGUN_ROLE（送信者役職名）
set -euo pipefail

# scripts/ の親 = リポジトリルートを node_modules 解決に使う
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NODE_PATH="${_SCRIPT_DIR}/../node_modules${NODE_PATH:+:$NODE_PATH}"

# macOS: util-linux の flock を keg-only パスから補完
if [[ "$(uname -s)" == "Darwin" ]]; then
  export PATH="/opt/homebrew/opt/util-linux/bin:${PATH}"
fi

RECIPIENT="${1:?Usage: $0 <recipient> <subject> <body>}"
SUBJECT="${2:-}"
BODY="${3:-}"
ROOT="${SHOGUN_ROOT:?SHOGUN_ROOT が未設定です}"

# パストラバーサル防止: 役職名は英数字・アンダースコア・ハイフンのみ許可
[[ "$RECIPIENT" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ERROR: 不正な recipient: ${RECIPIENT}"; exit 1; }

INBOX="${ROOT}/.shogun/queue/inbox/${RECIPIENT}.yaml"
LOCK_FILE="/tmp/shogun_inbox_${RECIPIENT}.lock"
MSG_ID="msg_$(date +%Y%m%d%H%M%S)_$$"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SENDER="${SHOGUN_ROLE:-unknown}"

(
  flock -w 5 200
  # 初期化・書き込みをロック内で実行（競合防止）
  mkdir -p "$(dirname "$INBOX")"
  [[ -f "$INBOX" ]] || echo "messages: []" > "$INBOX"
  # シェルインジェクション防止: 全値を process.argv 経由で渡す
  node -e '
const fs = require("fs");
const yaml = require("js-yaml");
const [inbox, msgId, sender, ts, subject, body] = process.argv.slice(1);
const data = yaml.load(fs.readFileSync(inbox, "utf8")) || {messages: []};
data.messages = data.messages || [];
data.messages.push({id: msgId, from: sender, timestamp: ts, subject, body, status: "unread"});
fs.writeFileSync(inbox, yaml.dump(data, {allowUnicode: true}));
' -- "$INBOX" "$MSG_ID" "$SENDER" "$TIMESTAMP" "$SUBJECT" "$BODY"
) 200>"${LOCK_FILE}"

echo "[inbox_write] → ${RECIPIENT}: ${SUBJECT}"
