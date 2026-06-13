#!/usr/bin/env bats
# Integration tests for shogun upgrade

load '../test_helper'

setup() {
  TEST_PROJECT="$(mktemp -d)"
  export TEST_PROJECT
  cd "${TEST_PROJECT}"
}

teardown() {
  teardown_test_project
}

# --- option validation ---

@test "upgrade: exits 1 for invalid version format" {
  run shogun upgrade --version notaversion
  [ "$status" -eq 1 ]
}

@test "upgrade: exits 1 for version without v prefix" {
  run shogun upgrade --version 1.2.3
  [ "$status" -eq 1 ]
}

@test "upgrade: exits 1 for unknown option" {
  run shogun upgrade --unknown-option
  [ "$status" -eq 1 ]
}

@test "upgrade: exits 1 when --version has no value" {
  run shogun upgrade --version
  [ "$status" -eq 1 ]
}

# --- init: existing file protection (same copy logic) ---

@test "init: does not overwrite existing .claude/commands/ files" {
  shogun init
  local skill_file
  skill_file="$(ls .claude/commands/*.md 2>/dev/null | head -1)"
  [[ -n "$skill_file" ]] || skip "no skill files copied by init"

  local original_content="custom content preserved"
  echo "$original_content" > "$skill_file"

  # 2回目の shogun init でも既存ファイルは上書きされないこと
  shogun init >/dev/null 2>&1 || true

  local actual
  actual="$(cat "$skill_file")"
  [ "$actual" = "$original_content" ]
}

@test "init: copies new .claude/commands/ files when they do not exist" {
  shogun init
  local commands_dir=".claude/commands"
  [ -d "$commands_dir" ]
  # テンプレートにスキルファイルが存在すれば少なくとも1件コピーされること
  local count
  count="$(ls "${commands_dir}/"*.md 2>/dev/null | wc -l | tr -d ' ')"
  [ "$count" -gt 0 ]
}
