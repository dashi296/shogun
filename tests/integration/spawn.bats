#!/usr/bin/env bats
# Integration tests for shogun spawn

load '../test_helper'

setup() {
  init_test_project
  cd "${TEST_PROJECT}"
  shogun start --setup >/dev/null 2>&1

  # agmsg_adapter.sh の関数を fake に差し替える。
  # AGMSG_SPAWN_LOG に呼び出し引数を記録し、常に成功して固定の placement を返す。
  export AGMSG_SPAWN_LOG="${TEST_PROJECT}/agmsg_spawn.log"
  : > "$AGMSG_SPAWN_LOG"
  local fake_dir="${TEST_PROJECT}/fake-adapter"
  mkdir -p "$fake_dir"
  cat > "${fake_dir}/agmsg_adapter.sh" <<'FAKE'
agmsg_spawn() {
  echo "spawn $*" >> "${AGMSG_SPAWN_LOG}"
}
agmsg_get_placement() {
  printf '%%1\t/proj\tclaude-code\n'
}
FAKE
  export SHOGUN_FAKE_AGMSG_ADAPTER="${fake_dir}/agmsg_adapter.sh"

  _stub_tmux
}

teardown() {
  teardown_test_project
}

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

@test "spawn: rejects an invalid role name" {
  run shogun spawn "../evil"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "不正" ]]
}

@test "spawn: passes worker_model to agmsg_spawn" {
  run shogun spawn karo
  [ "$status" -eq 0 ]
  run grep -- "--model sonnet" "$AGMSG_SPAWN_LOG"
  [ "$status" -eq 0 ]
}

@test "spawn: uses --window for karo" {
  run shogun spawn karo
  [ "$status" -eq 0 ]
  run grep -- "--window" "$AGMSG_SPAWN_LOG"
  [ "$status" -eq 0 ]
}

@test "spawn: does not use --window for ashigaru1" {
  run shogun spawn ashigaru1
  [ "$status" -eq 0 ]
  run grep -- "--window" "$AGMSG_SPAWN_LOG"
  [ "$status" -ne 0 ]
}

@test "spawn: adds --fresh on the first spawn of a role in this run" {
  run shogun spawn karo
  [ "$status" -eq 0 ]
  run grep -- "--fresh" "$AGMSG_SPAWN_LOG"
  [ "$status" -eq 0 ]
}

@test "spawn: does not add --fresh on a second spawn of the same role in the same run" {
  shogun spawn karo >/dev/null
  : > "$AGMSG_SPAWN_LOG"
  run shogun spawn karo
  [ "$status" -eq 0 ]
  run grep -- "--fresh" "$AGMSG_SPAWN_LOG"
  [ "$status" -ne 0 ]
}
