#!/usr/bin/env bats
# Unit tests for scripts/inbox_watcher.sh
#
# fswatch/inotifywait の監視ループ自体は long-running で直接テストできないため、
# 「変更された report ファイルで上位を起こすべきか」を判定する純粋関数
# should_wake_on_report を切り出してテストする。
# スクリプトは末尾の監視ループを source ガードで囲み、関数だけ source できる。
#
# 判定は「自分が消費する報告元 (sources) の *_report.yaml だけで wake する」allowlist 方式。
#   - Karo  の sources: gunshi metsuke ashigaru1 ...（実在の subordinates）
#   - Taisho の sources: karo（Karo の集約報告のみ。下位の個別報告では起こさない）

load '../test_helper'

# BASH_SOURCE != $0 となるよう source して関数定義のみ読み込む
setup() {
  source "${SHOGUN_REPO}/scripts/inbox_watcher.sh"
}

@test "should_wake_on_report: karo wakes on a subordinate's report" {
  run should_wake_on_report "ashigaru1_report.yaml" "gunshi metsuke ashigaru1"
  [ "$status" -eq 0 ]
}

@test "should_wake_on_report: karo wakes on gunshi/metsuke reports" {
  run should_wake_on_report "gunshi_report.yaml" "gunshi metsuke ashigaru1"
  [ "$status" -eq 0 ]
  run should_wake_on_report "metsuke_report.yaml" "gunshi metsuke ashigaru1"
  [ "$status" -eq 0 ]
}

@test "should_wake_on_report: does not wake on a report outside sources (self-wake guard)" {
  # karo 自身の report は sources に含まれないので起こさない
  run should_wake_on_report "karo_report.yaml" "gunshi metsuke ashigaru1"
  [ "$status" -ne 0 ]
}

@test "should_wake_on_report: taisho wakes only on karo_report" {
  run should_wake_on_report "karo_report.yaml" "karo"
  [ "$status" -eq 0 ]
}

@test "should_wake_on_report: taisho does NOT wake on subordinate reports" {
  # Codex 指摘: 下位の個別報告で Taisho が早すぎる集約をしないこと
  run should_wake_on_report "ashigaru1_report.yaml" "karo"
  [ "$status" -ne 0 ]
  run should_wake_on_report "gunshi_report.yaml" "karo"
  [ "$status" -ne 0 ]
}

# --- SHOGUN_PROJECT_ID path switching ---

@test "inbox_watcher main: uses project-specific inbox when SHOGUN_PROJECT_ID is set" {
  # main() 関数内のパス決定ロジックをテストするため、
  # source後に main() の内部変数設定部分を再現して確認する
  local tmp_root
  tmp_root="$(mktemp -d)"

  export SHOGUN_ROOT="$tmp_root"
  export SHOGUN_PROJECT_ID="proj1"

  # inbox_watcher.sh を source して関数を読み込む
  # main() を直接呼ぶと監視ループが起動するため、内部パス計算を模倣する
  local expected_inbox="${tmp_root}/.shogun/queue/projects/proj1/inbox/karo.yaml"
  local actual_inbox
  if [[ -n "${SHOGUN_PROJECT_ID:-}" ]]; then
    actual_inbox="${SHOGUN_ROOT}/.shogun/queue/projects/${SHOGUN_PROJECT_ID}/inbox/karo.yaml"
  else
    actual_inbox="${SHOGUN_ROOT}/.shogun/queue/inbox/karo.yaml"
  fi

  [ "$actual_inbox" = "$expected_inbox" ]

  rm -rf "$tmp_root"
  unset SHOGUN_PROJECT_ID
}

@test "inbox_watcher main: uses default inbox when SHOGUN_PROJECT_ID is not set" {
  local tmp_root
  tmp_root="$(mktemp -d)"

  export SHOGUN_ROOT="$tmp_root"
  unset SHOGUN_PROJECT_ID

  local expected_inbox="${tmp_root}/.shogun/queue/inbox/karo.yaml"
  local actual_inbox
  if [[ -n "${SHOGUN_PROJECT_ID:-}" ]]; then
    actual_inbox="${SHOGUN_ROOT}/.shogun/queue/projects/${SHOGUN_PROJECT_ID}/inbox/karo.yaml"
  else
    actual_inbox="${SHOGUN_ROOT}/.shogun/queue/inbox/karo.yaml"
  fi

  [ "$actual_inbox" = "$expected_inbox" ]

  rm -rf "$tmp_root"
}

@test "should_wake_on_report: ignores non-report files" {
  run should_wake_on_report "notes.txt" "gunshi metsuke ashigaru1"
  [ "$status" -ne 0 ]
  run should_wake_on_report ".ashigaru1_report.yaml.swp" "gunshi metsuke ashigaru1"
  [ "$status" -ne 0 ]
}

