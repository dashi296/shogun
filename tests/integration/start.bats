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

@test "start: enables pane-border-status on both sessions" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "pane-border-status top" "$TMUX_LOG"
  [ "$status" -eq 0 ]
  # taisho と multiagent の2セッション分が設定される
  [ "$(grep -c "pane-border-status top" "$TMUX_LOG")" -ge 2 ]
}

@test "start: sets pane-border-format on both sessions" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "pane-border-format" "$TMUX_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pane_title"* ]]
  [[ "$output" == *"@shogun_role"* ]]
  [[ "$output" == *"@shogun_color"* ]]
}

@test "start: sets initial pane title for taisho" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "select-pane" "$TMUX_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-T taisho: 待機中"* ]]
}

@test "start: sets initial pane title for each agent" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "select-pane.*-T karo: 待機中" "$TMUX_LOG"
  [ "$status" -eq 0 ]

  run grep "select-pane.*-T ashigaru1: 待機中" "$TMUX_LOG"
  [ "$status" -eq 0 ]
}

@test "start: sets @shogun_role and @shogun_color pane options for taisho" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@shogun_role taisho" "$TMUX_LOG"
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@shogun_color magenta" "$TMUX_LOG"
  [ "$status" -eq 0 ]
}

@test "start: sets @shogun_role and @shogun_color pane options for each agent" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@shogun_role karo" "$TMUX_LOG"
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@shogun_color yellow" "$TMUX_LOG"
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@shogun_role gunshi" "$TMUX_LOG"
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@shogun_color cyan" "$TMUX_LOG"
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@shogun_role metsuke" "$TMUX_LOG"
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@shogun_color red" "$TMUX_LOG"
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@shogun_role ashigaru1" "$TMUX_LOG"
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@shogun_color green" "$TMUX_LOG"
  [ "$status" -eq 0 ]
}

@test "start: sets @agent_id pane option for taisho" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@agent_id taisho" "$TMUX_LOG"
  [ "$status" -eq 0 ]
}

@test "start: sets @agent_id pane option for each agent" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@agent_id karo" "$TMUX_LOG"
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@agent_id gunshi" "$TMUX_LOG"
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@agent_id metsuke" "$TMUX_LOG"
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@agent_id ashigaru1" "$TMUX_LOG"
  [ "$status" -eq 0 ]
}

# ── Agent Self-Watch（ASW）環境変数の配線テスト ──

@test "start: passes SHOGUN_ASW_ENABLED=false to taisho watcher by default" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "inbox_watcher.sh taisho " "$TMUX_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHOGUN_ASW_ENABLED=false"* ]]
}

@test "start: passes SHOGUN_ASW_ENABLED=false to worker watchers by default" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "inbox_watcher.sh karo " "$TMUX_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHOGUN_ASW_ENABLED=false"* ]]
}

@test "start: passes SHOGUN_ASW_ENABLED=true when escalation_policy.enabled is true" {
  # config.yaml の escalation_policy.enabled を true に書き換えてから起動
  node -e '
const yaml = require("js-yaml");
const fs = require("fs");
const cfg = ".shogun/config.yaml";
const d = yaml.load(fs.readFileSync(cfg, "utf8"));
d.escalation_policy = d.escalation_policy || {};
d.escalation_policy.enabled = true;
fs.writeFileSync(cfg, yaml.dump(d, {allowUnicode: true}));
'
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "inbox_watcher.sh taisho " "$TMUX_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHOGUN_ASW_ENABLED=true"* ]]
}

@test "start: resets ashigaru review files to reviews: []" {
  _stub_tmux
  # 既存の review ファイルを事前に作成
  mkdir -p ".shogun/queue/reviews"
  printf 'reviews:\n  - round: 1\n' > ".shogun/queue/reviews/ashigaru1_review.yaml"
  run shogun start --clean --setup
  [ "$status" -eq 0 ]
  run cat ".shogun/queue/reviews/ashigaru1_review.yaml"
  [ "$output" = "reviews: []" ]
}
