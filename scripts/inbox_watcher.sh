#!/usr/bin/env bash
# 使用法: bash inbox_watcher.sh <agent_id> <tmux_pane>
# 環境変数:
#   SHOGUN_ROOT                .shogun/ の親ディレクトリ（必須）
#   SHOGUN_BIN_DIR             Shogun インストール先（cli.js 参照用）
#   SHOGUN_ASW_CHECK_INTERVAL  ASW チェック間隔（秒）。デフォルト 30
#   SHOGUN_WAKE_CHECK_INTERVAL inbox 未読チェック間隔（秒）。デフォルト 5
# MCP 移行後: YAML 監視は廃止。idle エージェントへの wake ナッジのみ担当する。
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SHOGUN_BIN_DIR が未設定の場合はスクリプト位置から推定する（scripts/ の親ディレクトリ）
SHOGUN_BIN_DIR="${SHOGUN_BIN_DIR:-$(cd "${_SCRIPT_DIR}/.." && pwd)}"
export SHOGUN_BIN_DIR
export NODE_PATH="${_SCRIPT_DIR}/../node_modules${NODE_PATH:+:$NODE_PATH}"

# フラグ命名は scripts/flag_names.sh に集約（mark_busy.sh / stop_hook.sh /
# inject_role.sh と共通。SHOGUN_ROOT 由来キーで別リポジトリ間の衝突を防ぐ）。
source "${_SCRIPT_DIR}/flag_names.sh"

# macOS: util-linux の flock を keg-only パスから補完（notify_pane の直列化で使う）
if [[ "$(uname -s)" == "Darwin" ]]; then
  export PATH="/opt/homebrew/opt/util-linux/bin:${PATH}"
fi

# ────────────────────────────────────────────────────────────
# 純粋関数（テスト対象）
# ────────────────────────────────────────────────────────────

# inbox ファイルのパスを計算する。
# 引数: <agent_id> <project_id_or_empty> <root>
# 出力: inbox ファイルの絶対パスを stdout に出力
resolve_inbox_path() {
  local agent_id="$1" project_id="$2" root="$3"
  if [[ -n "$project_id" ]]; then
    echo "${root}/.shogun/queue/projects/${project_id}/inbox/${agent_id}.yaml"
  else
    echo "${root}/.shogun/queue/inbox/${agent_id}.yaml"
  fi
}

# reports ディレクトリのパスを計算する。
# 引数: <project_id_or_empty> <root>
# 出力: reports ディレクトリの絶対パスを stdout に出力
resolve_reports_dir() {
  local project_id="$1" root="$2"
  if [[ -n "$project_id" ]]; then
    echo "${root}/.shogun/queue/projects/${project_id}/reports"
  else
    echo "${root}/.shogun/queue/reports"
  fi
}

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

# ペインへ通知を送る。本文と Enter を別々の send-keys で送出する。
# ASW エスカレーション（催促・/clear 送信）で引き続き使用する。
notify_pane() {
  local pane="$1" message="$2"
  local lock_name="${pane//[^A-Za-z0-9_-]/_}"
  local lock_file="/tmp/shogun_send_${lock_name}.lock"
  (
    flock -w 5 200 || exit 0
    tmux send-keys -t "$pane" "$message" 2>/dev/null || true
    sleep "${SHOGUN_WAKE_ENTER_DELAY:-0.3}"
    tmux send-keys -t "$pane" Enter 2>/dev/null || true
  ) 200>"$lock_file" || true
}

# idle 時のみ中身なし単発打鍵でエージェントを起こす。
# 本文は MCP inbox_check で Claude 自身が取得するため送出しない。
wake_pane() {
  local pane="$1"
  is_agent_idle "$AGENT_ID" "${SHOGUN_PROJECT_ID:-}" || return 0
  tmux send-keys -t "$pane" "" 2>/dev/null || true
  sleep 0.1
  tmux send-keys -t "$pane" Enter 2>/dev/null || true
}

# ────────────────────────────────────────────────────────────
# Agent Self-Watch（3段階エスカレーション自動復旧）
# ────────────────────────────────────────────────────────────

# エスカレーション実行前に idle/busy を判定する純粋関数（テスト対象）
# Stop フック（scripts/stop_hook.sh）が立てた idle フラグの有無で判定する。
# idle（フラグあり）= ターン完了済みで安全に起こせる、busy（フラグなし）= 作業中。
# 引数: <agent_id> <project_id_or_empty>
# 戻り値: idle なら 0（つつき可）、busy なら 1（スキップ）
is_agent_idle() {
  local agent="$1" project_id="$2"
  [[ -f "$(shogun_idle_flag "$agent" "$project_id")" ]]
}

# フェーズ1: 催促メッセージ（nudge）
escalate_phase1() {
  local pane="$1"
  notify_pane "$pane" \
    "（システム自動通知）長時間無応答が検知されました。作業を再開してください。"
}

# フェーズ2: 中断（Ctrl-C）
escalate_phase2() {
  local pane="$1"
  tmux send-keys -t "$pane" C-c 2>/dev/null || true
}

# フェーズ3: リセット（/clear）
escalate_phase3() {
  local pane="$1"
  notify_pane "$pane" "/clear"
}

# エスカレーションフェーズを判定する純粋関数（テスト対象）
# 引数: <経過秒> <phase1閾値> <phase2閾値> <phase3閾値>
# 戻り値: 実行すべきフェーズ番号を stdout に出力（0=なし, 1, 2, 3）
get_escalation_phase() {
  local elapsed="$1" p1="$2" p2="$3" p3="$4"
  if [[ "$elapsed" -ge "$p3" ]]; then
    echo 3
  elif [[ "$elapsed" -ge "$p2" ]]; then
    echo 2
  elif [[ "$elapsed" -ge "$p1" ]]; then
    echo 1
  else
    echo 0
  fi
}

