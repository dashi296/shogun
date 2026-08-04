#!/usr/bin/env bats
# Unit tests for project_session_name (bin/shogun) — 1セッション統合後の命名

load '../test_helper'

setup() {
  TEST_ROOT="$(mktemp -d)"
}

teardown() {
  rm -rf "${TEST_ROOT}"
}

@test "project_session_name: returns a single 'shogun-' prefixed session name" {
  run bash -c "source '${SHOGUN_REPO}/bin/shogun' 2>/dev/null; project_session_name 'my project' '${TEST_ROOT}'"
  [ "$status" -eq 0 ]
  [[ "$output" == shogun-my_project-* ]]
  # 空白を含まない（1つの tmux セッション名として妥当）
  [[ "$output" != *" "* ]]
}

@test "project_session_name: is stable for the same project_name and root" {
  local a b
  a="$(bash -c "source '${SHOGUN_REPO}/bin/shogun' 2>/dev/null; project_session_name 'proj' '${TEST_ROOT}'")"
  b="$(bash -c "source '${SHOGUN_REPO}/bin/shogun' 2>/dev/null; project_session_name 'proj' '${TEST_ROOT}'")"
  [ "$a" = "$b" ]
}
