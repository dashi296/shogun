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

@test "stop_hook: idle フラグが作成される" {
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [ -f "/tmp/shogun_idle_${ROLE}" ]
}

@test "stop_hook: SHOGUN_PROJECT_ID があるときプロジェクト別フラグが作成される" {
  SHOGUN_ROLE="$ROLE" SHOGUN_PROJECT_ID="$PROJ" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [ -f "/tmp/shogun_idle_${PROJ}_${ROLE}" ]
  [ ! -f "/tmp/shogun_idle_${ROLE}" ]
}

@test "stop_hook: SHOGUN_ROLE 未設定なら何もせず正常終了する" {
  unset SHOGUN_ROLE
  run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stop_hook: 不正な SHOGUN_ROLE（パストラバーサル）では何もしない" {
  SHOGUN_ROLE="../evil" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "/tmp/shogun_idle_../evil" ]
}

@test "stop_hook: inbox に未読があればメッセージを出力する" {
  mkdir -p "${SHOGUN_ROOT}/.shogun/queue/inbox"
  cat > "${SHOGUN_ROOT}/.shogun/queue/inbox/${ROLE}.yaml" <<'YAML'
messages:
  - status: unread
    subject: テスト未読
YAML
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"未読"* ]]
  [ -f "/tmp/shogun_idle_${ROLE}" ]
}

@test "stop_hook: inbox に未読がなければメッセージを出力しない" {
  mkdir -p "${SHOGUN_ROOT}/.shogun/queue/inbox"
  cat > "${SHOGUN_ROOT}/.shogun/queue/inbox/${ROLE}.yaml" <<'YAML'
messages:
  - status: read
    subject: 既読のみ
YAML
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "/tmp/shogun_idle_${ROLE}" ]
}

@test "stop_hook: inbox ファイルが無くても安全に終了しフラグは作る" {
  SHOGUN_ROLE="$ROLE" run bash "${_SCRIPT_DIR}/stop_hook.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "/tmp/shogun_idle_${ROLE}" ]
}
