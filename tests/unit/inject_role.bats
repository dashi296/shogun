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
