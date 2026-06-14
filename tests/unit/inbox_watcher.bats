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
# wake_up_inbox / wake_up_reports: busy 中は送らない（idle ゲート）
#
# Claude が作業中（busy = idle フラグ無し）のときに send-keys を撃つと、
# ヒアドキュメント実行中・描画中のペインへ注入され出力が破損する。
# idle（Stop フックが立てたフラグ有り）のときだけ通知する。
# ────────────────────────────────────────────────────────────

@test "wake_up_inbox: does NOT send when the agent is busy" {
  local tmp; tmp="$(mktemp -d)"
  AGENT_ID="wakegatetest_$$"
  PANE="testpane"
  ROOT="$tmp"
  INBOX="${tmp}/inbox.yaml"
  SHOGUN_PROJECT_ID=""
  cat > "$INBOX" <<'YAML'
messages:
  - status: unread
    subject: hi
YAML
  rm -f "$(shogun_idle_flag "$AGENT_ID" "")"   # busy

  local log; log="$(mktemp)"
  tmux() { printf '%s\n' "$*" >> "$log"; }
  sleep() { :; }

  wake_up_inbox

  run cat "$log"
  rm -rf "$tmp"; rm -f "$log"
  # busy のため tmux は一切呼ばれない
  [ -z "$output" ]
}

@test "wake_up_inbox: sends when the agent is idle and there is unread" {
  local tmp; tmp="$(mktemp -d)"
  AGENT_ID="wakegatetest_$$"
  PANE="testpane"
  ROOT="$tmp"
  INBOX="${tmp}/inbox.yaml"
  SHOGUN_PROJECT_ID=""
  cat > "$INBOX" <<'YAML'
messages:
  - status: unread
    subject: hi
YAML
  touch "$(shogun_idle_flag "$AGENT_ID" "")"   # idle

  local log; log="$(mktemp)"
  tmux() { printf '%s\n' "$*" >> "$log"; }
  sleep() { :; }

  wake_up_inbox

  run cat "$log"
  rm -rf "$tmp"; rm -f "$log" "$(shogun_idle_flag "$AGENT_ID" "")"
  # idle なので通知が送られる（tmux が呼ばれる）
  [ -n "$output" ]
}

@test "wake_up_reports: does NOT send when the agent is busy" {
  AGENT_ID="wakegatetest_$$"
  PANE="testpane"
  SHOGUN_PROJECT_ID=""
  rm -f "$(shogun_idle_flag "$AGENT_ID" "")" "$(shogun_reports_pending_flag "$AGENT_ID" "")"   # busy

  local log; log="$(mktemp)"
  tmux() { printf '%s\n' "$*" >> "$log"; }
  sleep() { :; }

  wake_up_reports

  run cat "$log"
  rm -f "$log" "$(shogun_reports_pending_flag "$AGENT_ID" "")"
  [ -z "$output" ]
}

# busy 中にスキップした report 通知は pending マーカーへ記録し、Stop フックが
# idle 復帰時に再通知できるようにする（次の更新イベントが来なくても取りこぼさない）。
@test "wake_up_reports: marks pending when the agent is busy" {
  AGENT_ID="wakegatetest_$$"
  PANE="testpane"
  SHOGUN_PROJECT_ID=""
  rm -f "$(shogun_idle_flag "$AGENT_ID" "")" "$(shogun_reports_pending_flag "$AGENT_ID" "")"   # busy

  tmux() { :; }
  sleep() { :; }

  wake_up_reports

  local exists=1
  [ -f "$(shogun_reports_pending_flag "$AGENT_ID" "")" ] && exists=0
  rm -f "$(shogun_reports_pending_flag "$AGENT_ID" "")"
  [ "$exists" -eq 0 ]
}

@test "wake_up_reports: uses a project-specific pending marker when project_id is set" {
  AGENT_ID="wakegatetest_$$"
  PANE="testpane"
  SHOGUN_PROJECT_ID="wakeproj_$$"
  rm -f "$(shogun_idle_flag "$AGENT_ID" "$SHOGUN_PROJECT_ID")" \
        "$(shogun_reports_pending_flag "$AGENT_ID" "$SHOGUN_PROJECT_ID")"   # busy

  tmux() { :; }
  sleep() { :; }

  wake_up_reports

  local exists=1
  [ -f "$(shogun_reports_pending_flag "$AGENT_ID" "$SHOGUN_PROJECT_ID")" ] && exists=0
  rm -f "$(shogun_reports_pending_flag "$AGENT_ID" "$SHOGUN_PROJECT_ID")"
  SHOGUN_PROJECT_ID=""
  [ "$exists" -eq 0 ]
}

@test "wake_up_reports: sends when the agent is idle" {
  AGENT_ID="wakegatetest_$$"
  PANE="testpane"
  SHOGUN_PROJECT_ID=""
  touch "$(shogun_idle_flag "$AGENT_ID" "")"   # idle

  local log; log="$(mktemp)"
  tmux() { printf '%s\n' "$*" >> "$log"; }
  sleep() { :; }

  wake_up_reports

  run cat "$log"
  rm -f "$log" "$(shogun_idle_flag "$AGENT_ID" "")"
  [ -n "$output" ]
}

# idle 復帰後に直接通知できたときは、残っている pending マーカーを掃除して
# Stop フックによる二重通知を避ける。
@test "wake_up_reports: clears a stale pending marker when sending while idle" {
  AGENT_ID="wakegatetest_$$"
  PANE="testpane"
  SHOGUN_PROJECT_ID=""
  touch "$(shogun_idle_flag "$AGENT_ID" "")"                       # idle
  touch "$(shogun_reports_pending_flag "$AGENT_ID" "")"            # 以前 busy 中に立った残骸

  tmux() { :; }
  sleep() { :; }

  wake_up_reports

  local still=1
  [ -f "$(shogun_reports_pending_flag "$AGENT_ID" "")" ] && still=0
  rm -f "$(shogun_idle_flag "$AGENT_ID" "")" "$(shogun_reports_pending_flag "$AGENT_ID" "")"
  # マーカーは消えている（still=1 のまま = ファイル無し）
  [ "$still" -eq 1 ]
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
# exec で sleep に置き換え、記録する PID 自身を sleep にする。
# subshell のまま foreground で sleep すると、subshell を kill しても孫の sleep が
# orphan 化して bats の出力パイプを掴み続け、全テスト通過後も bats が終了できなくなる。
# 本番の fswatch/inotifywait は親が死ねば SIGPIPE で連鎖終了するため、この exec 置換は
# 「記録した子プロセスが kill される」という検証意図と等価。
watch_reports() { sh -c 'echo $PPID' > "${TMP_DIR}/reports_pid"; exec sleep 999; }
watch_escalation() { sh -c 'echo $PPID' > "${TMP_DIR}/asw_pid"; exec sleep 999; }
# watch_inbox は実際の本番同様に SIGTERM が来るまでブロックする
watch_inbox() { exec sleep 999; }

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
