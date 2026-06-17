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

# ── MCP サーバ起動・設定ファイル生成のテスト ──

@test "start: creates MCP config JSON for taisho" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]
  [ -f ".shogun/mcp/taisho.json" ]
}

@test "start: taisho MCP config contains allowed-sources=karo" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]
  run node -e "
const d = JSON.parse(require('fs').readFileSync('.shogun/mcp/taisho.json', 'utf8'));
const args = Object.values(d.mcpServers)[0].args.join(' ');
process.stdout.write(args);
"
  [[ "$output" == *"--allowed-sources=karo"* ]]
}

@test "start: creates MCP config JSON for each role" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]
  for role in karo gunshi metsuke ashigaru1; do
    [ -f ".shogun/mcp/${role}.json" ]
  done
}

@test "start: karo MCP config has correct allowed-sources (subordinates)" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]
  run node -e "
const d = JSON.parse(require('fs').readFileSync('.shogun/mcp/karo.json', 'utf8'));
const args = Object.values(d.mcpServers)[0].args.join(' ');
process.stdout.write(args);
"
  # karo は gunshi, metsuke, ashigaru{N} を受け取る allowlist を持つ
  [[ "$output" == *"--allowed-sources="* ]]
  [[ "$output" == *"gunshi"* ]]
  [[ "$output" == *"metsuke"* ]]
}

@test "start: worker roles have MCP config with correct server name" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]
  for role in gunshi metsuke ashigaru1; do
    run node -e "
const d = JSON.parse(require('fs').readFileSync('.shogun/mcp/${role}.json', 'utf8'));
process.stdout.write(Object.keys(d.mcpServers)[0]);
"
    [ "$output" = "shogun-mcp-queue-${role}" ]
  done
}

@test "start: passes SHOGUN_BIN_DIR to taisho watcher" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]
  run grep "inbox_watcher.sh taisho " "$TMUX_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHOGUN_BIN_DIR="* ]]
}

@test "start: passes SHOGUN_BIN_DIR to worker watchers" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]
  run grep "inbox_watcher.sh karo " "$TMUX_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHOGUN_BIN_DIR="* ]]
  run grep "inbox_watcher.sh ashigaru1 " "$TMUX_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHOGUN_BIN_DIR="* ]]
}

@test "start: MCP config JSON files exist before watcher is launched" {
  # MCP JSON は claude/watcher を起動する前（--setup でも）に生成されなければならない。
  # tmux stub がコマンドを記録するので、JSON ファイルが存在するタイミングを検証できる。
  local stub_bin="${TEST_PROJECT}/stub-bin2"
  mkdir -p "$stub_bin"
  local log="${TEST_PROJECT}/order.log"
  : > "$log"
  # tmux stub: send-keys でコマンドが来たとき、その時点で JSON が存在するか記録する
  cat > "${stub_bin}/tmux" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *"inbox_watcher"* ]]; then
  if [ -f "${TEST_PROJECT}/.shogun/mcp/taisho.json" ]; then
    echo "json_exists_before_watcher" >> "${log}"
  else
    echo "json_missing_before_watcher" >> "${log}"
  fi
fi
printf '%s\n' "\$*" >> "${TEST_PROJECT}/tmux2.log"
exit 0
STUB
  chmod +x "${stub_bin}/tmux"
  export PATH="${stub_bin}:${PATH}"
  run shogun start --setup
  [ "$status" -eq 0 ]
  # ログに "json_missing_before_watcher" が一件もないこと
  run grep "json_missing_before_watcher" "$log" || true
  [ -z "$output" ]
  # "json_exists_before_watcher" が少なくとも1件あること（watcher が呼ばれた証拠）
  run grep -c "json_exists_before_watcher" "$log"
  [ "$output" -ge 1 ]
}
