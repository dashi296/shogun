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
  local tmp_root
  tmp_root="$(mktemp -d)"

  local expected_inbox="${tmp_root}/.shogun/queue/projects/proj1/inbox/karo.yaml"
  run resolve_inbox_path "karo" "proj1" "$tmp_root"
  [ "$output" = "$expected_inbox" ]

  rm -rf "$tmp_root"
}

@test "inbox_watcher main: uses default inbox when SHOGUN_PROJECT_ID is not set" {
  local tmp_root
  tmp_root="$(mktemp -d)"

  local expected_inbox="${tmp_root}/.shogun/queue/inbox/karo.yaml"
  run resolve_inbox_path "karo" "" "$tmp_root"
  [ "$output" = "$expected_inbox" ]

  rm -rf "$tmp_root"
}

@test "resolve_reports_dir: returns project-specific path when project_id is set" {
  local tmp_root
  tmp_root="$(mktemp -d)"

  local expected="${tmp_root}/.shogun/queue/projects/proj1/reports"
  run resolve_reports_dir "proj1" "$tmp_root"
  [ "$output" = "$expected" ]

  rm -rf "$tmp_root"
}

@test "resolve_reports_dir: returns default path when project_id is empty" {
  local tmp_root
  tmp_root="$(mktemp -d)"

  local expected="${tmp_root}/.shogun/queue/reports"
  run resolve_reports_dir "" "$tmp_root"
  [ "$output" = "$expected" ]

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

# notify_pane はペイン単位の flock を保持して送出を直列化する。
# 並行する watcher（inbox / reports / ASW）が本文と Enter の隙間に割り込み、
# send-keys が混線して行が多重化するのを防ぐ。
# クリティカルセクション内（本文送信時）に外部から同じロックを non-blocking で
# 取得しようとすると失敗する（=ロック保持中）ことで直列化を検証する。
@test "notify_pane: holds a per-pane flock while sending" {
  local lockfile="/tmp/shogun_send_testpane.lock"
  local result; result="$(mktemp)"
  rm -f "$lockfile"

  sleep() { :; }
  tmux() {
    if [[ "$*" == *"本文"* ]]; then
      # クリティカルセクション内：別 fd で同じロックを non-blocking 取得
      if flock -n 8; then echo "acquired" > "$result"; else echo "blocked" > "$result"; fi 8>"$lockfile"
    fi
  }

  notify_pane "testpane" "本文メッセージ"

  run cat "$result"
  rm -f "$result" "$lockfile"
  [ "$output" = "blocked" ]
}

# ────────────────────────────────────────────────────────────
# wake_pane: idle エージェントへの非空 wake-up プロンプト送出
#
# Claude Code TUI は空文字列+Enter を新ターンとして処理しないため、
# wake_pane は notify_pane 経由で inbox_check を促す非空プロンプトを送出する。
# 空送信のまま放置すると shogun task / inbox_send 後にエージェントが起きない。
# ────────────────────────────────────────────────────────────

@test "wake_pane: sends non-empty prompt to idle agent (empty Enter does not start a turn)" {
  local log; log="$(mktemp)"
  tmux() { printf '%s\n' "$*" >> "$log"; }
  sleep() { :; }

  AGENT_ID="karo"
  SHOGUN_PROJECT_ID=""
  SHOGUN_ROOT="/tmp/test_wakepane_$$"
  local flag; flag="$(shogun_idle_flag "$AGENT_ID" "")"
  touch "$flag"

  wake_pane "testpane"

  local first_line last_line
  first_line="$(head -1 "$log" 2>/dev/null || true)"
  last_line="$(tail -1 "$log" 2>/dev/null || true)"
  rm -f "$flag" "$log"

  # 本文が空でないこと（旧実装の空文字では Claude Code が新ターンを開始しない）
  [[ "$first_line" != "send-keys -t testpane" ]]
  [[ "$first_line" != "send-keys -t testpane " ]]
  # inbox への言及がある wake メッセージであること
  [[ "$first_line" == *"inbox"* ]]
  # 最後に Enter で送信が確定すること
  [ "$last_line" = "send-keys -t testpane Enter" ]
}

@test "wake_pane: does not send-keys when agent is busy" {
  local log; log="$(mktemp)"
  tmux() { printf '%s\n' "$*" >> "$log"; }
  sleep() { :; }

  AGENT_ID="karo"
  SHOGUN_PROJECT_ID=""
  SHOGUN_ROOT="/tmp/test_wakepane_$$"
  local flag; flag="$(shogun_idle_flag "$AGENT_ID" "")"
  rm -f "$flag"  # フラグ不在 = busy

  wake_pane "testpane"

  run cat "$log"
  rm -f "$log"
  [ "${#lines[@]}" -eq 0 ]
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
# is_agent_idle: Stop フックが立てた idle フラグで idle/busy を判定する
#
# idle（フラグあり）= ターン完了済みで安全に起こせる → 0
# busy（フラグなし）= 作業中なのでエスカレーションをスキップ → 1
# project_id 設定時はフラグ名に project_id を含める（名前衝突回避）。
# ────────────────────────────────────────────────────────────

@test "is_agent_idle: returns 0 (idle) when flag exists" {
  local agent="idletest_$$"
  touch "$(shogun_idle_flag "$agent" "")"
  run is_agent_idle "$agent" ""
  rm -f "$(shogun_idle_flag "$agent" "")"
  [ "$status" -eq 0 ]
}

@test "is_agent_idle: returns 1 (busy) when flag is absent" {
  local agent="idletest_$$"
  rm -f "$(shogun_idle_flag "$agent" "")"
  run is_agent_idle "$agent" ""
  [ "$status" -ne 0 ]
}

@test "is_agent_idle: uses project-specific flag when project_id is set" {
  local agent="idletest_$$" proj="idleproj_$$"
  touch "$(shogun_idle_flag "$agent" "$proj")"
  run is_agent_idle "$agent" "$proj"
  rm -f "$(shogun_idle_flag "$agent" "$proj")"
  [ "$status" -eq 0 ]
}

@test "is_agent_idle: project flag does not satisfy the no-project check" {
  # project 別フラグだけがある場合、project_id 未指定の判定では busy(1) になる
  local agent="idletest_$$" proj="idleproj_$$"
  touch "$(shogun_idle_flag "$agent" "$proj")"
  run is_agent_idle "$agent" ""
  rm -f "$(shogun_idle_flag "$agent" "$proj")"
  [ "$status" -ne 0 ]
}

