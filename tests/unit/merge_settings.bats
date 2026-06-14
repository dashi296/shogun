#!/usr/bin/env bats
# bin/shogun の _merge_claude_settings 関数のユニットテスト
#
# init / upgrade が共有する settings.json マージ処理を関数として切り出し、
# 「既存プロジェクトの upgrade でも新フック（mark_busy 等）が追加される」ことを検証する。
# bin/shogun は source ガードでディスパッチをスキップするため、関数だけ読み込める。

load '../test_helper'

setup() {
  # 関数定義のみ読み込む（末尾の source ガードでディスパッチはスキップされる）
  source "${SHOGUN_REPO}/bin/shogun"
  TMP="$(mktemp -d)"
  SRC="${SHOGUN_REPO}/templates/.claude/settings.json"
  DEST="${TMP}/settings.json"
}

teardown() {
  rm -rf "$TMP"
}

# 指定イベントに指定スクリプトを呼ぶフックの登録個数を返す
_hook_count() {
  local file="$1" event="$2" script="$3"
  node -e '
const [file, event, script] = process.argv.slice(1);
const d = JSON.parse(require("fs").readFileSync(file, "utf8"));
const entries = (d.hooks && d.hooks[event]) || [];
const re = new RegExp(script.replace(/[.]/g, "\\."));
const n = entries.filter(e => (e.hooks || []).some(h => re.test(h.command || ""))).length;
process.stdout.write(String(n));
' -- "$file" "$event" "$script"
}

@test "_merge_claude_settings: adds mark_busy hook to a pre-mark_busy project (P1 regression)" {
  # mark_busy フック導入前のバージョンで init された既存プロジェクトを模す
  cat > "$DEST" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "bash $SHOGUN_BIN_DIR/scripts/inject_role.sh" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash $SHOGUN_BIN_DIR/scripts/stop_hook.sh" } ] }
    ]
  }
}
JSON
  run _merge_claude_settings "$DEST" "$SRC"
  [ "$status" -eq 0 ]
  # upgrade 後は UserPromptSubmit の mark_busy フックが追加されている
  run _hook_count "$DEST" UserPromptSubmit "mark_busy.sh"
  [ "$output" = "1" ]
}

@test "_merge_claude_settings: preserves an existing user hook while merging" {
  cat > "$DEST" <<'JSON'
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "echo USER_STOP_HOOK" } ] }
    ]
  }
}
JSON
  run _merge_claude_settings "$DEST" "$SRC"
  [ "$status" -eq 0 ]
  grep -q "USER_STOP_HOOK" "$DEST"
  run _hook_count "$DEST" Stop "stop_hook.sh"
  [ "$output" = "1" ]
}

@test "_merge_claude_settings: preserves unrelated top-level keys" {
  echo '{"env":{"FOO":"bar"}}' > "$DEST"
  run _merge_claude_settings "$DEST" "$SRC"
  [ "$status" -eq 0 ]
  run node -e '
const d = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
process.exit(d.env && d.env.FOO === "bar" ? 0 : 1);
' "$DEST"
  [ "$status" -eq 0 ]
}

@test "_merge_claude_settings: is idempotent (no duplicate hooks on re-run)" {
  _merge_claude_settings "$DEST" "$SRC"
  _merge_claude_settings "$DEST" "$SRC"
  run _hook_count "$DEST" UserPromptSubmit "mark_busy.sh"
  [ "$output" = "1" ]
  run _hook_count "$DEST" SessionStart "inject_role.sh"
  [ "$output" = "1" ]
}

@test "_merge_claude_settings: returns 2 for a malformed dest and leaves it untouched" {
  printf 'not json at all' > "$DEST"
  run _merge_claude_settings "$DEST" "$SRC"
  [ "$status" -eq 2 ]
  run cat "$DEST"
  [ "$output" = "not json at all" ]
}

@test "_merge_claude_settings: creates settings from template when dest is absent" {
  rm -f "$DEST"
  run _merge_claude_settings "$DEST" "$SRC"
  [ "$status" -eq 0 ]
  [ -f "$DEST" ]
  run _hook_count "$DEST" UserPromptSubmit "mark_busy.sh"
  [ "$output" = "1" ]
}
