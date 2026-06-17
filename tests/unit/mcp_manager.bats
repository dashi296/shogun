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

@test "mcp_manager start: generates mcp.json with server name" {
  bash "${SHOGUN_REPO}/scripts/mcp_manager.sh" start karo "${TEST_ROOT}" "ashigaru1,ashigaru2" 2>/dev/null
  run cat "${TEST_ROOT}/.shogun/mcp/karo.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"shogun-mcp-queue-karo"'* ]]
}

@test "mcp_manager start: mcp.json includes correct allowed-sources arg" {
  bash "${SHOGUN_REPO}/scripts/mcp_manager.sh" start karo "${TEST_ROOT}" "ashigaru1,ashigaru2" 2>/dev/null
  run cat "${TEST_ROOT}/.shogun/mcp/karo.json"
  [[ "$output" == *'--allowed-sources=ashigaru1,ashigaru2'* ]]
}

@test "mcp_manager start: does NOT create a PID file (server managed by Claude Code)" {
  bash "${SHOGUN_REPO}/scripts/mcp_manager.sh" start karo "${TEST_ROOT}" "" 2>/dev/null
  [ ! -f "${TEST_ROOT}/.shogun/mcp/karo.pid" ]
}

@test "mcp_manager start: MCP server binary starts and outputs ready message" {
  # サーババイナリが正常に起動することを確認（stdin を即 close して終了を待つ）
  run node "${SHOGUN_REPO}/packages/mcp-queue/src/server.js" \
    "--role=karo" "--root=${TEST_ROOT}" </dev/null 2>&1
  # StdioServerTransport は stdin EOF で終了するが、起動中に ready ログを出す
  [[ "$output" == *"role=karo ready"* ]]
}

@test "mcp_manager start: rejects invalid role name" {
  run bash "${SHOGUN_REPO}/scripts/mcp_manager.sh" start "../evil" "${TEST_ROOT}" ""
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid role" ]]
}

@test "mcp_manager start: rejects invalid allowed_sources" {
  run bash "${SHOGUN_REPO}/scripts/mcp_manager.sh" start karo "${TEST_ROOT}" "ok,../evil"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid source" ]]
}

@test "mcp_manager stop: succeeds even when no PID file exists" {
  run bash "${SHOGUN_REPO}/scripts/mcp_manager.sh" stop karo "${TEST_ROOT}"
  [ "$status" -eq 0 ]
}

@test "mcp_manager stop_all: succeeds even when no PID files exist" {
  run bash "${SHOGUN_REPO}/scripts/mcp_manager.sh" stop_all "${TEST_ROOT}"
  [ "$status" -eq 0 ]
}
