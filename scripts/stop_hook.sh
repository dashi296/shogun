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

# フラグ命名は scripts/flag_names.sh に集約（mark_busy.sh / inject_role.sh /
# inbox_watcher.sh と共通。SHOGUN_ROOT 由来キーで別リポジトリ間の衝突を防ぐ）。
source "${_SCRIPT_DIR}/flag_names.sh"

# stdin から Stop フック JSON を読み取り stop_hook_active フィールドを確認する。
# stop_hook_active=true はフックが既に block 中の再帰呼び出しを示すため、
# decision:block は出力しないが、idle 遷移・reports 安全網は通常通り実行する。
HOOK_INPUT=""
if [[ ! -t 0 ]]; then
  HOOK_INPUT="$(cat)"
fi
stop_hook_active="false"
if [[ -n "$HOOK_INPUT" ]]; then
  stop_hook_active=$(node -e '
    try {
      const d = JSON.parse(process.argv[1]);
      process.stdout.write(d.stop_hook_active === true ? "true" : "false");
    } catch(e) { process.stdout.write("false"); }
  ' -- "$HOOK_INPUT" 2>/dev/null || echo "false")
fi

AGENT="${SHOGUN_ROLE:-}"

# 役職が未設定なら何もしない（フックは全セッションで発火するため安全側に倒す）
[[ -n "$AGENT" ]] || exit 0
# パストラバーサル防止: 役職名は英数字・アンダースコア・ハイフンのみ許可
[[ "$AGENT" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0

# SHOGUN_PROJECT_ID もフラグ名・inbox パスに展開するため同様に検証する
# （inbox_write.sh / inbox_watcher.sh / inject_role.sh と同じ規約）。
# フックはセッションを壊さないよう、不正値なら何もせず正常終了する。
if [[ -n "${SHOGUN_PROJECT_ID:-}" ]]; then
  [[ "${SHOGUN_PROJECT_ID}" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0
fi

# idle フラグの命名は flag_names.sh に集約（SHOGUN_PROJECT_ID / SHOGUN_ROOT で名前空間を分離）。
FLAG="$(shogun_idle_flag "$AGENT" "${SHOGUN_PROJECT_ID:-}")"

# idle 状態へ遷移（busy → idle）
touch "$FLAG"

# reports 安全網: inbox_watcher が busy 中にスキップした report 通知を idle 復帰時に再提示する。
# inbox と違い reports には Stop 以外の救済経路がなく、busy 中に握りつぶすと次の更新が
# 来ない限り永久に気づけないため、ここで pending マーカーを消費して再通知する。
# マーカー名は inbox_watcher.sh の reports_pending_flag と一致させること（flag_names.sh に集約）。
REPORTS_PENDING="$(shogun_reports_pending_flag "$AGENT" "${SHOGUN_PROJECT_ID:-}")"
if [[ -f "$REPORTS_PENDING" ]]; then
  rm -f "$REPORTS_PENDING"
  echo ".shogun/queue/reports/ に下位エージェントの報告が更新されています。集約して上位へ報告してください。"
fi

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

if [[ "$unread" -gt 0 ]] && [[ "$stop_hook_active" != "true" ]]; then
  printf '{"decision":"block","reason":"未読メッセージを処理してから終了せよ"}\n'
fi
