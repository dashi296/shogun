#!/usr/bin/env bats
# shogun start の統合テスト（inbox_watcher への環境変数配線を検証）
#
# 実 tmux を使わず、tmux をスタブ化して send-keys に渡るコマンド文字列を
# TMUX_LOG に記録し、各役職の watcher 起動行に正しい SHOGUN_REPORT_SOURCES が
# 付与されることを確認する。
#   - taisho -> SHOGUN_REPORT_SOURCES=karo（Karo の集約報告のみ監視）
#   - karo   -> 配下 allowlist（gunshi metsuke ashigaru1 ...）
#   - worker(gunshi/metsuke/ashigaru) -> 付与しない

load '../test_helper'

setup() {
  init_test_project
  cd "${TEST_PROJECT}"
}

teardown() {
  teardown_test_project
}

# tmux をスタブ化し、全呼び出しの引数を TMUX_LOG に1行ずつ記録する
_stub_tmux() {
  local stub_bin="${TEST_PROJECT}/stub-bin"
  mkdir -p "$stub_bin"
  export TMUX_LOG="${TEST_PROJECT}/tmux.log"
  : > "$TMUX_LOG"
  cat > "${stub_bin}/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
exit 0
STUB
  chmod +x "${stub_bin}/tmux"
  export PATH="${stub_bin}:${PATH}"
}

@test "start: passes SHOGUN_REPORT_SOURCES=karo to taisho watcher" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "inbox_watcher.sh taisho " "$TMUX_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHOGUN_REPORT_SOURCES=karo"* ]]
}

@test "start: passes subordinate allowlist to karo watcher" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "inbox_watcher.sh karo " "$TMUX_LOG"
  [ "$status" -eq 0 ]
  # 固定役職 gunshi/metsuke の包含で allowlist 配線を確認（ashigaru 数には依存しない）
  [[ "$output" == *"SHOGUN_REPORT_SOURCES='gunshi metsuke"* ]]
}

@test "start: does not pass SHOGUN_REPORT_SOURCES to worker watchers" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "inbox_watcher.sh gunshi " "$TMUX_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOGUN_REPORT_SOURCES"* ]]

  run grep "inbox_watcher.sh ashigaru1 " "$TMUX_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SHOGUN_REPORT_SOURCES"* ]]
}
