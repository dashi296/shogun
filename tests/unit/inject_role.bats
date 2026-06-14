#!/usr/bin/env bats
# Unit tests for scripts/inject_role.sh (SessionStart フック: 役職コンテキスト注入)

load '../test_helper'

setup() {
  TEST_PROJECT="$(mktemp -d)"
  export TEST_PROJECT
  export SHOGUN_ROOT="${TEST_PROJECT}"
  mkdir -p "${TEST_PROJECT}/.shogun/instructions"
  # マーカー入りのフィクスチャを用意
  printf '# Shogun 共通設定\nSHOGUN_COMMON_MARKER\n' > "${TEST_PROJECT}/.shogun/CLAUDE.md"
  printf '# Taisho（大将）\nTAISHO_ROLE_MARKER\n'        > "${TEST_PROJECT}/.shogun/instructions/taisho.md"
  printf '# Ashigaru（足軽）\nASHIGARU_ROLE_MARKER\n'    > "${TEST_PROJECT}/.shogun/instructions/ashigaru.md"
}

teardown() {
  teardown_test_project
}

# additionalContext を取り出すヘルパー
_additional_context() {
  node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
process.stdout.write(d.hookSpecificOutput.additionalContext);
'
}

# --- happy path ---

@test "inject_role: exits 0 for a valid role" {
  export SHOGUN_ROLE="taisho"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  [ "$status" -eq 0 ]
}

@test "inject_role: outputs valid SessionStart hook JSON" {
  export SHOGUN_ROLE="taisho"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  echo "$output" | node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
if (d.hookSpecificOutput.hookEventName !== "SessionStart") process.exit(1);
'
}

@test "inject_role: additionalContext states the role id" {
  export SHOGUN_ROLE="taisho"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  ctx="$(echo "$output" | _additional_context)"
  [[ "$ctx" == *"taisho"* ]]
}

@test "inject_role: additionalContext includes the role instructions" {
  export SHOGUN_ROLE="taisho"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  ctx="$(echo "$output" | _additional_context)"
  [[ "$ctx" == *"TAISHO_ROLE_MARKER"* ]]
}

# --- idle フラグ（コールドスタート対応） ---
# 起動直後はプロンプト待ち = idle なので idle フラグを立てる。
# これにより最初のタスク通知が wake ゲートで skip されない。
# busy 化はターン開始時の mark_busy.sh（UserPromptSubmit）が担う。

@test "inject_role: sets the idle flag" {
  local role="injidletest_$$"
  rm -f "/tmp/shogun_idle_${role}"
  export SHOGUN_ROLE="$role"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  [ "$status" -eq 0 ]
  [ -f "/tmp/shogun_idle_${role}" ]
  rm -f "/tmp/shogun_idle_${role}"
}

@test "inject_role: sets a project-specific idle flag when SHOGUN_PROJECT_ID is set" {
  local role="injidletest_$$" proj="injidleproj_$$"
  rm -f "/tmp/shogun_idle_${proj}_${role}" "/tmp/shogun_idle_${role}"
  export SHOGUN_ROLE="$role" SHOGUN_PROJECT_ID="$proj"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  [ "$status" -eq 0 ]
  [ -f "/tmp/shogun_idle_${proj}_${role}" ]
  [ ! -f "/tmp/shogun_idle_${role}" ]
  rm -f "/tmp/shogun_idle_${proj}_${role}"
}

# --- source=compact では idle フラグを操作しない（busy 中の出力破損を防ぐ） ---
# compact 継続ターンでは UserPromptSubmit(mark_busy) が走らず、ここで idle フラグを
# 立てると作業中(busy)のまま idle と誤判定され、busy ペインへの send-keys 注入が再発する。
# そのため source=compact では touch せず、直前の busy/idle 状態を維持する。

@test "inject_role: does NOT set the idle flag when source=compact (busy preserved)" {
  local role="injcompacttest_$$"
  rm -f "/tmp/shogun_idle_${role}"          # busy 状態を模す（フラグ無し）
  export SHOGUN_ROLE="$role"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh" <<<'{"source":"compact"}'
  [ "$status" -eq 0 ]
  # compact では idle フラグを立てない（busy のまま）
  [ ! -f "/tmp/shogun_idle_${role}" ]
  rm -f "/tmp/shogun_idle_${role}"
}

@test "inject_role: still injects role context when source=compact" {
  export SHOGUN_ROLE="taisho"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh" <<<'{"source":"compact"}'
  [ "$status" -eq 0 ]
  # compact でも役職コンテキストの注入は従来どおり行う
  ctx="$(echo "$output" | _additional_context)"
  [[ "$ctx" == *"TAISHO_ROLE_MARKER"* ]]
}

