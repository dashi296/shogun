#!/usr/bin/env bash
# stop_hook.sh の bats テスト
# ターン完了時の idle フラグ作成・project_id 分岐・inbox 未読通知を検証する

setup() {
  _SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../scripts" && pwd)"
  TMP_ROOT="$(mktemp -d)"
  export SHOGUN_ROOT="$TMP_ROOT"
  # テスト固有の role 名を使い、/tmp のフラグ衝突を避ける
  ROLE="stophooktest"
  PROJ="stophookproj"
  rm -f "/tmp/shogun_idle_${ROLE}" "/tmp/shogun_idle_${PROJ}_${ROLE}"
}

teardown() {
  rm -rf "$TMP_ROOT"
  rm -f "/tmp/shogun_idle_${ROLE}" "/tmp/shogun_idle_${PROJ}_${ROLE}"
  unset SHOGUN_ROLE SHOGUN_PROJECT_ID
}

# 注: @test 名は ASCII（英語）で記述する。macOS 標準の bash 3.2 では bats が
# マルチバイトのテスト名を関数名へエンコードできず "unknown test name" となり実行されないため。
@test "stop_hook: creates the idle flag" {
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [ -f "/tmp/shogun_idle_${ROLE}" ]
}

@test "stop_hook: creates a project-specific flag when SHOGUN_PROJECT_ID is set" {
  SHOGUN_ROLE="$ROLE" SHOGUN_PROJECT_ID="$PROJ" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [ -f "/tmp/shogun_idle_${PROJ}_${ROLE}" ]
  [ ! -f "/tmp/shogun_idle_${ROLE}" ]
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
  [ -f "/tmp/shogun_idle_${ROLE}" ]
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
  [ -f "/tmp/shogun_idle_${ROLE}" ]
}

@test "stop_hook: exits safely and still creates the flag when the inbox file is missing" {
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "/tmp/shogun_idle_${ROLE}" ]
}
