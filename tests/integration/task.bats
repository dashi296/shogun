#!/usr/bin/env bats
# Integration tests for shogun task

load '../test_helper'

setup() {
  init_test_project
  cd "${TEST_PROJECT}"
}

teardown() {
  teardown_test_project
}

# --- happy path ---

@test "task: adds command to shogun_to_karo.yaml" {
  run shogun task "build auth feature"
  [ "$status" -eq 0 ]

  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/queue/shogun_to_karo.yaml', 'utf8'));
process.stdout.write(String(d.commands.length));
"
  [ "$output" = "1" ]
}

@test "task: sets command status to pending" {
  shogun task "build auth feature"

  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/queue/shogun_to_karo.yaml', 'utf8'));
process.stdout.write(d.commands[0].status);
"
  [ "$output" = "pending" ]
}

@test "task: first command id is cmd_001" {
  shogun task "build auth feature"

  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/queue/shogun_to_karo.yaml', 'utf8'));
process.stdout.write(d.commands[0].id);
"
  [ "$output" = "cmd_001" ]
}

@test "task: saves command description" {
  shogun task "implement login page"

  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/queue/shogun_to_karo.yaml', 'utf8'));
process.stdout.write(d.commands[0].command);
"
  [ "$output" = "implement login page" ]
}

@test "task: writes notification to taisho inbox" {
  shogun task "build auth feature"

  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/queue/inbox/taisho.yaml', 'utf8'));
process.stdout.write(String(d.messages.length));
"
  [ "$output" = "1" ]
}

@test "task: saves --priority option" {
  shogun task "urgent fix" --priority high

  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/queue/shogun_to_karo.yaml', 'utf8'));
process.stdout.write(d.commands[0].priority);
"
  [ "$output" = "high" ]
}

@test "task: assigns sequential ids for multiple tasks" {
  shogun task "task one"
  shogun task "task two"
  shogun task "task three"

  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/queue/shogun_to_karo.yaml', 'utf8'));
process.stdout.write(d.commands.map(c => c.id).join(','));
"
  [ "$output" = "cmd_001,cmd_002,cmd_003" ]
}

# --- error cases ---

@test "task: fails outside initialized directory" {
  local no_init_dir
  no_init_dir="$(mktemp -d)"
  cd "$no_init_dir"

  run shogun task "some task"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]

  rm -rf "$no_init_dir"
}