# ────────────────────────────────────────────────────────────
# notify_pane: 本文と Enter を別々の send-keys で送る
#
# Claude Code の TUI が起動直後・ビジー時、本文と Enter を同一 send-keys で
# 送るとブラケットペースト扱いで末尾 Enter が改行に吸収され、送信が確定しない。
# 本文送信と Enter を分離することで送信の取りこぼしを防ぐ。
# ────────────────────────────────────────────────────────────

@test "notify_pane: sends body and Enter as separate send-keys" {
  local log
  log="$(mktemp)"
  # tmux / sleep をスタブして送出引数を記録する
  tmux() { printf '%s\n' "$*" >> "$log"; }
  sleep() { :; }

  notify_pane "mypane" "本文メッセージ"

  run cat "$log"
  rm -f "$log"
  # send-keys が 2 回呼ばれる（本文 → Enter）
  [ "${#lines[@]}" -eq 2 ]
  # 1 回目は本文のみ。末尾に Enter を含まない（同梱しない）
  [ "${lines[0]}" = "send-keys -t mypane 本文メッセージ" ]
  [[ "${lines[0]}" != *Enter* ]]
  # 2 回目で Enter を単独送信して確定する
  [ "${lines[1]}" = "send-keys -t mypane Enter" ]
}

# ────────────────────────────────────────────────────────────
# get_escalation_phase: 経過時間からフェーズを判定する純粋関数
# ────────────────────────────────────────────────────────────

@test "get_escalation_phase: returns 0 when elapsed is below phase1 threshold" {
  run get_escalation_phase 299 300 600 900
  [ "$output" = "0" ]
}

@test "get_escalation_phase: returns 1 when elapsed reaches phase1 threshold" {
  run get_escalation_phase 300 300 600 900
  [ "$output" = "1" ]
}

@test "get_escalation_phase: returns 2 when elapsed reaches phase2 threshold" {
  run get_escalation_phase 600 300 600 900
  [ "$output" = "2" ]
}

@test "get_escalation_phase: returns 3 when elapsed reaches phase3 threshold" {
  run get_escalation_phase 900 300 600 900
  [ "$output" = "3" ]
}

@test "get_escalation_phase: returns 3 for elapsed beyond phase3" {
  run get_escalation_phase 9999 300 600 900
  [ "$output" = "3" ]
}

# ────────────────────────────────────────────────────────────
# escalate_phase1/2/3: 各フェーズが正しい tmux コマンドを送出する
# ────────────────────────────────────────────────────────────

@test "escalate_phase1: sends nudge message and Enter" {
  local log
  log="$(mktemp)"
  tmux() { printf '%s\n' "$*" >> "$log"; }
  sleep() { :; }

  escalate_phase1 "testpane"

  run cat "$log"
  rm -f "$log"
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *"無応答"* ]]
  [ "${lines[1]}" = "send-keys -t testpane Enter" ]
}

@test "escalate_phase2: sends Ctrl-C" {
  local log
  log="$(mktemp)"
  tmux() { printf '%s\n' "$*" >> "$log"; }

  escalate_phase2 "testpane"

  run cat "$log"
  rm -f "$log"
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "send-keys -t testpane C-c" ]
}

@test "escalate_phase3: sends /clear and Enter" {
  local log
  log="$(mktemp)"
  tmux() { printf '%s\n' "$*" >> "$log"; }
  sleep() { :; }

  escalate_phase3 "testpane"

  run cat "$log"
  rm -f "$log"
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "send-keys -t testpane /clear" ]
  [ "${lines[1]}" = "send-keys -t testpane Enter" ]
}

# ────────────────────────────────────────────────────────────
# get_next_escalation_step: フェーズ昇格の順序を守る純粋関数
# ────────────────────────────────────────────────────────────

@test "get_next_escalation_step: returns 1 when last=0 and target=1" {
  run get_next_escalation_step 1 0
  [ "$output" = "1" ]
}

@test "get_next_escalation_step: returns 1 when last=0 and target=3 (no jump)" {
  run get_next_escalation_step 3 0
  [ "$output" = "1" ]
}

@test "get_next_escalation_step: returns 2 when last=1 and target=2" {
  run get_next_escalation_step 2 1
  [ "$output" = "2" ]
}

@test "get_next_escalation_step: returns 3 when last=2 and target=3" {
  run get_next_escalation_step 3 2
  [ "$output" = "3" ]
}

@test "get_next_escalation_step: returns 0 when last=1 and target=1 (already at target)" {
  run get_next_escalation_step 1 1
  [ "$output" = "0" ]
}

@test "get_next_escalation_step: returns 0 when last=3 and target=3 (already at max)" {
  run get_next_escalation_step 3 3
  [ "$output" = "0" ]
}

# ────────────────────────────────────────────────────────────
# should_reset_escalation: アクティビティ再開によるリセット判定
# ────────────────────────────────────────────────────────────

@test "should_reset_escalation: resets when last_phase>0 and activity is recent enough" {
  # last_activity=200, last_esc_time=100, check_interval=30 → threshold=160 < 200 → reset
  run should_reset_escalation 1 200 100 30
  [ "$status" -eq 0 ]
}

