#!/usr/bin/env bash
# mark_busy.sh の bats テスト
# ターン開始（UserPromptSubmit）時に idle フラグを削除して busy 状態へ遷移することを検証する。
# stop_hook.sh が立てた idle フラグを消す対になるスクリプト。

load '../test_helper'

setup() {
  _SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../scripts" && pwd)"
  # フラグ命名を被テストスクリプトと共有するため flag_names.sh を source する。
  # SHOGUN_ROOT を固定し、ヘルパーが返すフラグパスをテスト側でも決定的に再現する。
  export SHOGUN_ROOT="/tmp/markbusyroot_$$"
  source "${SHOGUN_REPO}/scripts/flag_names.sh"
  # テスト固有の role 名を使い、/tmp のフラグ衝突を避ける
  ROLE="markbusytest"
  PROJ="markbusyproj"
  IDLE="$(shogun_idle_flag "$ROLE" "")"
  IDLE_PROJ="$(shogun_idle_flag "$ROLE" "$PROJ")"
  rm -f "$IDLE" "$IDLE_PROJ"
}

teardown() {
  rm -f "$IDLE" "$IDLE_PROJ"
  unset SHOGUN_ROLE SHOGUN_PROJECT_ID SHOGUN_ROOT
}

# 注: @test 名は ASCII（英語）で記述する（bash 3.2 の bats 制約）。
@test "mark_busy: removes the idle flag" {
  touch "$IDLE"
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/mark_busy.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$IDLE" ]
}

@test "mark_busy: removes the project-specific flag when SHOGUN_PROJECT_ID is set" {
  touch "$IDLE_PROJ"
  SHOGUN_ROLE="$ROLE" SHOGUN_PROJECT_ID="$PROJ" run bash "${_SCRIPT_DIR}/mark_busy.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$IDLE_PROJ" ]
}

@test "mark_busy: does not touch the non-project flag when SHOGUN_PROJECT_ID is set" {
  touch "$IDLE"
  SHOGUN_ROLE="$ROLE" SHOGUN_PROJECT_ID="$PROJ" run bash "${_SCRIPT_DIR}/mark_busy.sh"
  [ "$status" -eq 0 ]
  # project_id 指定時は project 別フラグだけを消し、無印フラグは残す
  [ -f "$IDLE" ]
}

@test "mark_busy: exits 0 when the flag is already absent" {
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/mark_busy.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$IDLE" ]
}

@test "mark_busy: exits 0 with no output when SHOGUN_ROLE is unset" {
  unset SHOGUN_ROLE
  run bash "${_SCRIPT_DIR}/mark_busy.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mark_busy: does nothing for a path-traversal SHOGUN_ROLE" {
  SHOGUN_ROLE="../evil" run bash "${_SCRIPT_DIR}/mark_busy.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mark_busy: does nothing for a path-traversal SHOGUN_PROJECT_ID" {
  touch "$IDLE"
  SHOGUN_ROLE="$ROLE" SHOGUN_PROJECT_ID="../../evil" run bash "${_SCRIPT_DIR}/mark_busy.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # 不正な project_id ではフラグ名へ展開せず、何も消さない
  [ -f "$IDLE" ]
}
