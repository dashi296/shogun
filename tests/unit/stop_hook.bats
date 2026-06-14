#!/usr/bin/env bash
# stop_hook.sh の bats テスト
# ターン完了時の idle フラグ作成・project_id 分岐・inbox 未読通知を検証する

load '../test_helper'

setup() {
  _SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../scripts" && pwd)"
  TMP_ROOT="$(mktemp -d)"
  export SHOGUN_ROOT="$TMP_ROOT"
  # フラグ命名を被テストスクリプトと共有するため flag_names.sh を source する。
  source "${SHOGUN_REPO}/scripts/flag_names.sh"
  # テスト固有の role 名を使い、/tmp のフラグ衝突を避ける
  ROLE="stophooktest"
  PROJ="stophookproj"
  IDLE="$(shogun_idle_flag "$ROLE" "")"
  IDLE_PROJ="$(shogun_idle_flag "$ROLE" "$PROJ")"
  PENDING="$(shogun_reports_pending_flag "$ROLE" "")"
  PENDING_PROJ="$(shogun_reports_pending_flag "$ROLE" "$PROJ")"
  rm -f "$IDLE" "$IDLE_PROJ" "$PENDING" "$PENDING_PROJ"
}

teardown() {
  rm -rf "$TMP_ROOT"
  rm -f "$IDLE" "$IDLE_PROJ" "$PENDING" "$PENDING_PROJ"
  unset SHOGUN_ROLE SHOGUN_PROJECT_ID SHOGUN_ROOT
}

# 注: @test 名は ASCII（英語）で記述する。macOS 標準の bash 3.2 では bats が
# マルチバイトのテスト名を関数名へエンコードできず "unknown test name" となり実行されないため。
@test "stop_hook: creates the idle flag" {
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [ -f "$IDLE" ]
}

@test "stop_hook: creates a project-specific flag when SHOGUN_PROJECT_ID is set" {
  SHOGUN_ROLE="$ROLE" SHOGUN_PROJECT_ID="$PROJ" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [ -f "$IDLE_PROJ" ]
  [ ! -f "$IDLE" ]
}

@test "stop_hook: exits 0 with no output when SHOGUN_ROLE is unset" {
  unset SHOGUN_ROLE
  run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stop_hook: does nothing for a path-traversal SHOGUN_ROLE" {
  SHOGUN_ROLE="../evil" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "/tmp/shogun_idle_../evil" ]
}

@test "stop_hook: does nothing for a path-traversal SHOGUN_PROJECT_ID" {
  SHOGUN_ROLE="$ROLE" SHOGUN_PROJECT_ID="../../evil" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # 不正な project_id ではフラグ名・inbox パスへ展開せず、何も作らない
  [ ! -f "$IDLE" ]
  [ ! -f "$IDLE_PROJ" ]
}

@test "stop_hook: prints a message when the inbox has unread messages" {
  mkdir -p "${SHOGUN_ROOT}/.shogun/queue/inbox"
  cat > "${SHOGUN_ROOT}/.shogun/queue/inbox/${ROLE}.yaml" <<'YAML'
messages:
  - status: unread
    subject: test-unread
YAML
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  # 未読があれば通知メッセージが stdout に出る（出力が非空であることで検証）
  [ -n "$output" ]
  [ -f "$IDLE" ]
}

@test "stop_hook: prints nothing when the inbox has no unread messages" {
  mkdir -p "${SHOGUN_ROOT}/.shogun/queue/inbox"
  cat > "${SHOGUN_ROOT}/.shogun/queue/inbox/${ROLE}.yaml" <<'YAML'
messages:
  - status: read
    subject: already-read
YAML
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$IDLE" ]
}

@test "stop_hook: exits safely and still creates the flag when the inbox file is missing" {
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$IDLE" ]
}

# ────────────────────────────────────────────────────────────
# reports 安全網: inbox_watcher が busy 中にスキップした report 通知を
# idle 復帰時（Stop フック）に再提示し、pending マーカーを消費する。
# ────────────────────────────────────────────────────────────

@test "stop_hook: re-notifies and clears the reports pending marker" {
  touch "$PENDING"
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  # reports の再通知メッセージが stdout に出る
  [[ "$output" == *"reports"* ]]
  # 消費済みマーカーは削除されている（次ターンで再提示しない）
  [ ! -f "$PENDING" ]
}

@test "stop_hook: consumes a project-specific reports pending marker" {
  touch "$PENDING_PROJ"
  SHOGUN_ROLE="$ROLE" SHOGUN_PROJECT_ID="$PROJ" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reports"* ]]
  [ ! -f "$PENDING_PROJ" ]
}

@test "stop_hook: prints nothing about reports when there is no pending marker" {
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"reports"* ]]
}

# ────────────────────────────────────────────────────────────
# decision:block 強制継続（issue #55）
# ────────────────────────────────────────────────────────────

@test "stop_hook: outputs decision block JSON when inbox has unread and stop_hook_active is false" {
  mkdir -p "${SHOGUN_ROOT}/.shogun/queue/inbox"
  cat > "${SHOGUN_ROOT}/.shogun/queue/inbox/${ROLE}.yaml" <<'YAML'
messages:
  - status: unread
    subject: test-unread
YAML
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/stop_hook.sh" <<< '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"decision":"block"'* ]]
  [ -f "$IDLE" ]
}

@test "stop_hook: does not block when stop_hook_active is true" {
  mkdir -p "${SHOGUN_ROOT}/.shogun/queue/inbox"
  cat > "${SHOGUN_ROOT}/.shogun/queue/inbox/${ROLE}.yaml" <<'YAML'
messages:
  - status: unread
    subject: test-unread
YAML
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/stop_hook.sh" <<< '{"stop_hook_active":true}'
  [ "$status" -eq 0 ]
  [[ "$output" != *'"decision"'* ]]
  [ -f "$IDLE" ]
}

@test "stop_hook: does not block when inbox has no unread (stop_hook_active false)" {
  mkdir -p "${SHOGUN_ROOT}/.shogun/queue/inbox"
  cat > "${SHOGUN_ROOT}/.shogun/queue/inbox/${ROLE}.yaml" <<'YAML'
messages:
  - status: read
    subject: already-read
YAML
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/stop_hook.sh" <<< '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [[ "$output" != *'"decision"'* ]]
}
