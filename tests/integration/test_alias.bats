#!/usr/bin/env bats
# sengoku alias (shutsujin / kijin) integration tests

load '../test_helper'

setup() {
  init_test_project
  cd "${TEST_PROJECT}"
}

teardown() {
  teardown_test_project
}

@test "shutsujin: recognized as a valid command (no unknown-command error)" {
  run shogun shutsujin --setup
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"不明なコマンド"* ]]
  ! [[ "$output" == *"unknown command"* ]]
}

@test "kijin: recognized as a valid command (no unknown-command error)" {
  run shogun kijin
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"不明なコマンド"* ]]
  ! [[ "$output" == *"unknown command"* ]]
}

@test "start: still works for backward compatibility" {
  run shogun start --setup
  [ "$status" -eq 0 ]
}

@test "stop: still works for backward compatibility" {
  run shogun stop
  [ "$status" -eq 0 ]
}

@test "help: shows shutsujin alias" {
  run shogun help
  [ "$status" -eq 0 ]
  [[ "$output" == *"shutsujin"* ]]
  [[ "$output" == *"出陣"* ]]
}

@test "help: shows kijin alias" {
  run shogun help
  [ "$status" -eq 0 ]
  [[ "$output" == *"kijin"* ]]
  [[ "$output" == *"帰陣"* ]]
}
