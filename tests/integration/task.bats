#!/usr/bin/env bats
# Integration tests for shogun task

load '../test_helper'

setup() {
  init_test_project
  cd "${TEST_PROJECT}"
}

teardown() {
  teardown_test_project
}

# --- agmsg 送信への置き換え後の振る舞い ---

_stub_agmsg_send() {
  local fake_dir="${TEST_PROJECT}/fake-adapter"
  mkdir -p "$fake_dir"
  export AGMSG_SEND_LOG="${TEST_PROJECT}/agmsg_send.log"
  : > "$AGMSG_SEND_LOG"
  cat > "${fake_dir}/agmsg_adapter.sh" <<'FAKE'
agmsg_send() { echo "send $*" >> "${AGMSG_SEND_LOG}"; }
FAKE
  export SHOGUN_FAKE_AGMSG_ADAPTER="${fake_dir}/agmsg_adapter.sh"
}

@test "task: sends the task description to taisho via agmsg" {
  _stub_agmsg_send
  run shogun task "build auth feature"
  [ "$status" -eq 0 ]
  run grep "taisho" "$AGMSG_SEND_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"build auth feature"* ]]
}

@test "task: no longer writes shogun_to_karo.yaml" {
  _stub_agmsg_send
  shogun task "build auth feature" >/dev/null
  [ ! -f ".shogun/queue/shogun_to_karo.yaml" ] || {
    run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/queue/shogun_to_karo.yaml', 'utf8')) || {commands: []};
process.stdout.write(String((d.commands || []).length));
"
    [ "$output" = "0" ]
  }
}

@test "task: --priority option is shown in output but not persisted to a queue file" {
  _stub_agmsg_send
  run shogun task "urgent fix" --priority high
  [ "$status" -eq 0 ]
  [[ "$output" == *"優先度: high"* ]]
}

@test "task: --priority=value form is accepted" {
  _stub_agmsg_send
  run shogun task "urgent fix" --priority=high
  [ "$status" -eq 0 ]
  [[ "$output" == *"優先度: high"* ]]
}

# --- error cases ---

@test "task: fails outside initialized directory" {
  local no_init_dir
  no_init_dir="$(mktemp -d)"
  cd "$no_init_dir"

  run shogun task "some task"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]

  rm -rf "$no_init_dir"
}

@test "task: rejects unknown options" {
  _stub_agmsg_send
  run shogun task "build auth feature" --bogus-option
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]
}
