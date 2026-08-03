#!/usr/bin/env bats
# Unit tests for scripts/agmsg_adapter.sh

load '../test_helper'

setup() {
  source "${SHOGUN_REPO}/scripts/agmsg_adapter.sh"
  export AGMSG_TEST_HOME="$(mktemp -d)"
  export AGMSG_HOME_OVERRIDE="${AGMSG_TEST_HOME}"
}

teardown() {
  rm -rf "${AGMSG_TEST_HOME}"
}

@test "agmsg_adapter: _agmsg_home honors AGMSG_HOME_OVERRIDE" {
  run _agmsg_home "mycmd"
  [ "$status" -eq 0 ]
  [ "$output" = "${AGMSG_TEST_HOME}" ]
}

@test "agmsg_adapter: agmsg_version reads the VERSION file" {
  echo "v1.1.12-3-g1c7efbc" > "${AGMSG_TEST_HOME}/VERSION"
  run agmsg_version "mycmd"
  [ "$status" -eq 0 ]
  [ "$output" = "v1.1.12-3-g1c7efbc" ]
}

@test "agmsg_adapter: agmsg_version returns 'unknown' when VERSION is missing" {
  run agmsg_version "mycmd"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "agmsg_adapter: agmsg_version_ok succeeds for v1.1.12 prefix" {
  echo "v1.1.12" > "${AGMSG_TEST_HOME}/VERSION"
  run agmsg_version_ok "mycmd"
  [ "$status" -eq 0 ]
}

@test "agmsg_adapter: agmsg_version_ok succeeds for v1.1.12-N-g<sha> variant" {
  echo "v1.1.12-3-g1c7efbc" > "${AGMSG_TEST_HOME}/VERSION"
  run agmsg_version_ok "mycmd"
  [ "$status" -eq 0 ]
}

@test "agmsg_adapter: agmsg_version_ok fails for a mismatched version" {
  echo "v2.0.0" > "${AGMSG_TEST_HOME}/VERSION"
  run agmsg_version_ok "mycmd"
  [ "$status" -eq 1 ]
}

# --- pass-through wrapper functions ---
# 各委譲先スクリプトを fake 実装に差し替え、渡された引数をそのまま echo する。

_fake_agmsg_script() {
  local name="$1"
  mkdir -p "${AGMSG_TEST_HOME}/scripts"
  cat > "${AGMSG_TEST_HOME}/scripts/${name}" <<'FAKE'
#!/usr/bin/env bash
echo "${0##*/} $*"
FAKE
  chmod +x "${AGMSG_TEST_HOME}/scripts/${name}"
}

@test "agmsg_adapter: agmsg_send delegates to send.sh with all args" {
  _fake_agmsg_script "send.sh"
  run agmsg_send "mycmd" "team1" "karo" "taisho" "done"
  [ "$status" -eq 0 ]
  [ "$output" = "send.sh team1 karo taisho done" ]
}

@test "agmsg_adapter: agmsg_join delegates to join.sh with all args" {
  _fake_agmsg_script "join.sh"
  run agmsg_join "mycmd" "team1" "taisho" "claude-code" "/proj"
  [ "$output" = "join.sh team1 taisho claude-code /proj" ]
}

@test "agmsg_adapter: agmsg_set_delivery delegates to delivery.sh with all args" {
  _fake_agmsg_script "delivery.sh"
  run agmsg_set_delivery "mycmd" set monitor claude-code /proj
  [ "$output" = "delivery.sh set monitor claude-code /proj" ]
}

@test "agmsg_adapter: agmsg_spawn delegates to spawn.sh with all args" {
  _fake_agmsg_script "spawn.sh"
  run agmsg_spawn "mycmd" claude-code karo --model sonnet --fresh
  [ "$output" = "spawn.sh claude-code karo --model sonnet --fresh" ]
}

@test "agmsg_adapter: agmsg_despawn delegates to despawn.sh with all args" {
  _fake_agmsg_script "despawn.sh"
  run agmsg_despawn "mycmd" team1 karo ashigaru1 --force
  [ "$output" = "despawn.sh team1 karo ashigaru1 --force" ]
}

@test "agmsg_adapter: agmsg_inbox delegates to inbox.sh with all args" {
  _fake_agmsg_script "inbox.sh"
  run agmsg_inbox "mycmd" team1 karo
  [ "$output" = "inbox.sh team1 karo" ]
}

@test "agmsg_adapter: agmsg_history delegates to history.sh with all args" {
  _fake_agmsg_script "history.sh"
  run agmsg_history "mycmd" team1 --limit 20
  [ "$output" = "history.sh team1 --limit 20" ]
}
