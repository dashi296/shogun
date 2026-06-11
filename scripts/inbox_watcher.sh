#!/usr/bin/env bash
# 使用法: bash inbox_watcher.sh <agent_id> <tmux_pane>
# 環境変数:
#   SHOGUN_ROOT          .shogun/ の親ディレクトリ（必須）
#   SHOGUN_WATCH_REPORTS 1 のとき reports/ も監視する（Karo / Taisho 用の安全網）
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NODE_PATH="${_SCRIPT_DIR}/../node_modules${NODE_PATH:+:$NODE_PATH}"

# ────────────────────────────────────────────────────────────
# 純粋関数（テスト対象）
# ────────────────────────────────────────────────────────────

# 変更された report ファイルで上位エージェントを起こすべきか判定する。
# 引数: <変更ファイルの basename> <自分が消費する報告元の空白区切りリスト(sources)>
# 戻り値: 起こすべきなら 0、無視すべきなら 1
#   - sources に含まれる報告元の <src>_report.yaml のみで起こす（allowlist）
#   - sources に自分を含めないため自己 wake ループは起きない
#   - Taisho の sources は karo のみ。下位エージェントの個別報告では起こさず、
#     Karo の集約報告だけに反応する（階層バイパス・早すぎる集約を防止）
should_wake_on_report() {
  local base="$1" sources="$2" src
  [[ "$base" == *_report.yaml ]] || return 1
  for src in $sources; do
    [[ "$base" == "${src}_report.yaml" ]] && return 0
  done
  return 1
}

# ────────────────────────────────────────────────────────────
# wake-up 送出
# ────────────────────────────────────────────────────────────

# inbox の未読件数を確認し、未読があればペインへ通知する
wake_up_inbox() {
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

# reports/ の更新を検知したときペインへ通知する（inbox_write 漏れに対する安全網）
wake_up_reports() {
  tmux send-keys -t "$PANE" \
    ".shogun/queue/reports/ に下位エージェントの報告が更新されました。集約して上位へ報告してください。" \
    Enter 2>/dev/null || true
}

# ────────────────────────────────────────────────────────────
# 監視ループ
# ────────────────────────────────────────────────────────────

watch_inbox() {
  if [[ "$OS" == "Darwin" ]]; then
    # --latency 0.5 で連続イベントをデバウンス
    fswatch -o --latency 0.5 "$INBOX" | while read -r _; do wake_up_inbox; done
  else
    while inotifywait -e close_write "$INBOX" 2>/dev/null; do wake_up_inbox; done
  fi
}

watch_reports() {
  mkdir -p "$REPORTS_DIR"
  if [[ "$OS" == "Darwin" ]]; then
    # -o を付けず変更パスを取得し、消費する報告元(REPORT_SOURCES)の更新のみで wake する
    fswatch --latency 0.5 "$REPORTS_DIR" | while read -r changed; do
      should_wake_on_report "$(basename "$changed")" "$REPORT_SOURCES" && wake_up_reports
    done
  else
    inotifywait -m -e close_write --format '%f' "$REPORTS_DIR" 2>/dev/null | while read -r base; do
      should_wake_on_report "$base" "$REPORT_SOURCES" && wake_up_reports
    done
  fi
}

main() {
  AGENT_ID="${1:?Usage: $0 <agent_id> <tmux_pane>}"
  PANE="${2:?}"
  ROOT="${SHOGUN_ROOT:?SHOGUN_ROOT が未設定です}"

  # パストラバーサル防止: エージェントIDは英数字・アンダースコア・ハイフンのみ許可
  [[ "$AGENT_ID" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ERROR: 不正な agent_id: ${AGENT_ID}"; exit 1; }

  INBOX="${ROOT}/.shogun/queue/inbox/${AGENT_ID}.yaml"
  REPORTS_DIR="${ROOT}/.shogun/queue/reports"
  # 消費する報告元の allowlist（空白区切り）。bin/shogun が役職ごとに設定する。
  #   karo  -> "gunshi metsuke ashigaru1 ..." / taisho -> "karo"
  REPORT_SOURCES="${SHOGUN_REPORT_SOURCES:-}"
  mkdir -p "$(dirname "$INBOX")"
  [[ -f "$INBOX" ]] || echo "messages: []" > "$INBOX"

  OS=$(uname -s)
  if [[ "$OS" == "Darwin" ]]; then
    command -v fswatch &>/dev/null || { echo "ERROR: brew install fswatch を実行してください"; exit 1; }
  else
    command -v inotifywait &>/dev/null || { echo "ERROR: sudo apt install inotify-tools を実行してください"; exit 1; }
  fi

  # reports/ 監視は報告元 allowlist が指定されたとき（Karo / Taisho）だけ有効化
  if [[ -n "$REPORT_SOURCES" ]]; then
    watch_reports &
  fi
  watch_inbox
}

# source 時（テスト）は関数定義のみ読み込み、監視ループは起動しない
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
