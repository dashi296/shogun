#!/usr/bin/env bats
# Unit tests for scripts/inbox_write.sh

load '../test_helper'

setup() {
  setup_test_project
}

teardown() {
  teardown_test_project
}

# --- happy path ---

@test "inbox_write: exits 0 on valid message" {
  export SHOGUN_ROLE="taisho"
  run bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "karo" "subject" "body"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-> karo"* ]] || [[ "$output" == *"→ karo"* ]]
}

@test "inbox_write: writes message to YAML file" {
  export SHOGUN_ROLE="taisho"
  bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "karo" "subject" "body"

  local inbox="${TEST_PROJECT}/.shogun/queue/inbox/karo.yaml"
  [ -f "$inbox" ]
  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('${inbox}', 'utf8'));
process.stdout.write(String(d.messages.length));
"
  [ "$output" = "1" ]
}

@test "inbox_write: sets message status to unread" {
  export SHOGUN_ROLE="taisho"
  bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "karo" "subject" "body"

  local inbox="${TEST_PROJECT}/.shogun/queue/inbox/karo.yaml"
  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('${inbox}', 'utf8'));
process.stdout.write(d.messages[0].status);
"
  [ "$output" = "unread" ]
}

@test "inbox_write: sets from field from SHOGUN_ROLE" {
  export SHOGUN_ROLE="gunshi"
  bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "karo" "subject" "body"

  local inbox="${TEST_PROJECT}/.shogun/queue/inbox/karo.yaml"
  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('${inbox}', 'utf8'));
process.stdout.write(d.messages[0].from);
"
  [ "$output" = "gunshi" ]
}

@test "inbox_write: preserves subject and body" {
  export SHOGUN_ROLE="taisho"
  bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "karo" "my-subject" "my-body"

  local inbox="${TEST_PROJECT}/.shogun/queue/inbox/karo.yaml"
  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('${inbox}', 'utf8'));
const m = d.messages[0];
process.stdout.write(m.subject + '|' + m.body);
"
  [ "$output" = "my-subject|my-body" ]
}

@test "inbox_write: appends to existing messages" {
  export SHOGUN_ROLE="taisho"
  bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "karo" "msg1" "body1"
  bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "karo" "msg2" "body2"

  local inbox="${TEST_PROJECT}/.shogun/queue/inbox/karo.yaml"
  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('${inbox}', 'utf8'));
process.stdout.write(String(d.messages.length));
"
  [ "$output" = "2" ]
}

@test "inbox_write: creates inbox directory if missing" {
  export SHOGUN_ROLE="taisho"
  rm -rf "${TEST_PROJECT}/.shogun/queue/inbox"

  bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "karo" "subject" "body"
  [ -f "${TEST_PROJECT}/.shogun/queue/inbox/karo.yaml" ]
}

# --- error cases ---

@test "inbox_write: rejects recipient with slash" {
  export SHOGUN_ROLE="taisho"
  run bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "../etc/passwd" "subject" "body"
  [ "$status" -eq 1 ]
  [[ "$output" == *"recipient"* ]]
}

@test "inbox_write: rejects recipient with space" {
  export SHOGUN_ROLE="taisho"
  run bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "karo agent" "subject" "body"
  [ "$status" -eq 1 ]
  [[ "$output" == *"recipient"* ]]
}

@test "inbox_write: fails when SHOGUN_ROOT is unset" {
  unset SHOGUN_ROOT
  run bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "karo" "subject" "body"
  [ "$status" -ne 0 ]
}

# --- SHOGUN_PROJECT_ID ---

@test "inbox_write: with SHOGUN_PROJECT_ID writes to project-specific inbox" {
  export SHOGUN_ROLE="taisho"
  export SHOGUN_PROJECT_ID="proj1"
  bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "karo" "subject" "body"

  local inbox="${TEST_PROJECT}/.shogun/queue/projects/proj1/inbox/karo.yaml"
  [ -f "$inbox" ]
  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('${inbox}', 'utf8'));
process.stdout.write(String(d.messages.length));
"
  [ "$output" = "1" ]
}

@test "inbox_write: without SHOGUN_PROJECT_ID uses default inbox path" {
  export SHOGUN_ROLE="taisho"
  unset SHOGUN_PROJECT_ID
  bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "karo" "subject" "body"

  local default_inbox="${TEST_PROJECT}/.shogun/queue/inbox/karo.yaml"
  local project_inbox="${TEST_PROJECT}/.shogun/queue/projects"
  [ -f "$default_inbox" ]
  [ ! -d "$project_inbox" ]
}

@test "inbox_write: rejects invalid SHOGUN_PROJECT_ID with slash" {
  export SHOGUN_ROLE="taisho"
  export SHOGUN_PROJECT_ID="bad/id"
  run bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "karo" "subject" "body"
  [ "$status" -eq 1 ]
  [[ "$output" == *"project_id"* ]]
}

# --- SHOGUN_ROOT 二重 .shogun 検証 (issue #56) ---

@test "inbox_write: rejects SHOGUN_ROOT ending with .shogun" {
  export SHOGUN_ROLE="taisho"
  export SHOGUN_ROOT="${TEST_PROJECT}/.shogun"
  run bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "karo" "subject" "body"
  [ "$status" -eq 1 ]
  [[ "$output" == *".shogun"* ]]
}

@test "inbox_write: rejects SHOGUN_ROOT ending with .shogun/" {
  export SHOGUN_ROLE="taisho"
  export SHOGUN_ROOT="${TEST_PROJECT}/.shogun/"
  run bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "karo" "subject" "body"
  [ "$status" -eq 1 ]
  [[ "$output" == *".shogun"* ]]
}

@test "inbox_write: warns when inbox parent directory does not exist" {
  export SHOGUN_ROLE="taisho"
  rm -rf "${TEST_PROJECT}/.shogun/queue/inbox"
  run bash "${SHOGUN_REPO}/scripts/inbox_write.sh" "karo" "subject" "body"
  [ "$status" -eq 0 ]
  [ -f "${TEST_PROJECT}/.shogun/queue/inbox/karo.yaml" ]
  [[ "$output" == *"[warn]"* ]]
}
