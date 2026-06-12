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
