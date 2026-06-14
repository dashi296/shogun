#!/usr/bin/env bats
# Integration tests for shogun init: SessionStart 役職注入フックの配置/マージ

load '../test_helper'

setup() {
  TEST_PROJECT="$(mktemp -d)"
  export TEST_PROJECT
  cd "${TEST_PROJECT}"
}

teardown() {
  teardown_test_project
}

# settings.json の SessionStart に inject_role フックが含まれるか
_has_inject_role_hook() {
  node -e '
const d = JSON.parse(require("fs").readFileSync(".claude/settings.json", "utf8"));
const starts = (d.hooks && d.hooks.SessionStart) || [];
const found = starts.some(e => (e.hooks || []).some(h => /inject_role\.sh/.test(h.command || "")));
process.exit(found ? 0 : 1);
'
}

# 指定イベントに指定スクリプトを呼ぶフックが含まれるか / その登録個数
_hook_count() {
  local event="$1" script="$2"
  node -e '
const [event, script] = process.argv.slice(1);
const d = JSON.parse(require("fs").readFileSync(".claude/settings.json", "utf8"));
const entries = (d.hooks && d.hooks[event]) || [];
const re = new RegExp(script.replace(/[.]/g, "\\."));
const n = entries.filter(e => (e.hooks || []).some(h => re.test(h.command || ""))).length;
process.stdout.write(String(n));
' -- "$event" "$script"
}

@test "init: creates .claude/settings.json" {
  shogun init
  [ -f ".claude/settings.json" ]
}

@test "init: settings.json registers a SessionStart inject_role hook" {
  shogun init
  run _has_inject_role_hook
  [ "$status" -eq 0 ]
}

@test "init: settings.json is valid JSON" {
  shogun init
  run node -e 'JSON.parse(require("fs").readFileSync(".claude/settings.json","utf8"))'
  [ "$status" -eq 0 ]
}

@test "init: settings.json registers a Stop stop_hook hook" {
  shogun init
  run _hook_count Stop "stop_hook.sh"
  [ "$output" = "1" ]
}

@test "init: settings.json registers a UserPromptSubmit mark_busy hook" {
  shogun init
  run _hook_count UserPromptSubmit "mark_busy.sh"
  [ "$output" = "1" ]
}

@test "init: does not duplicate Stop / UserPromptSubmit hooks on re-run" {
  shogun init
  shogun init
  run _hook_count Stop "stop_hook.sh"
  [ "$output" = "1" ]
  run _hook_count UserPromptSubmit "mark_busy.sh"
  [ "$output" = "1" ]
}

@test "init: preserves an existing user Stop hook when merging" {
  mkdir -p .claude
  cat > .claude/settings.json <<'JSON'
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "echo USER_STOP_HOOK" } ] }
    ]
  }
}
JSON
  shogun init

  grep -q "USER_STOP_HOOK" .claude/settings.json
  run _hook_count Stop "stop_hook.sh"
  [ "$output" = "1" ]
}

@test "init: preserves an existing user SessionStart hook when merging" {
  mkdir -p .claude
  cat > .claude/settings.json <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "echo USER_CUSTOM_HOOK" } ] }
    ]
  }
}
JSON
  shogun init

  # ユーザー独自フックが残っている
  grep -q "USER_CUSTOM_HOOK" .claude/settings.json
  # かつ inject_role フックが追加されている
  run _has_inject_role_hook
  [ "$status" -eq 0 ]
}

@test "init: preserves unrelated keys in an existing settings.json" {
  mkdir -p .claude
  echo '{"env":{"FOO":"bar"}}' > .claude/settings.json
  shogun init

  run node -e '
const d = JSON.parse(require("fs").readFileSync(".claude/settings.json","utf8"));
process.exit(d.env && d.env.FOO === "bar" ? 0 : 1);
'
  [ "$status" -eq 0 ]
}

@test "init: does not duplicate the inject_role hook on re-run" {
  shogun init
  shogun init

  run node -e '
const d = JSON.parse(require("fs").readFileSync(".claude/settings.json","utf8"));
const starts = (d.hooks && d.hooks.SessionStart) || [];
const n = starts.filter(e => (e.hooks||[]).some(h => /inject_role\.sh/.test(h.command||""))).length;
process.stdout.write(String(n));
'
  [ "$output" = "1" ]
}

@test "init: leaves a malformed settings.json untouched" {
  mkdir -p .claude
  printf 'not json at all' > .claude/settings.json
  shogun init

  run cat .claude/settings.json
  [ "$output" = "not json at all" ]
}
