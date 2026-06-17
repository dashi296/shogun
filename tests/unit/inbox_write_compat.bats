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

@test "inbox_write compat: rejects SHOGUN_ROOT pointing to .shogun dir" {
  local shogun_dir="${TMP_ROOT}/.shogun"
  mkdir -p "$shogun_dir"
  SHOGUN_ROOT="$shogun_dir" run bash "${SHOGUN_REPO}/scripts/inbox_write.sh" taisho "subject"
  [ "$status" -ne 0 ]
  [[ "$output" =~ ".shogun" ]]
}

@test "cli.js inbox_list: rejects path-traversal project-id" {
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_list "--root=${TMP_ROOT}" "--role=taisho" "--project-id=../../evil"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid project-id" ]]
}

@test "cli.js inbox_send: rejects path-traversal --from role" {
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_send "--root=${TMP_ROOT}" "--from=../evil" "--to=taisho" "--subject=x"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid --from" ]]
}

@test "cli.js inbox_send: rejects path-traversal --to role" {
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_send "--root=${TMP_ROOT}" "--from=karo" "--to=../evil" "--subject=x"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid --to" ]]
}

@test "cli.js inbox_send: rejects --to with spaces" {
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_send "--root=${TMP_ROOT}" "--from=karo" "--to=bad role" "--subject=x"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid --to" ]]
}

@test "cli.js inbox_unread_count: rejects path-traversal --role" {
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_unread_count "--root=${TMP_ROOT}" "--role=../evil"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid --role" ]]
}

@test "cli.js inbox_list: rejects path-traversal --role" {
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_list "--root=${TMP_ROOT}" "--role=../evil"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid --role" ]]
}

# ────────────────────────────────────────────────────────────
# inbox_max_unread_id: 最大未読 message ID を返す（wake デバウンス用）
# ────────────────────────────────────────────────────────────

@test "cli.js inbox_max_unread_id: returns 0 when inbox is empty" {
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_max_unread_id "--root=${TMP_ROOT}" "--role=taisho"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "cli.js inbox_max_unread_id: returns max id of unread messages" {
  node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_send "--root=${TMP_ROOT}" "--from=karo" "--to=taisho" "--subject=first"
  local id2
  id2="$(node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_send "--root=${TMP_ROOT}" "--from=karo" "--to=taisho" "--subject=second")"

  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_max_unread_id "--root=${TMP_ROOT}" "--role=taisho"
  [ "$status" -eq 0 ]
  [ "$output" = "$id2" ]
}

@test "cli.js inbox_max_unread_id: changes when new message arrives after same-count read (race scenario)" {
  # 旧 msg(id1) 送信・通知済み → 既読化 → 新 msg(id2) 到着の場合に max_id が変わること
  local id1
  id1="$(node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_send "--root=${TMP_ROOT}" "--from=karo" "--to=taisho" "--subject=old-msg")"

  # 旧メッセージを既読化（MCP の inbox_mark_read に相当）
  node -e "
    const { openDb, initSchema, markRead } = require('${SHOGUN_REPO}/packages/mcp-queue/src/db.js');
    const path = require('path');
    const dbPath = path.join('${TMP_ROOT}', '.shogun', 'queue', 'queue.db');
    const db = openDb(dbPath); initSchema(db);
    markRead(db, [${id1}], new Date().toISOString(), 'taisho', '');
    db.close();
  "

  # 新メッセージ到着
  local id2
  id2="$(node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_send "--root=${TMP_ROOT}" "--from=karo" "--to=taisho" "--subject=new-msg")"

  # max_id は新メッセージの id2 になり、count ベースでは両方 1 件でも検出できる
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_max_unread_id "--root=${TMP_ROOT}" "--role=taisho"
  [ "$output" = "$id2" ]
  [ "$id2" -gt "$id1" ]
}

@test "cli.js inbox_max_unread_id: rejects path-traversal --role" {
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_max_unread_id "--root=${TMP_ROOT}" "--role=../evil"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid --role" ]]
}

# ────────────────────────────────────────────────────────────
# migrate_yaml_inbox: YAML 形式 inbox を SQLite へ移行
# ────────────────────────────────────────────────────────────

@test "cli.js migrate_yaml_inbox: migrates unread YAML messages to SQLite" {
  local inbox_dir="${TMP_ROOT}/.shogun/queue/inbox"
  mkdir -p "$inbox_dir"
  cat > "${inbox_dir}/karo.yaml" <<'YAML'
messages:
  - id: msg_20240101120000_1
    from: taisho
    timestamp: "2024-01-01T12:00:00Z"
    subject: "legacy task"
    body: "urgent"
    status: unread
YAML

  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    migrate_yaml_inbox "--root=${TMP_ROOT}"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  # SQLite に移行されていること
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_unread_count "--root=${TMP_ROOT}" "--role=karo"
  [ "$output" = "1" ]
}

@test "cli.js migrate_yaml_inbox: clears YAML after migration (idempotent)" {
  local inbox_dir="${TMP_ROOT}/.shogun/queue/inbox"
  mkdir -p "$inbox_dir"
  cat > "${inbox_dir}/karo.yaml" <<'YAML'
messages:
  - id: msg_20240101120000_1
    from: taisho
    timestamp: "2024-01-01T12:00:00Z"
    subject: "legacy task"
    body: ""
    status: unread
YAML

  node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" migrate_yaml_inbox "--root=${TMP_ROOT}"

  # 2 回目の移行でメッセージが重複しないこと
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    migrate_yaml_inbox "--root=${TMP_ROOT}"
  [ "$output" = "0" ]

  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_unread_count "--root=${TMP_ROOT}" "--role=karo"
  [ "$output" = "1" ]
}

@test "cli.js migrate_yaml_inbox: skips already-read messages in YAML" {
  local inbox_dir="${TMP_ROOT}/.shogun/queue/inbox"
  mkdir -p "$inbox_dir"
  cat > "${inbox_dir}/karo.yaml" <<'YAML'
messages:
  - id: msg_001
    from: taisho
    timestamp: "2024-01-01T12:00:00Z"
    subject: "already read"
    body: ""
    status: read
YAML

  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    migrate_yaml_inbox "--root=${TMP_ROOT}"
  [ "$output" = "0" ]

  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_unread_count "--root=${TMP_ROOT}" "--role=karo"
  [ "$output" = "0" ]
}

@test "cli.js migrate_yaml_inbox: migrates project-specific inbox YAML" {
  local proj_inbox="${TMP_ROOT}/.shogun/queue/projects/myproject/inbox"
  mkdir -p "$proj_inbox"
  cat > "${proj_inbox}/karo.yaml" <<'YAML'
messages:
  - id: msg_proj_001
    from: taisho
    timestamp: "2024-01-01T12:00:00Z"
    subject: "project task"
    body: ""
    status: unread
YAML

  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    migrate_yaml_inbox "--root=${TMP_ROOT}"
  [ "$output" = "1" ]

  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_unread_count "--root=${TMP_ROOT}" "--role=karo" "--project-id=myproject"
  [ "$output" = "1" ]
}

@test "cli.js migrate_yaml_inbox: returns 0 when no inbox directory exists" {
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    migrate_yaml_inbox "--root=${TMP_ROOT}"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}
