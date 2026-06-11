#!/usr/bin/env bats
# Unit tests for shogun version command

load '../test_helper'

@test "version: outputs 'shogun' and a version string" {
  run shogun version
  [ "$status" -eq 0 ]
  [[ "$output" == shogun\ v* ]]
}

@test "version: --version flag works" {
  run shogun --version
  [ "$status" -eq 0 ]
  [[ "$output" == shogun\ v* ]]
}

@test "version: -v flag works" {
  run shogun -v
  [ "$status" -eq 0 ]
  [[ "$output" == shogun\ v* ]]
}