@test "inject_role: keeps an existing idle flag during compact (idle preserved)" {
  local role="injcompacttest_$$"
  touch "/tmp/shogun_idle_${role}"          # 直前は idle
  export SHOGUN_ROLE="$role"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh" <<<'{"source":"compact"}'
  [ "$status" -eq 0 ]
  # compact ではフラグに触れず idle を維持する
  [ -f "/tmp/shogun_idle_${role}" ]
  rm -f "/tmp/shogun_idle_${role}"
}

@test "inject_role: sets the idle flag when source=startup" {
  local role="injstartuptest_$$"
  rm -f "/tmp/shogun_idle_${role}"
  export SHOGUN_ROLE="$role"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh" <<<'{"source":"startup"}'
  [ "$status" -eq 0 ]
  [ -f "/tmp/shogun_idle_${role}" ]
  rm -f "/tmp/shogun_idle_${role}"
}

@test "inject_role: does NOT set a project-specific idle flag when source=compact" {
  local role="injcompacttest_$$" proj="injcompactproj_$$"
  rm -f "/tmp/shogun_idle_${proj}_${role}"
  export SHOGUN_ROLE="$role" SHOGUN_PROJECT_ID="$proj"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh" <<<'{"source":"compact"}'
  [ "$status" -eq 0 ]
  [ ! -f "/tmp/shogun_idle_${proj}_${role}" ]
  rm -f "/tmp/shogun_idle_${proj}_${role}"
}

@test "inject_role: additionalContext includes the common CLAUDE.md" {
  export SHOGUN_ROLE="taisho"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  ctx="$(echo "$output" | _additional_context)"
  [[ "$ctx" == *"SHOGUN_COMMON_MARKER"* ]]
}

# --- numbered ashigaru ---

@test "inject_role: ashigaru1 resolves to ashigaru.md instructions" {
  export SHOGUN_ROLE="ashigaru1"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  ctx="$(echo "$output" | _additional_context)"
  [[ "$ctx" == *"ASHIGARU_ROLE_MARKER"* ]]
}

@test "inject_role: ashigaru2 keeps its numbered id in the context" {
  export SHOGUN_ROLE="ashigaru2"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  ctx="$(echo "$output" | _additional_context)"
  [[ "$ctx" == *"ashigaru2"* ]]
}

# --- graceful degradation / security ---

