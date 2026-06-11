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
  shogun task "build auth feature" >/dev/null
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