# 次に実行すべきエスカレーションフェーズを計算する純粋関数（テスト対象）
# 順序を守り高フェーズへの飛び越しを防ぐ（例: last=0, target=3 → 1 を返す）
# 引数: <target_phase> <last_phase>
# 戻り値: 実行すべき次フェーズ（0=なし）を stdout に出力
get_next_escalation_step() {
  local target_phase="$1" last_phase="$2"
  local next_phase=$(( last_phase + 1 ))
  if [[ "$next_phase" -gt "$target_phase" ]]; then
    echo 0
  else
    echo "$next_phase"
  fi
}

# アクティビティ再開によるフェーズリセット判定純粋関数（テスト対象）
# エスカレーション操作自体も pane_activity を更新するため、
# 最後のエスカレーション後 check_interval*2 より新しい活動のみ本物の復帰とみなす
# 引数: <last_phase> <last_activity> <last_esc_time> <check_interval>
# 戻り値: リセットすべきなら 0、そうでなければ 1
should_reset_escalation() {
  local last_phase="$1" last_activity="$2" last_esc_time="$3" check_interval="$4"
  if [[ "$last_phase" -gt 0 ]] && (( last_activity > last_esc_time + check_interval * 2 )); then
    return 0
  fi
  return 1
}

# エスカレーション監視ループ（SHOGUN_ASW_ENABLED=true のとき main から起動）
watch_escalation() {
  local pane="$1"
  local phase1_sec="${SHOGUN_ASW_PHASE1_SEC:-300}"
  local phase2_sec="${SHOGUN_ASW_PHASE2_SEC:-600}"
  local phase3_sec="${SHOGUN_ASW_PHASE3_SEC:-900}"
  local check_interval="${SHOGUN_ASW_CHECK_INTERVAL:-30}"
  local last_phase=0
  local last_esc_time=0

  while true; do
    sleep "$check_interval"

    # tmux ペインの最終アクティビティ（秒単位エポック）を取得
    local last_activity
    last_activity="$(tmux display-message -t "$pane" -p '#{pane_activity}' 2>/dev/null || echo 0)"
    if [[ "$last_activity" -eq 0 ]]; then continue; fi

    local now elapsed
    now="$(date +%s)"
    elapsed=$(( now - last_activity ))

    local target_phase
    target_phase="$(get_escalation_phase "$elapsed" "$phase1_sec" "$phase2_sec" "$phase3_sec")"

    if [[ "$target_phase" -eq 0 ]]; then
      if should_reset_escalation "$last_phase" "$last_activity" "$last_esc_time" "$check_interval"; then
        last_phase=0
        last_esc_time=0
      fi
      continue
    fi

    # 常に last_phase+1 から順に昇格させ、初回でも高フェーズへ飛び越すのを防ぐ
    local next_phase
    next_phase="$(get_next_escalation_step "$target_phase" "$last_phase")"
    if [[ "$next_phase" -eq 0 ]]; then
      continue
    fi

    # idle 状態でないとき（busy = 作業中）はエスカレーションをスキップする。
    # last_phase/last_esc_time はリセットせず、次のチェックで再判定する
    # （busy 中の作業エージェントを誤って中断しないための安全網）。
    if ! is_agent_idle "$AGENT_ID" "${SHOGUN_PROJECT_ID:-}"; then
      continue
    fi

    case "$next_phase" in
      1) escalate_phase1 "$pane" ;;
      2) escalate_phase2 "$pane" ;;
      3) escalate_phase3 "$pane" ;;
    esac
    last_phase="$next_phase"
    last_esc_time="$now"
  done
}

# ────────────────────────────────────────────────────────────
# 監視ループ（MCP 移行後: wake ナッジ専用）
# ────────────────────────────────────────────────────────────

main() {
  AGENT_ID="${1:?Usage: $0 <agent_id> <tmux_pane>}"
  PANE="${2:?}"
  ROOT="${SHOGUN_ROOT:?SHOGUN_ROOT が未設定です}"

  [[ "$AGENT_ID" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ERROR: 不正な agent_id: ${AGENT_ID}"; exit 1; }

  if [[ -n "${SHOGUN_PROJECT_ID:-}" ]]; then
    [[ "$SHOGUN_PROJECT_ID" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ERROR: 不正な project_id: ${SHOGUN_PROJECT_ID}"; exit 1; }
  fi

  local _asw_pid="" _wake_pid=""
  # shellcheck disable=SC2064
  trap 'kill "${_asw_pid:-}" "${_wake_pid:-}" 2>/dev/null || true' EXIT INT TERM HUP

  if [[ "${SHOGUN_ASW_ENABLED:-false}" == "true" ]]; then
    watch_escalation "$PANE" &
    _asw_pid=$!
  fi

  # inbox 更新は MCP プル型に移行。cli.js で未読件数を定期確認し、あれば wake ナッジを送る。
  while true; do
    sleep "${SHOGUN_WAKE_CHECK_INTERVAL:-5}"
    local unread=0
    unread="$(node "${SHOGUN_BIN_DIR}/packages/mcp-queue/cli.js" \
      inbox_unread_count \
      "--root=${ROOT}" \
      "--role=${AGENT_ID}" \
      ${SHOGUN_PROJECT_ID:+"--project-id=${SHOGUN_PROJECT_ID}"} 2>/dev/null || echo 0)"
    if [[ "$unread" -gt 0 ]]; then
      wake_pane "$PANE"
    fi
  done &
  _wake_pid=$!
  wait
}

# source 時（テスト）は関数定義のみ読み込み、監視ループは起動しない
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