@test "inject_role: emits nothing when SHOGUN_ROLE is empty" {
  export SHOGUN_ROLE=""
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "inject_role: emits nothing when SHOGUN_ROLE is unset" {
  unset SHOGUN_ROLE
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "inject_role: rejects path-traversal role without emitting context" {
  export SHOGUN_ROLE="../../etc/passwd"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "inject_role: rejects role containing a slash" {
  export SHOGUN_ROLE="foo/bar"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "inject_role: still emits valid JSON when the instructions file is missing" {
  export SHOGUN_ROLE="gunshi"   # フィクスチャに gunshi.md は無い
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  [ "$status" -eq 0 ]
  echo "$output" | node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
if (d.hookSpecificOutput.hookEventName !== "SessionStart") process.exit(1);
if (!String(d.hookSpecificOutput.additionalContext).includes("gunshi")) process.exit(1);
'
}

# --- フック登録コマンド（settings.json 内）の安全性 ---
# shogun start 経由でない通常の claude セッションでは SHOGUN_BIN_DIR が未設定。
# その場合でもフックがエラーにならず no-op することを保証する。

# テンプレートの SessionStart コマンド文字列を取り出す
_hook_command() {
  node -e '
const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const h = d.hooks.SessionStart.flatMap(e => e.hooks || []).find(h => /inject_role/.test(h.command));
process.stdout.write(h.command);
' "${SHOGUN_REPO}/templates/.claude/settings.json"
}

@test "hook command: no-ops (exit 0, no output) when SHOGUN_BIN_DIR is unset" {
  local cmd
  cmd="$(_hook_command)"
  run env -u SHOGUN_BIN_DIR -u SHOGUN_ROLE bash -c "$cmd"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook command: runs the script when SHOGUN_BIN_DIR is set" {
  local cmd
  cmd="$(_hook_command)"
  # setup で作成した .shogun フィクスチャを CLAUDE_PROJECT_DIR として使う
  run env SHOGUN_BIN_DIR="${SHOGUN_REPO}" SHOGUN_ROLE="taisho" \
      SHOGUN_ROOT="${TEST_PROJECT}" CLAUDE_PROJECT_DIR="${TEST_PROJECT}" \
      bash -c "$cmd"
  [ "$status" -eq 0 ]
  echo "$output" | node -e '
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
if (d.hookSpecificOutput.hookEventName !== "SessionStart") process.exit(1);
if (!String(d.hookSpecificOutput.additionalContext).includes("TAISHO_ROLE_MARKER")) process.exit(1);
'
}

# --- persona.sengoku / config.yaml 解決 ---

@test "inject_role: persona.sengoku=true expands {{ persona.sengoku }} to true" {
  mkdir -p "${TEST_PROJECT}/.shogun"
  printf 'persona:\n  sengoku: true\n' > "${TEST_PROJECT}/.shogun/config.yaml"
  printf '{{ persona.sengoku }}\n' >> "${TEST_PROJECT}/.shogun/instructions/taisho.md"
  export SHOGUN_ROLE="taisho"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  [ "$status" -eq 0 ]
  ctx="$(echo "$output" | _additional_context)"
  # placeholder が消えていることを主に確認（"true" は委任原則内 "while true" でも出現するため否定で検査）
  [[ "$ctx" != *"{{ persona.sengoku }}"* ]]
  # instructions ファイルに書いた placeholder が "true" に置換されたことを行単位で確認
  echo "$ctx" | grep -qF 'sengoku: true' || [[ $'\n'"$ctx"$'\n' == *$'\n'"true"$'\n'* ]]
}

@test "inject_role: persona.sengoku=false expands {{ persona.sengoku }} to false" {
  mkdir -p "${TEST_PROJECT}/.shogun"
  printf 'persona:\n  sengoku: false\n' > "${TEST_PROJECT}/.shogun/config.yaml"
  printf '{{ persona.sengoku }}\n' >> "${TEST_PROJECT}/.shogun/instructions/taisho.md"
  export SHOGUN_ROLE="taisho"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  [ "$status" -eq 0 ]
  ctx="$(echo "$output" | _additional_context)"
  [[ "$ctx" != *"{{ persona.sengoku }}"* ]]
  [[ $'\n'"$ctx"$'\n' == *$'\n'"false"$'\n'* ]]
}

@test "inject_role: missing config.yaml expands {{ persona.sengoku }} to false" {
  printf '{{ persona.sengoku }}\n' >> "${TEST_PROJECT}/.shogun/instructions/taisho.md"
  export SHOGUN_ROLE="taisho"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  [ "$status" -eq 0 ]
  ctx="$(echo "$output" | _additional_context)"
  [[ "$ctx" == *"false"* ]]
  [[ "$ctx" != *"{{ persona.sengoku }}"* ]]
}

@test "inject_role: invalid YAML in config.yaml falls back to false and exits 0" {
  mkdir -p "${TEST_PROJECT}/.shogun"
  printf 'this: is: invalid: yaml: {{\n' > "${TEST_PROJECT}/.shogun/config.yaml"
  # placeholder を含む instructions を配置して false への置換を確認する
  printf '{{ persona.sengoku }}\n' >> "${TEST_PROJECT}/.shogun/instructions/taisho.md"
  export SHOGUN_ROLE="taisho"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  [ "$status" -eq 0 ]
  ctx="$(echo "$output" | _additional_context)"
  [[ "$ctx" == *"false"* ]]
}

@test "inject_role: persona.sengoku=true adds sengoku-enabled line to HEADER" {
  mkdir -p "${TEST_PROJECT}/.shogun"
  printf 'persona:\n  sengoku: true\n' > "${TEST_PROJECT}/.shogun/config.yaml"
  export SHOGUN_ROLE="taisho"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  [ "$status" -eq 0 ]
  ctx="$(echo "$output" | _additional_context)"
  [[ "$ctx" == *"口調設定"* ]]
  [[ "$ctx" == *"有効"* ]]
}

@test "inject_role: persona.sengoku=false adds normal-tone line to HEADER" {
  mkdir -p "${TEST_PROJECT}/.shogun"
  printf 'persona:\n  sengoku: false\n' > "${TEST_PROJECT}/.shogun/config.yaml"
  export SHOGUN_ROLE="taisho"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  [ "$status" -eq 0 ]
  ctx="$(echo "$output" | _additional_context)"
  [[ "$ctx" == *"口調設定"* ]]
  [[ "$ctx" == *"無効"* ]]
}

@test "inject_role: HEADER includes delegation principle (self_execute_task forbidden)" {
  export SHOGUN_ROLE="taisho"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  [ "$status" -eq 0 ]
  ctx="$(echo "$output" | _additional_context)"
  [[ "$ctx" == *"self_execute_task"* ]]
}

@test "inject_role: ashigaru role does NOT get delegation principle in HEADER" {
  export SHOGUN_ROLE="ashigaru1"
  run bash "${SHOGUN_REPO}/scripts/inject_role.sh"
  [ "$status" -eq 0 ]
  ctx="$(echo "$output" | _additional_context)"
  [[ "$ctx" != *"self_execute_task"* ]]
}
