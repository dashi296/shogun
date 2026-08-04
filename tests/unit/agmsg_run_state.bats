#!/usr/bin/env bats
# Unit tests for scripts/agmsg_run_state.sh

load '../test_helper'

setup() {
  export SHOGUN_ROOT="$(mktemp -d)"
  source "${SHOGUN_REPO}/scripts/agmsg_run_state.sh"
}

teardown() {
  rm -rf "${SHOGUN_ROOT}"
}

@test "agmsg_run_state: current returns empty before any run is started" {
  run agmsg_run_state_current
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "agmsg_run_state: new_run outputs a run_id and current reflects it" {
  run agmsg_run_state_new_run
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local run_id="$output"
  run agmsg_run_state_current
  [ "$output" = "$run_id" ]
}

@test "agmsg_run_state: new_run generates a different run_id each time" {
  local first second
  first="$(agmsg_run_state_new_run)"
  second="$(agmsg_run_state_new_run)"
  [ "$first" != "$second" ]
}

@test "agmsg_run_state: fresh_needed is true for a role with no marker" {
  agmsg_run_state_new_run >/dev/null
  run agmsg_run_state_fresh_needed "karo"
  [ "$status" -eq 0 ]
}

@test "agmsg_run_state: fresh_needed is false after mark_fresh_done" {
  agmsg_run_state_new_run >/dev/null
  agmsg_run_state_mark_fresh_done "karo"
  run agmsg_run_state_fresh_needed "karo"
  [ "$status" -eq 1 ]
}

@test "agmsg_run_state: new_run clears fresh_done markers from the previous run" {
  agmsg_run_state_new_run >/dev/null
  agmsg_run_state_mark_fresh_done "karo"
  agmsg_run_state_new_run >/dev/null
  run agmsg_run_state_fresh_needed "karo"
  [ "$status" -eq 0 ]
}

@test "agmsg_run_state: fresh_needed rejects an invalid role name" {
  agmsg_run_state_new_run >/dev/null
  run agmsg_run_state_fresh_needed "../evil"
  [ "$status" -eq 2 ]
}

@test "agmsg_run_state: mark_fresh_done rejects an invalid role name" {
  agmsg_run_state_new_run >/dev/null
  run agmsg_run_state_mark_fresh_done "bad name"
  [ "$status" -eq 2 ]
}
