#!/usr/bin/env bats
# inbox_write.sh 互換シムのテスト
# YAML 版の呼び出し形式（to subject [body]）で SQLite に書き込めることを検証する。

load '../test_helper'

setup() {
  TMP_ROOT="$(mktemp -d)"
  export SHOGUN_ROOT="$TMP_ROOT"
  export SHOGUN_BIN_DIR="${SHOGUN_REPO}"
  export SHOGUN_ROLE="karo"
}

teardown() {
  rm -rf "$TMP_ROOT"
  unset SHOGUN_ROOT SHOGUN_BIN_DIR SHOGUN_ROLE SHOGUN_PROJECT_ID
}

@test "inbox_write compat: sends a message to SQLite inbox" {
  run bash "${SHOGUN_REPO}/scripts/inbox_write.sh" taisho "wake-up" "hello"
  [ "$status" -eq 0 ]

  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_unread_count "--root=${TMP_ROOT}" "--role=taisho"
  [ "$output" = "1" ]
}

@test "inbox_write compat: body is optional" {
  run bash "${SHOGUN_REPO}/scripts/inbox_write.sh" karo "subject-only"
  [ "$status" -eq 0 ]

  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_unread_count "--root=${TMP_ROOT}" "--role=karo"
  [ "$output" = "1" ]
}

@test "inbox_write compat: rejects path-traversal to_role" {
  run bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "../evil" "subject"
  [ "$status" -ne 0 ]
}

@test "inbox_write compat: uses SHOGUN_PROJECT_ID when set" {
  export SHOGUN_PROJECT_ID="myproject"
  run bash "${SHOGUN_REPO}/scripts/inbox_write.sh" taisho "proj-wake"
  [ "$status" -eq 0 ]

  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_unread_count "--root=${TMP_ROOT}" "--role=taisho" "--project-id=myproject"
  [ "$output" = "1" ]
}

@test "cli.js: rejects path-traversal project-id in inbox_send" {
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_send "--root=${TMP_ROOT}" "--from=karo" "--to=taisho" \
    "--subject=x" "--project-id=../../evil"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid project-id" ]]
}

@test "cli.js: rejects path-traversal project-id in inbox_unread_count" {
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_unread_count "--root=${TMP_ROOT}" "--role=taisho" "--project-id=../outside"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid project-id" ]]
}

@test "cli.js: accepts valid project-id with alphanumeric and hyphens" {
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_send "--root=${TMP_ROOT}" "--from=karo" "--to=taisho" \
    "--subject=valid" "--project-id=my-project_01"
  [ "$status" -eq 0 ]
}

@test "cli.js inbox_list: shows unread messages with id and subject" {
  node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_send "--root=${TMP_ROOT}" "--from=karo" "--to=taisho" "--subject=hello-list"
  node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_send "--root=${TMP_ROOT}" "--from=karo" "--to=taisho" "--subject=second-msg"

  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_list "--root=${TMP_ROOT}" "--role=taisho"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "未読: 2 件" ]]
  [[ "$output" =~ "hello-list" ]]
  [[ "$output" =~ "second-msg" ]]
  [[ "$output" =~ "from: karo" ]]
}

@test "cli.js inbox_list: shows 0 件 when inbox is empty" {
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_list "--root=${TMP_ROOT}" "--role=taisho"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "未読: 0 件" ]]
}

@test "cli.js inbox_list: rejects path-traversal project-id" {
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_list "--root=${TMP_ROOT}" "--role=taisho" "--project-id=../../evil"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid project-id" ]]
}
