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
