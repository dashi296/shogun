#!/usr/bin/env bash
# mark_busy.sh の bats テスト
# ターン開始（UserPromptSubmit）時に idle フラグを削除して busy 状態へ遷移することを検証する。
# stop_hook.sh が立てた idle フラグを消す対になるスクリプト。

setup() {
  _SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../scripts" && pwd)"
  # テスト固有の role 名を使い、/tmp のフラグ衝突を避ける
  ROLE="markbusytest"
  PROJ="markbusyproj"
  rm -f "/tmp/shogun_idle_${ROLE}" "/tmp/shogun_idle_${PROJ}_${ROLE}"
}

teardown() {
  rm -f "/tmp/shogun_idle_${ROLE}" "/tmp/shogun_idle_${PROJ}_${ROLE}"
  unset SHOGUN_ROLE SHOGUN_PROJECT_ID
}

# 注: @test 名は ASCII（英語）で記述する（bash 3.2 の bats 制約）。
@test "mark_busy: removes the idle flag" {
  touch "/tmp/shogun_idle_${ROLE}"
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/mark_busy.sh"
  [ "$status" -eq 0 ]
  [ ! -f "/tmp/shogun_idle_${ROLE}" ]
}

@test "mark_busy: removes the project-specific flag when SHOGUN_PROJECT_ID is set" {
  touch "/tmp/shogun_idle_${PROJ}_${ROLE}"
  SHOGUN_ROLE="$ROLE" SHOGUN_PROJECT_ID="$PROJ" run bash "${_SCRIPT_DIR}/mark_busy.sh"
  [ "$status" -eq 0 ]
  [ ! -f "/tmp/shogun_idle_${PROJ}_${ROLE}" ]
}

@test "mark_busy: does not touch the non-project flag when SHOGUN_PROJECT_ID is set" {
  touch "/tmp/shogun_idle_${ROLE}"
  SHOGUN_ROLE="$ROLE" SHOGUN_PROJECT_ID="$PROJ" run bash "${_SCRIPT_DIR}/mark_busy.sh"
  [ "$status" -eq 0 ]
  # project_id 指定時は project 別フラグだけを消し、無印フラグは残す
  [ -f "/tmp/shogun_idle_${ROLE}" ]
}

@test "mark_busy: exits 0 when the flag is already absent" {
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/mark_busy.sh"
  [ "$status" -eq 0 ]
  [ ! -f "/tmp/shogun_idle_${ROLE}" ]
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
  touch "/tmp/shogun_idle_${ROLE}"
  SHOGUN_ROLE="$ROLE" SHOGUN_PROJECT_ID="../../evil" run bash "${_SCRIPT_DIR}/mark_busy.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # 不正な project_id ではフラグ名へ展開せず、何も消さない
  [ -f "/tmp/shogun_idle_${ROLE}" ]
}
