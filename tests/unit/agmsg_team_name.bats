#!/usr/bin/env bats
# Unit tests for project_agmsg_team_name (bin/shogun)

load '../test_helper'

setup() {
  TEST_ROOT="$(mktemp -d)"
}

teardown() {
  rm -rf "${TEST_ROOT}"
}

@test "project_agmsg_team_name: combines safe_name and root_hash" {
  run bash -c "source '${SHOGUN_REPO}/bin/shogun' 2>/dev/null; project_agmsg_team_name 'my project' '${TEST_ROOT}'"
  [ "$status" -eq 0 ]
  [[ "$output" == my_project-* ]]
}

@test "project_agmsg_team_name: is stable for the same project_name and root" {
  local a b
  a="$(bash -c "source '${SHOGUN_REPO}/bin/shogun' 2>/dev/null; project_agmsg_team_name 'proj' '${TEST_ROOT}'")"
  b="$(bash -c "source '${SHOGUN_REPO}/bin/shogun' 2>/dev/null; project_agmsg_team_name 'proj' '${TEST_ROOT}'")"
  [ "$a" = "$b" ]
}

@test "project_agmsg_team_name: differs from the tmux session name (different namespace)" {
  run bash -c "
    source '${SHOGUN_REPO}/bin/shogun' 2>/dev/null
    team=\"\$(project_agmsg_team_name 'proj' '${TEST_ROOT}')\"
    read -r sess _rest <<< \"\$(project_session_name 'proj' '${TEST_ROOT}')\"
    [ \"\$team\" != \"\$sess\" ]
  "
  [ "$status" -eq 0 ]
}
