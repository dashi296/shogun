#!/usr/bin/env bats
# Integration tests for shogun status

load '../test_helper'

setup() {
  init_test_project
  cd "${TEST_PROJECT}"
}

teardown() {
  teardown_test_project
}

@test "status: displays command queue contents" {
  # shogun task はもはや shogun_to_karo.yaml に書き込まないため（agmsg send 経由に
  # 置き換え済み）、shogun status のキュー表示自体を検証するために直接書き込む。
  node -e "
const fs = require('fs');
const yaml = require('js-yaml');
const data = { commands: [{ id: 'cmd_001', timestamp: new Date().toISOString(), command: 'build auth feature', priority: 'normal', status: 'pending' }] };
fs.writeFileSync('.shogun/queue/shogun_to_karo.yaml', yaml.dump(data, { allowUnicode: true }));
"
  run shogun status
  [ "$status" -eq 0 ]
  [[ "$output" == *"cmd_001"* ]]
  [[ "$output" == *"pending"* ]]
}

@test "status: displays agent names" {
  run shogun status
  [ "$status" -eq 0 ]
  [[ "$output" == *"karo"* ]]
  [[ "$output" == *"gunshi"* ]]
  [[ "$output" == *"metsuke"* ]]
}

@test "status: shows dashboard path" {
  run shogun status
  [ "$status" -eq 0 ]
  [[ "$output" == *"dashboard"* ]]
}

@test "status: fails outside initialized directory" {
  local no_init_dir
  no_init_dir="$(mktemp -d)"
  cd "$no_init_dir"

  run shogun status
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]

  rm -rf "$no_init_dir"
}
