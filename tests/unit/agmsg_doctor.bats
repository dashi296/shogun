#!/usr/bin/env bats
# Unit tests for read_agmsg_cmd_name (bin/shogun) と shogun doctor の agmsg 連携

load '../test_helper'

setup() {
  # bin/shogun は source されると（BASH_SOURCE と $0 が異なるため）既存のガードで
  # ディスパッチ部分（case文）の実行を止める。これを利用してヘルパー関数だけを読み込む。
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

@test "read_agmsg_cmd_name: does not silently replace an explicit empty string with the default" {
  cat > "$TEST_CONFIG" <<'YAML'
project_name: testproj
agmsg:
  cmd_name: ""
YAML
  run bash -c "source '${SHOGUN_REPO}/bin/shogun' 2>/dev/null; read_agmsg_cmd_name '${TEST_CONFIG}'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "read_agmsg_cmd_name: an explicit empty string is then rejected by agmsg_cmd_name_valid" {
  cat > "$TEST_CONFIG" <<'YAML'
project_name: testproj
agmsg:
  cmd_name: ""
YAML
  run bash -c "
    source '${SHOGUN_REPO}/bin/shogun' 2>/dev/null
    source '${SHOGUN_REPO}/scripts/agmsg_adapter.sh'
    v=\"\$(read_agmsg_cmd_name '${TEST_CONFIG}')\"
    agmsg_cmd_name_valid \"\$v\"
  "
  [ "$status" -eq 1 ]
}
