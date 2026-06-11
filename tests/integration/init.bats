#!/usr/bin/env bats
# Integration tests for shogun init

load '../test_helper'

setup() {
  TEST_PROJECT="$(mktemp -d)"
  export TEST_PROJECT
  cd "${TEST_PROJECT}"
}

teardown() {
  teardown_test_project
}

# --- directory structure ---

@test "init: creates .shogun/ directory" {
  run shogun init
  [ "$status" -eq 0 ]
  [ -d ".shogun" ]
}

@test "init: creates queue subdirectories" {
  shogun init
  [ -d ".shogun/queue/inbox" ]
  [ -d ".shogun/queue/tasks" ]
  [ -d ".shogun/queue/reports" ]
}

@test "init: creates instructions, memory, and logs directories" {
  shogun init
  [ -d ".shogun/instructions" ]
  [ -d ".shogun/memory" ]
  [ -d ".shogun/logs" ]
}

# --- file copies ---

@test "init: creates config.yaml" {
  shogun init
  [ -f ".shogun/config.yaml" ]
}

@test "init: sets project_name in config.yaml" {
  local expected_name
  expected_name="$(basename "${TEST_PROJECT}")"
  shogun init

  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/config.yaml', 'utf8'));
process.stdout.write(d.project_name);
"
  [ "$output" = "$expected_name" ]
}

@test "init: copies CLAUDE.md" {
  shogun init
  [ -f ".shogun/CLAUDE.md" ]
}

@test "init: copies all role instruction files" {
  shogun init
  [ -f ".shogun/instructions/taisho.md" ]
  [ -f ".shogun/instructions/karo.md" ]
  [ -f ".shogun/instructions/gunshi.md" ]
  [ -f ".shogun/instructions/metsuke.md" ]
  [ -f ".shogun/instructions/ashigaru.md" ]
}

# --- queue initialization ---

@test "init: initializes shogun_to_karo.yaml with empty commands" {
  shogun init

  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/queue/shogun_to_karo.yaml', 'utf8'));
process.stdout.write(JSON.stringify(d.commands));
"
  [ "$output" = "[]" ]
}

@test "init: initializes all agent inboxes as empty" {
  shogun init

  for agent in taisho karo gunshi metsuke ashigaru1 ashigaru2 ashigaru3; do
    [ -f ".shogun/queue/inbox/${agent}.yaml" ]
    run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/queue/inbox/${agent}.yaml', 'utf8'));
process.stdout.write(JSON.stringify(d.messages));
"
    [ "$output" = "[]" ]
  done
}

# --- idempotency and gitignore ---

@test "init: second run does not error" {
  shogun init
  run shogun init
  [ "$status" -eq 0 ]
}

@test "init: appends Shogun entry to existing .gitignore" {
  echo "node_modules/" > .gitignore
  shogun init
  grep -q "Shogun" .gitignore
}

@test "init: creates dashboard.md in .shogun/" {
  shogun init
  [ -f ".shogun/dashboard.md" ]
}

@test "init: dashboard.md contains project name" {
  shogun init
  local project_name
  project_name="$(basename "${TEST_PROJECT}")"
  grep -q "$project_name" ".shogun/dashboard.md"
}
