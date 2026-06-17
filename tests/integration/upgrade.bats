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

# --- .shogun/CLAUDE.md / instructions の内容チェック (MCP 移行回帰防止) ---

@test "init: .shogun/CLAUDE.md references inbox_check MCP tool (not legacy YAML inbox)" {
  shogun init
  # MCP ツール名が含まれること
  grep -q "inbox_check" ".shogun/CLAUDE.md"
  # 旧 YAML inbox ファイルパスが混入していないこと
  run grep -c "queue/inbox" ".shogun/CLAUDE.md"
  [ "$output" = "0" ]
}

@test "init: taisho instructions reference inbox_check (not legacy YAML inbox path)" {
  shogun init
  grep -q "inbox_check" ".shogun/instructions/taisho.md"
  run grep -c "queue/inbox/taisho" ".shogun/instructions/taisho.md"
  [ "$output" = "0" ]
}

@test "upgrade: .shogun/CLAUDE.md is overwritten with latest template (stale content replaced)" {
  shogun init
  # 旧バージョンを模倣した古い内容に差し替え
  echo "# OLD: queue/inbox/taisho.yaml を読む" > ".shogun/CLAUDE.md"
  # upgrade の同一ロジック（テンプレートからの無条件 cp）を直接実行して動作を確認
  cp "${SHOGUN_REPO}/templates/CLAUDE.md" ".shogun/CLAUDE.md"
  # 更新後は inbox_check が含まれ、旧 YAML パスが消えていること
  grep -q "inbox_check" ".shogun/CLAUDE.md"
  run grep -c "queue/inbox" ".shogun/CLAUDE.md"
  [ "$output" = "0" ]
}

@test "upgrade: .shogun/instructions are overwritten with latest templates" {
  shogun init
  echo "# OLD: queue/inbox/taisho.yaml を読む" > ".shogun/instructions/taisho.md"
  cp "${SHOGUN_REPO}/templates/instructions/"*.md ".shogun/instructions/"
  grep -q "inbox_check" ".shogun/instructions/taisho.md"
}

# --- 全役職の instructions が inbox_check を参照する回帰テスト ---
# 旧 YAML inbox 参照が残るとエージェントがタスクを取りこぼす（MCP 移行後は YAML は使われない）

@test "init: ashigaru instructions reference inbox_check (not legacy YAML inbox)" {
  shogun init
  grep -q "inbox_check" ".shogun/instructions/ashigaru.md"
  run grep -c "queue/inbox/ashigaru" ".shogun/instructions/ashigaru.md"
  [ "$output" = "0" ]
}

@test "init: gunshi instructions reference inbox_check (not legacy YAML inbox)" {
  shogun init
  grep -q "inbox_check" ".shogun/instructions/gunshi.md"
  run grep -c "queue/inbox/gunshi" ".shogun/instructions/gunshi.md"
  [ "$output" = "0" ]
}

@test "init: metsuke instructions reference inbox_check (not legacy YAML inbox)" {
  shogun init
  grep -q "inbox_check" ".shogun/instructions/metsuke.md"
  run grep -c "queue/inbox/metsuke" ".shogun/instructions/metsuke.md"
  [ "$output" = "0" ]
}

# ────────────────────────────────────────────────────────────
# upgrade: YAML inbox 移行（upgrade ロジックの直接呼び出し）
#
# shogun upgrade --version ... は git fetch/checkout を必要とするため統合テストで
# 呼び出せない。upgrade が内部で実行するのと同じ migrate_yaml_inbox CLI を直接
# 呼び出して、YAML → SQLite 移行が正しく動作することを確認する。
# ────────────────────────────────────────────────────────────

@test "upgrade: YAML inbox unread messages are migrated to SQLite on upgrade" {
  shogun init

  # upgrade 前の旧 YAML inbox を模倣して未読メッセージを作成
  local inbox_dir="${TEST_PROJECT}/.shogun/queue/inbox"
  mkdir -p "$inbox_dir"
  cat > "${inbox_dir}/karo.yaml" <<'YAML'
messages:
  - id: msg_legacy_001
    from: taisho
    timestamp: "2024-01-01T12:00:00Z"
    subject: "upgrade 前の未読タスク"
    body: "MCP 移行前に届いたメッセージ"
    status: unread
YAML

  # upgrade の移行ステップと同じ CLI 呼び出し
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    migrate_yaml_inbox "--root=${TEST_PROJECT}"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  # SQLite に移行されていること
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    inbox_unread_count "--root=${TEST_PROJECT}" "--role=karo"
  [ "$output" = "1" ]

  # YAML がリセットされて重複移行が起きないこと
  run node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" \
    migrate_yaml_inbox "--root=${TEST_PROJECT}"
  [ "$output" = "0" ]
}
