#!/usr/bin/env bash
# UserPromptSubmit フックスクリプト: ターン開始時に idle フラグを削除して busy 状態へ遷移する。
#
# Stop フック（scripts/stop_hook.sh）がターン完了時に立てた idle フラグを、
# 次のターンが始まった瞬間に消すことで busy/idle 判定（is_agent_idle）を正確に保つ。
# これが無いと最初の Stop 以降フラグが残り続け、作業中（busy）でも idle と
# 誤判定され、inbox_watcher の wake-up や ASW が描画中のペインへ送出してしまう。
#
# 環境変数:
#   SHOGUN_ROLE        役職名（ashigaru は番号付き。例: taisho / ashigaru1）
#   SHOGUN_PROJECT_ID  設定時はプロジェクト別のフラグ名を使う
# 出力:
#   何も出力しない（セッションを壊さないよう、不正値でも正常終了する）。
set -euo pipefail

# フラグ命名は scripts/flag_names.sh に集約（stop_hook.sh / inject_role.sh /
# inbox_watcher.sh と共通。SHOGUN_ROOT 由来キーで別リポジトリ間の衝突を防ぐ）。
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/flag_names.sh"

AGENT="${SHOGUN_ROLE:-}"

# 役職が未設定なら何もしない（フックは全セッションで発火するため安全側に倒す）
[[ -n "$AGENT" ]] || exit 0
# パストラバーサル防止: 役職名は英数字・アンダースコア・ハイフンのみ許可
[[ "$AGENT" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0

# project_id 設定時は project 別フラグだけを消す（stop_hook.sh もその名前でしか作らないため、
# 無印フラグには触れない）。不正な project_id なら何もしない（stop_hook.sh と揃える）。
if [[ -n "${SHOGUN_PROJECT_ID:-}" ]]; then
  [[ "${SHOGUN_PROJECT_ID}" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0
  rm -f "$(shogun_idle_flag "$AGENT" "$SHOGUN_PROJECT_ID")"
else
  rm -f "$(shogun_idle_flag "$AGENT" "")"
fi
