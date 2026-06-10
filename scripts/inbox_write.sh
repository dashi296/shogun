#!/usr/bin/env bash
# 使用法: bash inbox_write.sh <recipient> "<subject>" "<body>"
# 環境変数: SHOGUN_ROOT（.shogun/の親ディレクトリ）, SHOGUN_ROLE（送信者役職名）
set -euo pipefail

RECIPIENT="${1:?Usage: $0 <recipient> <subject> <body>}"
SUBJECT="${2:-}"
BODY="${3:-}"
ROOT="${SHOGUN_ROOT:?SHOGUN_ROOT が未設定です}"
INBOX="${ROOT}/.shogun/queue/inbox/${RECIPIENT}.yaml"
LOCK_FILE="/tmp/shogun_inbox_${RECIPIENT}.lock"

[[ -f "$INBOX" ]] || echo "messages: []" > "$INBOX"

MSG_ID="msg_$(date +%Y%m%d%H%M%S)_$$"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SENDER="${SHOGUN_ROLE:-unknown}"

(
  flock -w 5 200
  node -e "
const fs = require('fs');
const yaml = require('js-yaml');
const data = yaml.load(fs.readFileSync('${INBOX}', 'utf8')) || {messages: []};
data.messages = data.messages || [];
data.messages.push({
  id: '${MSG_ID}',
  from: '${SENDER}',
  timestamp: '${TIMESTAMP}',
  subject: process.argv[1],
  body: process.argv[2],
  status: 'unread',
});
fs.writeFileSync('${INBOX}', yaml.dump(data, {allowUnicode: true}));
" "${SUBJECT}" "${BODY}"
) 200>"${LOCK_FILE}"

echo "[inbox_write] → ${RECIPIENT}: ${SUBJECT}"
