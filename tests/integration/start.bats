#!/usr/bin/env bats
# shogun start の統合テスト
#
# shogun start は単一の shogun-<name>-<hash> セッションに Taisho のみを起動する
# (Karo/Gunshi/Metsuke/Ashigaru は shogun spawn によるオンデマンド起動に移行済み)。
# 実 tmux を使わず、tmux をスタブ化して send-keys / new-session に渡る
# コマンド文字列を TMUX_LOG に記録し、Taisho ペインの配線を確認する。

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

@test "start: enables pane-border-status on the taisho session" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "pane-border-status top" "$TMUX_LOG"
  [ "$status" -eq 0 ]
}

@test "start: sets pane-border-format on the taisho session" {
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

@test "start: sets @shogun_role and @shogun_color pane options for taisho" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@shogun_role taisho" "$TMUX_LOG"
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@shogun_color magenta" "$TMUX_LOG"
  [ "$status" -eq 0 ]
}

@test "start: sets @agent_id pane option for taisho" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "set-option -p.*@agent_id taisho" "$TMUX_LOG"
  [ "$status" -eq 0 ]
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

@test "start: MCP config JSON exists before taisho claude command is launched" {
  # MCP JSON は claude を起動する前に生成されなければならない
  # (taisho は --mcp-config でそのファイルを直接参照する)。
  # tmux stub がコマンドを記録するので、JSON ファイルが存在するタイミングを検証できる。
  local stub_bin="${TEST_PROJECT}/stub-bin2"
  mkdir -p "$stub_bin"
  local log="${TEST_PROJECT}/order.log"
  : > "$log"
  # tmux stub: send-keys で claude 起動コマンドが来たとき、その時点で JSON が存在するか記録する
  cat > "${stub_bin}/tmux" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *"claude --model"* ]]; then
  if [ -f "${TEST_PROJECT}/.shogun/mcp/taisho.json" ]; then
    echo "json_exists_before_claude" >> "${log}"
  else
    echo "json_missing_before_claude" >> "${log}"
  fi
fi
printf '%s\n' "\$*" >> "${TEST_PROJECT}/tmux2.log"
exit 0
STUB
  chmod +x "${stub_bin}/tmux"
  export PATH="${stub_bin}:${PATH}"
  run shogun start
  [ "$status" -eq 0 ]
  # ログに "json_missing_before_claude" が一件もないこと
  run grep "json_missing_before_claude" "$log" || true
  [ -z "$output" ]
  # "json_exists_before_claude" が少なくとも1件あること(claude が呼ばれた証拠)
  run grep -c "json_exists_before_claude" "$log"
  [ "$output" -ge 1 ]
}

@test "start: creates exactly one tmux session (no multiagent session)" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep -c "^new-session " "$TMUX_LOG"
  [ "$output" = "1" ]
}

@test "start: does not spawn inbox_watcher for karo/gunshi/metsuke/ashigaru at startup" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "inbox_watcher.sh karo \|inbox_watcher.sh gunshi \|inbox_watcher.sh metsuke \|inbox_watcher.sh ashigaru" "$TMUX_LOG"
  [ "$status" -ne 0 ]
}

@test "start: does not launch inbox_watcher for taisho either (superseded by agmsg monitor)" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "inbox_watcher.sh taisho " "$TMUX_LOG"
  [ "$status" -ne 0 ]
}
