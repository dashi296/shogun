#!/usr/bin/env bash
# Stop フックスクリプト: ターン完了時に idle フラグを立て、inbox 未読があれば
# 自己 wake-up メッセージを stdout に出力する（Claude Code が次ターンで受信する）。
#
# 環境変数:
#   SHOGUN_ROLE        役職名（ashigaru は番号付き。例: taisho / ashigaru1）
#   SHOGUN_ROOT        .shogun/ の親ディレクトリ（未設定なら inbox 確認のみスキップ）
#   SHOGUN_PROJECT_ID  設定時はプロジェクト別のフラグ名・inbox パスを使う
# 出力:
#   inbox に未読があるときのみ通知メッセージを stdout に出力する。
#   役職が未設定・不正なときはセッションを壊さないよう何も出力せず正常終了する。
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NODE_PATH="${_SCRIPT_DIR}/../node_modules${NODE_PATH:+:$NODE_PATH}"

AGENT="${SHOGUN_ROLE:-}"

# 役職が未設定なら何もしない（フックは全セッションで発火するため安全側に倒す）
[[ -n "$AGENT" ]] || exit 0
# パストラバーサル防止: 役職名は英数字・アンダースコア・ハイフンのみ許可
[[ "$AGENT" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0

# idle フラグの命名: SHOGUN_PROJECT_ID 併用時の名前衝突を回避（既存の project_id 連動パターンに倣う）
if [[ -n "${SHOGUN_PROJECT_ID:-}" ]]; then
  FLAG="/tmp/shogun_idle_${SHOGUN_PROJECT_ID}_${AGENT}"
else
  FLAG="/tmp/shogun_idle_${AGENT}"
fi

# idle 状態へ遷移（busy → idle）
touch "$FLAG"

# inbox 未読確認（未読があればメッセージを stdout に出力 → Claude Code が次ターンで受信）
ROOT="${SHOGUN_ROOT:-}"
[[ -n "$ROOT" ]] || exit 0

if [[ -n "${SHOGUN_PROJECT_ID:-}" ]]; then
  INBOX="${ROOT}/.shogun/queue/projects/${SHOGUN_PROJECT_ID}/inbox/${AGENT}.yaml"
else
  INBOX="${ROOT}/.shogun/queue/inbox/${AGENT}.yaml"
fi

[[ -f "$INBOX" ]] || exit 0

unread=$(node -e '
const yaml = require("js-yaml");
const data = yaml.load(require("fs").readFileSync(process.argv[1], "utf8")) || {};
const msgs = (data.messages || []).filter(m => m.status === "unread");
process.stdout.write(String(msgs.length));
' -- "$INBOX" 2>/dev/null || echo "0")

if [[ "$unread" -gt 0 ]]; then
  echo "${INBOX#${ROOT}/} に ${unread} 件の未読メッセージがあります。確認してください。"
fi
