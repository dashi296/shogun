#!/usr/bin/env bats
# Unit tests for scripts/mcp_manager.sh

load '../test_helper'

setup() {
  TEST_ROOT="$(mktemp -d)"
  mkdir -p "${TEST_ROOT}/.shogun/queue"
}

teardown() {
  bash "${SHOGUN_REPO}/scripts/mcp_manager.sh" stop_all "${TEST_ROOT}" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}

@test "mcp_manager start: creates PID file" {
  bash "${SHOGUN_REPO}/scripts/mcp_manager.sh" start karo "${TEST_ROOT}" "" 2>/dev/null
  [ -f "${TEST_ROOT}/.shogun/mcp/karo.pid" ]
}

@test "mcp_manager start: generates mcp.json with server name" {
  bash "${SHOGUN_REPO}/scripts/mcp_manager.sh" start karo "${TEST_ROOT}" "ashigaru1,ashigaru2" 2>/dev/null
  run cat "${TEST_ROOT}/.shogun/mcp/karo.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"shogun-mcp-queue-karo"'* ]]
}

@test "mcp_manager stop: removes PID file" {
  bash "${SHOGUN_REPO}/scripts/mcp_manager.sh" start karo "${TEST_ROOT}" "" 2>/dev/null
  bash "${SHOGUN_REPO}/scripts/mcp_manager.sh" stop karo "${TEST_ROOT}" 2>/dev/null
  [ ! -f "${TEST_ROOT}/.shogun/mcp/karo.pid" ]
}
