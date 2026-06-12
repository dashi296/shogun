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
