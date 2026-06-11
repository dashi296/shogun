#!/usr/bin/env bats
# shogun attach の統合テスト

load '../test_helper'

declare -a EXTRA_TMUX_SESSIONS=()
declare -a EXTRA_DIRS=()

setup() {
  init_test_project
  cd "${TEST_PROJECT}"
}

test_safe_name() {
  local project_name="$1"
  local safe_name
  safe_name="$(printf "%s" "$project_name" | LC_ALL=C tr -c 'A-Za-z0-9_-' '_')"
  if [[ -z "$safe_name" ]]; then
    safe_name="shogun"
  fi
  printf "%s" "$safe_name"
}

test_root_hash() {
  local root="$1"
  local physical_root
  physical_root="$(cd "$root" && pwd -P)"
  node -e "
const crypto = require('crypto');
process.stdout.write(crypto.createHash('sha1').update(process.argv[1]).digest('hex').slice(0, 8));
" "$physical_root"
}

test_session_names() {
  local project_name="$1"
  local root="$2"
  local safe_name root_hash
  safe_name="$(test_safe_name "$project_name")"
  root_hash="$(test_root_hash "$root")"
  printf "%s %s\n" "taisho-${safe_name}-${root_hash}" "multiagent-${safe_name}-${root_hash}"
}

# attach-session / switch-client をログに記録して exit 0 で返すスタブ。
# has-session 等は実 tmux に委譲してセッション存在チェックを正しく機能させる。
_stub_tmux_passthrough() {
  local stub_bin="${TEST_PROJECT}/stub-bin"
  mkdir -p "$stub_bin"
  export TMUX_LOG="${TEST_PROJECT}/tmux.log"
  : > "$TMUX_LOG"
  local real_tmux
  real_tmux="$(command -v tmux)"
  cat > "${stub_bin}/tmux" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  attach|attach-session|switch-client)
    printf '%s\n' "\$*" >> "\$TMUX_LOG"
    exit 0 ;;
  *)
    exec env -u TMUX ${real_tmux} "\$@" ;;
esac
STUB
  chmod +x "${stub_bin}/tmux"
  export PATH="${stub_bin}:${PATH}"
}

teardown() {
  local project_name session_taisho session_multi extra_session extra_dir
  if [[ -f "${TEST_PROJECT}/.shogun/config.yaml" ]]; then
    project_name="$(yaml_query "${TEST_PROJECT}/.shogun/config.yaml" "process.stdout.write(String(d.project_name || 'shogun'));")"
    read -r session_taisho session_multi <<< "$(test_session_names "$project_name" "$TEST_PROJECT")"
    tmux kill-session -t "=${session_taisho}" 2>/dev/null || true
    tmux kill-session -t "=${session_multi}"  2>/dev/null || true
  fi
  for extra_session in "${EXTRA_TMUX_SESSIONS[@]}"; do
    tmux kill-session -t "=${extra_session}" 2>/dev/null || true
  done
  for extra_dir in "${EXTRA_DIRS[@]}"; do
    rm -rf "$extra_dir"
  done
  teardown_test_project
}

@test "attach: exits 1 with shogun start hint when session not found" {
  run shogun attach
  [ "$status" -eq 1 ]
  [[ "$output" == *"shogun start"* ]]
}

@test "attach taisho: exits 1 when taisho session not found" {
  run shogun attach taisho
  [ "$status" -eq 1 ]
  [[ "$output" == *"shogun start"* ]]
}

@test "attach multi: exits 1 when multi session not found" {
  run shogun attach multi
  [ "$status" -eq 1 ]
  [[ "$output" == *"shogun start"* ]]
}

@test "attach: exits 1 for unknown target" {
  run shogun attach unknown_target
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown_target"* ]]
}

@test "attach: uses switch-client for taisho when inside tmux (default target)" {
  _stub_tmux_passthrough
  local project_name session_taisho session_multi
  project_name="$(basename "${TEST_PROJECT}")"
  read -r session_taisho session_multi <<< "$(test_session_names "$project_name" "$TEST_PROJECT")"
  tmux new-session -d -s "$session_taisho"

  run env TMUX=mock shogun attach
  [ "$status" -eq 0 ]
  [[ "$(cat "$TMUX_LOG")" == *"switch-client"* ]]
  [[ "$(cat "$TMUX_LOG")" == *"=${session_taisho}"* ]]
}

@test "attach taisho: uses switch-client for taisho when inside tmux" {
  _stub_tmux_passthrough
  local project_name session_taisho session_multi
  project_name="$(basename "${TEST_PROJECT}")"
  read -r session_taisho session_multi <<< "$(test_session_names "$project_name" "$TEST_PROJECT")"
  tmux new-session -d -s "$session_taisho"

  run env TMUX=mock shogun attach taisho
  [ "$status" -eq 0 ]
  [[ "$(cat "$TMUX_LOG")" == *"switch-client"* ]]
  [[ "$(cat "$TMUX_LOG")" == *"=${session_taisho}"* ]]
}

@test "attach multi: uses switch-client for multiagent when inside tmux" {
  _stub_tmux_passthrough
  local project_name session_taisho session_multi
  project_name="$(basename "${TEST_PROJECT}")"
  read -r session_taisho session_multi <<< "$(test_session_names "$project_name" "$TEST_PROJECT")"
  tmux new-session -d -s "$session_multi"

  run env TMUX=mock shogun attach multi
  [ "$status" -eq 0 ]
  [[ "$(cat "$TMUX_LOG")" == *"switch-client"* ]]
  [[ "$(cat "$TMUX_LOG")" == *"=${session_multi}"* ]]
}

@test "attach multiagent: alias for multi connects to multiagent session" {
  _stub_tmux_passthrough
  local project_name session_taisho session_multi
  project_name="$(basename "${TEST_PROJECT}")"
  read -r session_taisho session_multi <<< "$(test_session_names "$project_name" "$TEST_PROJECT")"
  tmux new-session -d -s "$session_multi"

  run env TMUX=mock shogun attach multiagent
  [ "$status" -eq 0 ]
  [[ "$(cat "$TMUX_LOG")" == *"switch-client"* ]]
  [[ "$(cat "$TMUX_LOG")" == *"=${session_multi}"* ]]
}

@test "attach: uses attach-session when not inside tmux" {
  _stub_tmux_passthrough
  local project_name session_taisho session_multi
  project_name="$(basename "${TEST_PROJECT}")"
  read -r session_taisho session_multi <<< "$(test_session_names "$project_name" "$TEST_PROJECT")"
  tmux new-session -d -s "$session_taisho"

  run env -u TMUX shogun attach
  [ "$status" -eq 0 ]
  [[ "$(cat "$TMUX_LOG")" == *"attach-session"* ]]
  [[ "$(cat "$TMUX_LOG")" == *"=${session_taisho}"* ]]
}

@test "attach: exits 1 for invalid target name (path traversal ../evil)" {
  run shogun attach "../evil"
  [ "$status" -eq 1 ]
  [[ "$output" == *"不正なターゲット名"* ]]
}

@test "attach: exits 1 for invalid target name (semicolon a;b)" {
  run shogun attach "a;b"
  [ "$status" -eq 1 ]
  [[ "$output" == *"不正なターゲット名"* ]]
}

@test "attach: exits 1 for invalid target name (space a b)" {
  run shogun attach "a b"
  [ "$status" -eq 1 ]
  [[ "$output" == *"不正なターゲット名"* ]]
}
