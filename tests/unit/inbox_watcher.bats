#!/usr/bin/env bats
# Unit tests for scripts/inbox_watcher.sh
#
# fswatch/inotifywait の監視ループ自体は long-running で直接テストできないため、
# 「変更された report ファイルで上位を起こすべきか」を判定する純粋関数
# should_wake_on_report を切り出してテストする。
# スクリプトは末尾の監視ループを source ガードで囲み、関数だけ source できる。

load '../test_helper'

# BASH_SOURCE != $0 となるよう source して関数定義のみ読み込む
setup() {
  source "${SHOGUN_REPO}/scripts/inbox_watcher.sh"
}

@test "should_wake_on_report: wakes on another agent's report" {
  run should_wake_on_report "ashigaru1_report.yaml" "karo"
  [ "$status" -eq 0 ]
}

@test "should_wake_on_report: wakes on gunshi/metsuke reports" {
  run should_wake_on_report "gunshi_report.yaml" "karo"
  [ "$status" -eq 0 ]
  run should_wake_on_report "metsuke_report.yaml" "karo"
  [ "$status" -eq 0 ]
}

@test "should_wake_on_report: does not wake on own report (self-wake guard)" {
  run should_wake_on_report "karo_report.yaml" "karo"
  [ "$status" -ne 0 ]
}

@test "should_wake_on_report: taisho wakes on karo_report" {
  run should_wake_on_report "karo_report.yaml" "taisho"
  [ "$status" -eq 0 ]
}

@test "should_wake_on_report: ignores non-report files" {
  run should_wake_on_report "notes.txt" "karo"
  [ "$status" -ne 0 ]
  run should_wake_on_report ".karo_report.yaml.swp" "karo"
  [ "$status" -ne 0 ]
}
