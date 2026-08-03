#!/usr/bin/env bats
# Unit tests for read_agmsg_cmd_name (bin/shogun) と shogun doctor の agmsg 連携

load '../test_helper'

setup() {
  # bin/shogun 内のヘルパー関数だけを取り出して source する。
  # cmd_* のディスパッチ（case文）は実行させないため、関数定義部分までを抽出する。
  TEST_CONFIG="$(mktemp)"
  cat > "$TEST_CONFIG" <<'YAML'
project_name: testproj
agents:
  ashigaru_count: 3
agmsg:
  cmd_name: mycmd
YAML
}

teardown() {
  rm -f "$TEST_CONFIG"
}

@test "read_agmsg_cmd_name: returns configured cmd_name" {
  run bash -c "source '${SHOGUN_REPO}/bin/shogun' 2>/dev/null; read_agmsg_cmd_name '${TEST_CONFIG}'"
  [ "$status" -eq 0 ]
  [ "$output" = "mycmd" ]
}

@test "read_agmsg_cmd_name: defaults to 'agmsg' when unset" {
  echo "project_name: testproj" > "$TEST_CONFIG"
  run bash -c "source '${SHOGUN_REPO}/bin/shogun' 2>/dev/null; read_agmsg_cmd_name '${TEST_CONFIG}'"
  [ "$output" = "agmsg" ]
}
