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

@test "agmsg_adapter: _agmsg_home rejects a cmd_name with path traversal characters" {
  run _agmsg_home "../../../../tmp/evil"
  [ "$status" -eq 2 ]
}

@test "agmsg_adapter: _agmsg_home rejects a cmd_name with a slash" {
  run _agmsg_home "foo/bar"
  [ "$status" -eq 2 ]
}

@test "agmsg_adapter: _agmsg_home uses HOME when AGMSG_HOME_OVERRIDE is unset" {
  unset AGMSG_HOME_OVERRIDE
  # HOME=... を "source ...; _agmsg_home" の外側の env に渡す必要がある。
  # bash -c 文字列の中で HOME=... source ... と書いても、次のコマンド（_agmsg_home）には
  # 引き継がれない（source は POSIX の特殊組込みではないため、非対話シェルでは
  # 一時環境の代入がコマンド終了後も残らない）。そのため env でプロセス全体の HOME を差し替える。
  run env HOME=/tmp/fake-home bash -c "source '${SHOGUN_REPO}/scripts/agmsg_adapter.sh'; _agmsg_home mycmd"
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/fake-home/.agents/skills/mycmd" ]
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

@test "agmsg_adapter: agmsg_version trims only leading/trailing whitespace, not internal" {
  printf '  v1.1.12  \n' > "${AGMSG_TEST_HOME}/VERSION"
  run agmsg_version "mycmd"
  [ "$output" = "v1.1.12" ]
}

@test "agmsg_adapter: agmsg_version preserves a corrupted internal space (does not silently repair it)" {
  printf 'v1.1. 12\n' > "${AGMSG_TEST_HOME}/VERSION"
  run agmsg_version "mycmd"
  [ "$output" = "v1.1. 12" ]
}

@test "agmsg_adapter: agmsg_version_ok rejects a version with an internal space" {
  printf 'v1.1. 12\n' > "${AGMSG_TEST_HOME}/VERSION"
  run agmsg_version_ok "mycmd"
  [ "$status" -eq 1 ]
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

@test "agmsg_adapter: agmsg_version_ok rejects a version with an unrelated numeric suffix" {
  echo "v1.1.120" > "${AGMSG_TEST_HOME}/VERSION"
  run agmsg_version_ok "mycmd"
  [ "$status" -eq 1 ]
}

@test "agmsg_adapter: agmsg_version_ok rejects a version with a trailing letter" {
  echo "v1.1.12x" > "${AGMSG_TEST_HOME}/VERSION"
  run agmsg_version_ok "mycmd"
  [ "$status" -eq 1 ]
}

@test "agmsg_adapter: agmsg_version_ok rejects a non-git-describe suffix" {
  echo "v1.1.12-foo" > "${AGMSG_TEST_HOME}/VERSION"
  run agmsg_version_ok "mycmd"
  [ "$status" -eq 1 ]
}

@test "agmsg_adapter: agmsg_version_ok rejects a bare trailing dash" {
  echo "v1.1.12-" > "${AGMSG_TEST_HOME}/VERSION"
  run agmsg_version_ok "mycmd"
  [ "$status" -eq 1 ]
}

@test "agmsg_adapter: agmsg_version_ok succeeds for v1.1.12-N-g<sha>-dirty variant" {
  echo "v1.1.12-3-g1c7efbc-dirty" > "${AGMSG_TEST_HOME}/VERSION"
  run agmsg_version_ok "mycmd"
  [ "$status" -eq 0 ]
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

# --- placement record accessor ---

@test "agmsg_adapter: agmsg_get_placement reads an existing record" {
  mkdir -p "${AGMSG_TEST_HOME}/run"
  printf '%%3\t/proj\tclaude-code\n' > "${AGMSG_TEST_HOME}/run/spawn.team1__karo"
  run agmsg_get_placement "mycmd" "team1" "karo"
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r id project type <<< "$output"
  [ "$id" = "%3" ]
  [ "$project" = "/proj" ]
  [ "$type" = "claude-code" ]
}

@test "agmsg_adapter: agmsg_get_placement fails when no record exists" {
  run agmsg_get_placement "mycmd" "team1" "karo"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "agmsg_adapter: agmsg_get_placement rejects an invalid team name" {
  run agmsg_get_placement "mycmd" "team one" "karo"
  [ "$status" -eq 2 ]
}

@test "agmsg_adapter: agmsg_get_placement rejects an invalid agent name" {
  run agmsg_get_placement "mycmd" "team1" "../evil"
  [ "$status" -eq 2 ]
}

# --- cmd_name validation must propagate through every derived function ---
# (regression coverage: an invalid cmd_name must not be silently swallowed by
# an intermediate "$(...)" substitution — it must surface as exit 2)

@test "agmsg_adapter: _agmsg_script propagates _agmsg_home's failure on invalid cmd_name" {
  unset AGMSG_HOME_OVERRIDE
  run _agmsg_script "bad/name" send.sh
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "agmsg_adapter: agmsg_version propagates _agmsg_home's failure on invalid cmd_name" {
  run agmsg_version "bad/name"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "agmsg_adapter: agmsg_version_ok propagates agmsg_version's failure on invalid cmd_name (not just 'version mismatch')" {
  run agmsg_version_ok "bad/name"
  [ "$status" -eq 2 ]
}

@test "agmsg_adapter: agmsg_get_placement propagates _agmsg_home's failure on invalid cmd_name" {
  run agmsg_get_placement "bad/name" "team1" "karo"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "agmsg_adapter: agmsg_send propagates cmd_name validation failure without invoking anything" {
  run agmsg_send "bad/name" team1 karo taisho msg
  [ "$status" -eq 2 ]
}

@test "agmsg_adapter: agmsg_join propagates cmd_name validation failure without invoking anything" {
  run agmsg_join "bad/name" team1 taisho claude-code /proj
  [ "$status" -eq 2 ]
}

@test "agmsg_adapter: agmsg_set_delivery propagates cmd_name validation failure without invoking anything" {
  run agmsg_set_delivery "bad/name" set monitor claude-code /proj
  [ "$status" -eq 2 ]
}

@test "agmsg_adapter: agmsg_spawn propagates cmd_name validation failure without invoking anything" {
  run agmsg_spawn "bad/name" claude-code karo
  [ "$status" -eq 2 ]
}

@test "agmsg_adapter: agmsg_despawn propagates cmd_name validation failure without invoking anything" {
  run agmsg_despawn "bad/name" team1 karo ashigaru1
  [ "$status" -eq 2 ]
}

@test "agmsg_adapter: agmsg_inbox propagates cmd_name validation failure without invoking anything" {
  run agmsg_inbox "bad/name" team1 karo
  [ "$status" -eq 2 ]
}

@test "agmsg_adapter: agmsg_history propagates cmd_name validation failure without invoking anything" {
  run agmsg_history "bad/name" team1
  [ "$status" -eq 2 ]
}