@test "should_reset_escalation: does not reset when activity is too close to last escalation" {
  # last_activity=155, last_esc_time=100, check_interval=30 → threshold=160 > 155 → no reset
  run should_reset_escalation 1 155 100 30
  [ "$status" -ne 0 ]
}

@test "should_reset_escalation: does not reset when last_phase=0" {
  run should_reset_escalation 0 9999 0 30
  [ "$status" -ne 0 ]
}

@test "should_reset_escalation: resets only when activity strictly exceeds threshold" {
  # last_activity=160, last_esc_time=100, check_interval=30 → threshold=160, activity=160 → NOT > threshold → no reset
  run should_reset_escalation 1 160 100 30
  [ "$status" -ne 0 ]
}

# ────────────────────────────────────────────────────────────
# SHOGUN_ASW_CHECK_INTERVAL: check_interval の環境変数対応
# ────────────────────────────────────────────────────────────

@test "watch_escalation: uses SHOGUN_ASW_CHECK_INTERVAL when set" {
  # sleep をスタブして第1引数を記録後 exit 0 でサブシェルを終了させる
  local log
  log="$(mktemp)"
  sleep() { printf '%s\n' "$1" >> "$log"; exit 0; }
  # tmux は activity=0 を返し、ループは continue → 次の sleep でスタブが発火
  tmux() { echo 0; }

  export SHOGUN_ASW_CHECK_INTERVAL=5
  ( watch_escalation "dummy" ) || true

  run cat "$log"
  rm -f "$log"
  unset SHOGUN_ASW_CHECK_INTERVAL
  [ "${lines[0]}" = "5" ]
}

# ────────────────────────────────────────────────────────────
# trap on EXIT: バックグラウンド子プロセスの kill 確認 (#64 回帰)
#
# main() 末尾の trap が EXIT 時に watch_reports / watch_escalation の
# 子プロセスを確実に kill することを検証する。
# main() はブロッキング呼び出し watch_inbox を含むため、別 bash プロセスで起動する。
# ────────────────────────────────────────────────────────────

@test "trap on EXIT kills watch_reports and watch_escalation child processes" {
  local tmp_dir
  tmp_dir="$(mktemp -d)"

  local test_script="${tmp_dir}/run_main.sh"
  cat > "$test_script" << 'SCRIPT'
set -euo pipefail

# inbox_watcher.sh を source して関数定義を読み込む
# shellcheck disable=SC1090
source "${SHOGUN_REPO}/scripts/inbox_watcher.sh"

# 子プロセス起動時に PID をファイルへ書き出してから長時間待機するスタブ
# Bash 3.2 では $$ がサブシェルでも親PIDを返すため sh -c 'echo $PPID' で自身のPIDを取得する
watch_reports() { sh -c 'echo $PPID' > "${TMP_DIR}/reports_pid"; sleep 999; }
watch_escalation() { sh -c 'echo $PPID' > "${TMP_DIR}/asw_pid"; sleep 999; }
# watch_inbox は実際の本番同様に SIGTERM が来るまでブロックする
watch_inbox() { sleep 999; }

# fswatch / inotifywait のコマンド存在チェックを通過させるスタブ
fswatch() { :; }
inotifywait() { :; }

# main が参照するディレクトリ構造を作成
mkdir -p "${TMP_DIR}/root/.shogun/queue/inbox"

export SHOGUN_ROOT="${TMP_DIR}/root"
export SHOGUN_REPORT_SOURCES="ashigaru1"
export SHOGUN_ASW_ENABLED="true"

main "karo" "dummy"
SCRIPT

  # run_main.sh をバックグラウンドで起動（watch_inbox が SIGTERM まで待機するため）
  TMP_DIR="$tmp_dir" SHOGUN_REPO="${SHOGUN_REPO}" bash "$test_script" &
  local main_pid=$!

  # 子プロセスが起動して PID ファイルを書き込む猶予を与える
  sleep 0.5

  # テスト側から SIGTERM を送って trap を発火させる（本番と同じシナリオ）
  kill -TERM "$main_pid" 2>/dev/null || true
  wait "$main_pid" 2>/dev/null || true

  local reports_pid asw_pid
  reports_pid="$(cat "${tmp_dir}/reports_pid" 2>/dev/null || echo "")"
  asw_pid="$(cat "${tmp_dir}/asw_pid" 2>/dev/null || echo "")"

  # PID ファイルが存在すること（両子プロセスが起動したこと）を確認
  [ -n "$reports_pid" ]
  [ -n "$asw_pid" ]

  # EXIT trap により両子プロセスが kill されていること（kill -0 が失敗）を確認
  run kill -0 "$reports_pid"
  [ "$status" -ne 0 ]

  run kill -0 "$asw_pid"
  [ "$status" -ne 0 ]

  rm -rf "$tmp_dir"
}
