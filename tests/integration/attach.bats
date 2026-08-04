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

# 1セッション構成: project_session_name() が返す単一の tmux セッション名
test_session_name() {
  local project_name="$1"
  local root="$2"
  local safe_name root_hash
  safe_name="$(test_safe_name "$project_name")"
  root_hash="$(test_root_hash "$root")"
  printf "shogun-%s-%s" "${safe_name}" "${root_hash}"
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
  local project_name session extra_session extra_dir
  if [[ -f "${TEST_PROJECT}/.shogun/config.yaml" ]]; then
    project_name="$(yaml_query "${TEST_PROJECT}/.shogun/config.yaml" "process.stdout.write(String(d.project_name || 'shogun'));")"
    session="$(test_session_name "$project_name" "$TEST_PROJECT")"
    tmux kill-session -t "=${session}" 2>/dev/null || true
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

@test "attach: extra positional args are ignored (single-session, no target) when session not found" {
  # 旧 2セッション構成では taisho/multi ターゲットを解決していたが、
  # 1セッション構成では cmd_attach は引数を一切読まない。
  # 余分な引数を渡しても単一セッションの解決結果に影響しないことを確認する。
  run shogun attach taisho
  [ "$status" -eq 1 ]
  [[ "$output" == *"shogun start"* ]]

  run shogun attach some_arbitrary_arg
  [ "$status" -eq 1 ]
  [[ "$output" == *"shogun start"* ]]
}

@test "attach: uses switch-client for the single session when inside tmux" {
  _stub_tmux_passthrough
  local project_name session
  project_name="$(basename "${TEST_PROJECT}")"
  session="$(test_session_name "$project_name" "$TEST_PROJECT")"
  tmux new-session -d -s "$session"

  run env TMUX=mock shogun attach
  [ "$status" -eq 0 ]
  [[ "$(cat "$TMUX_LOG")" == *"switch-client"* ]]
  [[ "$(cat "$TMUX_LOG")" == *"=${session}"* ]]
}

@test "attach: uses attach-session when not inside tmux" {
  _stub_tmux_passthrough
  local project_name session
  project_name="$(basename "${TEST_PROJECT}")"
  session="$(test_session_name "$project_name" "$TEST_PROJECT")"
  tmux new-session -d -s "$session"

  run env -u TMUX shogun attach
  [ "$status" -eq 0 ]
  [[ "$(cat "$TMUX_LOG")" == *"attach-session"* ]]
  [[ "$(cat "$TMUX_LOG")" == *"=${session}"* ]]
}
