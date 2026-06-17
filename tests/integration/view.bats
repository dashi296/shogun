#!/usr/bin/env bats
# Integration tests for shogun view

load '../test_helper'

setup() {
  init_test_project
  cd "${TEST_PROJECT}"
}

teardown() {
  teardown_test_project
}

@test "view: fails in uninitialized directory" {
  local no_init_dir
  no_init_dir="$(mktemp -d)"
  cd "$no_init_dir"

  run shogun view
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]

  rm -rf "$no_init_dir"
}

# ─── _view_render() を bash -c で呼ぶ共通ヘルパー ───────────
_run_view_render() {
  run bash -c "
    export SHOGUN_ROOT='${TEST_PROJECT}'
    export SHOGUN_BIN_DIR='${SHOGUN_REPO}'
    source '${SHOGUN_REPO}/bin/shogun'
    _view_render
  "
}

# idle フラグのパスを返す（flag_names.sh と同一ロジック）
_idle_flag_path() {
  local agent="$1"
  local root_key
  root_key="$(printf '%s' "${TEST_PROJECT}" | cksum | cut -d' ' -f1)"
  echo "/tmp/shogun_idle_${root_key}_${agent}"
}

@test "view render: BUSY agent is shown as BUSY" {
  # karo の idle フラグを削除して BUSY 状態にする
  rm -f "$(_idle_flag_path karo)"

  _run_view_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"● BUSY"* ]]
}

@test "view render: idle agent is shown as idle" {
  # karo に idle フラグを作成して idle 状態にする
  touch "$(_idle_flag_path karo)"

  _run_view_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"● idle"* ]]

  rm -f "$(_idle_flag_path karo)"
}

@test "view render: inbox unread count is shown in inbox:N format" {
  _run_view_render
  [ "$status" -eq 0 ]
  [[ "$output" =~ inbox:[0-9] ]]
}
