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

@test "init: creates reviews queue directory" {
  shogun init
  [ -d ".shogun/queue/reviews" ]
}

@test "init: creates per-ashigaru review file with reviews: []" {
  shogun init
  [ -f ".shogun/queue/reviews/ashigaru1_review.yaml" ]
  run cat ".shogun/queue/reviews/ashigaru1_review.yaml"
  [ "$output" = "reviews: []" ]
}

@test "init: does NOT create review files for non-ashigaru roles" {
  shogun init
  [ ! -f ".shogun/queue/reviews/karo_review.yaml" ]
  [ ! -f ".shogun/queue/reviews/metsuke_review.yaml" ]
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

@test "init: gitignore includes reviews queue pattern" {
  echo "node_modules/" > .gitignore
  shogun init
  grep -q "queue/reviews/\*\.yaml" .gitignore
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

# --- Memory MCP ---

@test "init: creates .mcp.json in project root" {
  shogun init
  [ -f ".mcp.json" ]
}

@test "init: .mcp.json contains memory MCP server entry" {
  shogun init
  run node -e "
const d = JSON.parse(require('fs').readFileSync('.mcp.json', 'utf8'));
process.stdout.write(d.mcpServers && d.mcpServers.memory ? 'ok' : 'ng');
"
  [ "$output" = "ok" ]
}

@test "init: does not overwrite pre-existing .mcp.json" {
  echo '{"custom":true}' > .mcp.json
  shogun init
  run node -e "
const d = JSON.parse(require('fs').readFileSync('.mcp.json', 'utf8'));
process.stdout.write(d.custom ? 'ok' : 'ng');
"
  [ "$output" = "ok" ]
}

@test "init: MEMORY_FILE_PATH in .mcp.json is an absolute path" {
  shogun init
  run node -e "
const path = require('path');
const d = JSON.parse(require('fs').readFileSync('.mcp.json', 'utf8'));
const p = d.mcpServers.memory.env.MEMORY_FILE_PATH;
process.stdout.write(path.isAbsolute(p) ? 'ok' : 'ng:' + p);
"
  [ "$output" = "ok" ]
}

@test "init: MEMORY_FILE_PATH points inside project .shogun/memory/" {
  shogun init
  run node -e "
const d = JSON.parse(require('fs').readFileSync('.mcp.json', 'utf8'));
const p = d.mcpServers.memory.env.MEMORY_FILE_PATH;
process.stdout.write(p.endsWith('/.shogun/memory/memory.jsonl') ? 'ok' : 'ng:' + p);
"
  [ "$output" = "ok" ]
}

# --- Bloom Taxonomy ---

@test "init: config.yaml contains capability_tiers section" {
  shogun init

  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/config.yaml', 'utf8'));
process.stdout.write(JSON.stringify(d.capability_tiers != null));
"
  [ "$output" = "true" ]
}

@test "init: capability_tiers has ashigaru bloom_max 3 and gunshi bloom_min 4" {
  shogun init

  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/config.yaml', 'utf8'));
const t = d.capability_tiers;
process.stdout.write(JSON.stringify(t.ashigaru.bloom_max === 3 && t.gunshi.bloom_min === 4));
"
  [ "$output" = "true" ]
}

@test "init: capability_tiers has correct model_bloom_ceiling values" {
  shogun init

  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/config.yaml', 'utf8'));
const c = d.capability_tiers.model_bloom_ceiling;
process.stdout.write(JSON.stringify(c.haiku === 3 && c.sonnet === 5 && c.opus === 6));
"
  [ "$output" = "true" ]
}

# --- Skill System ---

@test "init: creates .claude/commands/ directory" {
  shogun init
  [ -d ".claude/commands" ]
}

@test "init: copies shogun-agent-status skill" {
  shogun init
  [ -f ".claude/commands/shogun-agent-status.md" ]
}

@test "init: copies shogun-propose-skill skill" {
  shogun init
  [ -f ".claude/commands/shogun-propose-skill.md" ]
}

# --- project management (--project-id) ---

@test "init --project-id: creates .shogun/config/projects.yaml" {
  shogun init --project-id myproject
  [ -f ".shogun/config/projects.yaml" ]
}

@test "init --project-id: sets correct project id in projects.yaml" {
  shogun init --project-id myproject
  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/config/projects.yaml', 'utf8'));
process.stdout.write(d.default_project);
"
  [ "$output" = "myproject" ]
}

@test "init --project-id: creates .shogun/projects/{id}.yaml" {
  shogun init --project-id myproject
  [ -f ".shogun/projects/myproject.yaml" ]
}

@test "init --project-id: project file has correct project_id" {
  shogun init --project-id myproject
  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/projects/myproject.yaml', 'utf8'));
process.stdout.write(d.project_id);
"
  [ "$output" = "myproject" ]
}

@test "init --project-id: rejects invalid project id with slash" {
  run shogun init --project-id "bad/id"
  [ "$status" -ne 0 ]
}

@test "init: without --project-id does not create projects files" {
  shogun init
  [ ! -f ".shogun/config/projects.yaml" ]
  [ ! -d ".shogun/projects" ]
}

@test "init: gitignore includes project queue pattern when --project-id given" {
  echo "node_modules/" > .gitignore
  shogun init --project-id myproject
  grep -q "projects/\*\*/\*\.yaml" .gitignore || grep -q "projects" .gitignore
}

# --- Sengoku Persona ---

@test "init: config.yaml contains persona.sengoku: true" {
  shogun init

  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/config.yaml', 'utf8'));
process.stdout.write(JSON.stringify(d.persona != null && d.persona.sengoku === true));
"
  [ "$output" = "true" ]
}
