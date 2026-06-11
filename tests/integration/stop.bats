#!/usr/bin/env bats
# shogun stop の統合テスト

load '../test_helper'

declare -a EXTRA_TMUX_SESSIONS=()
declare -a EXTRA_DIRS=()

setup() {
  init_test_project
  cd "${TEST_PROJECT}"
}

test_safe_name() {
  local project_name="$1"
  local safe_name
  safe_name="$(printf "%s" "$project_name" | LC_ALL=C tr -c 'A-Za-z0-9_-' '_')"
  if [[ -z "$safe_name" ]]; then
    safe_name="shogun"
  fi
  printf "%s" "$safe_name"
}

test_legacy_safe_name() {
  local project_name="$1"
  printf "%s" "${project_name// /_}"
}

test_root_hash() {
  local root="$1"
  local physical_root
  physical_root="$(cd "$root" && pwd -P)"
  node -e "
const crypto = require('crypto');
process.stdout.write(crypto.createHash('sha1').update(process.argv[1]).digest('hex').slice(0, 8));
" "$physical_root"
}

test_session_names() {
  local project_name="$1"
  local root="$2"
  local safe_name root_hash
  safe_name="$(test_safe_name "$project_name")"
  root_hash="$(test_root_hash "$root")"
  printf "%s %s\n" "taisho-${safe_name}-${root_hash}" "multiagent-${safe_name}-${root_hash}"
}

teardown() {
  local project_name safe_name legacy_safe_name session_taisho session_multi extra_session extra_dir
  if [[ -f "${TEST_PROJECT}/.shogun/config.yaml" ]]; then
    project_name="$(yaml_query "${TEST_PROJECT}/.shogun/config.yaml" "process.stdout.write(String(d.project_name || 'shogun'));")"
    safe_name="$(test_safe_name "$project_name")"
    legacy_safe_name="$(test_legacy_safe_name "$project_name")"
    read -r session_taisho session_multi <<< "$(test_session_names "$project_name" "$TEST_PROJECT")"
    tmux kill-session -t "=${session_taisho}" 2>/dev/null || true
    tmux kill-session -t "=${session_multi}" 2>/dev/null || true
    tmux kill-session -t "=${session_taisho}-other" 2>/dev/null || true
    tmux kill-session -t "=${session_multi}-other" 2>/dev/null || true
    tmux kill-session -t "=taisho-${safe_name}" 2>/dev/null || true
    tmux kill-session -t "=multiagent-${safe_name}" 2>/dev/null || true
    tmux kill-session -t "=taisho-${legacy_safe_name}" 2>/dev/null || true
    tmux kill-session -t "=multiagent-${legacy_safe_name}" 2>/dev/null || true
  fi
  for extra_session in "${EXTRA_TMUX_SESSIONS[@]}"; do
    tmux kill-session -t "=${extra_session}" 2>/dev/null || true
  done
  for extra_dir in "${EXTRA_DIRS[@]}"; do
    rm -rf "$extra_dir"
  done
  teardown_test_project
}

@test "stop: kills project tmux sessions" {
  local project_name session_taisho session_multi
  project_name="$(basename "${TEST_PROJECT}")"
  read -r session_taisho session_multi <<< "$(test_session_names "$project_name" "$TEST_PROJECT")"

  tmux new-session -d -s "$session_taisho"
  tmux new-session -d -s "$session_multi"

  run shogun stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"$session_taisho"* ]]
  [[ "$output" == *"$session_multi"* ]]

  run tmux has-session -t "=${session_taisho}"
  [ "$status" -ne 0 ]
  run tmux has-session -t "=${session_multi}"
  [ "$status" -ne 0 ]
}

@test "stop: succeeds even when sessions are already stopped" {
  run shogun stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"停止"* || "$output" == *"stopped"* ]]
}

@test "stop: does not kill sessions with similar names" {
  local project_name session_taisho session_multi
  project_name="$(basename "${TEST_PROJECT}")"
  read -r session_taisho session_multi <<< "$(test_session_names "$project_name" "$TEST_PROJECT")"

  tmux new-session -d -s "$session_taisho"
  tmux new-session -d -s "$session_multi"
  tmux new-session -d -s "${session_taisho}-other"
  tmux new-session -d -s "${session_multi}-other"

  run shogun stop
  [ "$status" -eq 0 ]

  run tmux has-session -t "=${session_taisho}-other"
  [ "$status" -eq 0 ]
  run tmux has-session -t "=${session_multi}-other"
  [ "$status" -eq 0 ]
}

@test "stop: does not modify queue YAML" {
  shogun task "stop 後も保持されるタスク" >/dev/null
  local before
  before="$(cat .shogun/queue/shogun_to_karo.yaml)"

  run shogun stop
  [ "$status" -eq 0 ]

  local after
  after="$(cat .shogun/queue/shogun_to_karo.yaml)"
  [ "$after" = "$before" ]
  [[ "$after" == *"stop 後も保持されるタスク"* ]]
}

@test "stop: normalizes project_name with special chars to safe name" {
  node - <<'NODE'
const fs = require('fs');
const yaml = require('js-yaml');
const file = '.shogun/config.yaml';
const data = yaml.load(fs.readFileSync(file, 'utf8')) || {};
data.project_name = 'bad:name.with space';
fs.writeFileSync(file, yaml.dump(data));
NODE

  local session_taisho session_multi
  read -r session_taisho session_multi <<< "$(test_session_names "bad:name.with space" "$TEST_PROJECT")"
  tmux new-session -d -s "$session_taisho"
  tmux new-session -d -s "$session_multi"

  run shogun stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"$session_taisho"* ]]
  [[ "$output" == *"$session_multi"* ]]

  run tmux has-session -t "=${session_taisho}"
  [ "$status" -ne 0 ]
  run tmux has-session -t "=${session_multi}"
  [ "$status" -ne 0 ]
}

@test "stop: does not kill sessions from other project with same safe name" {
  local project_name session_taisho session_multi other_root other_taisho other_multi
  project_name="same:name"
  node - <<'NODE'
const fs = require('fs');
const yaml = require('js-yaml');
const file = '.shogun/config.yaml';
const data = yaml.load(fs.readFileSync(file, 'utf8')) || {};
data.project_name = 'same:name';
fs.writeFileSync(file, yaml.dump(data));
NODE

  read -r session_taisho session_multi <<< "$(test_session_names "$project_name" "$TEST_PROJECT")"
  other_root="$(mktemp -d)"
  EXTRA_DIRS+=("$other_root")
  read -r other_taisho other_multi <<< "$(test_session_names "$project_name" "$other_root")"

  tmux new-session -d -s "$session_taisho"
  tmux new-session -d -s "$session_multi"
  tmux new-session -d -s "$other_taisho"
  tmux new-session -d -s "$other_multi"
  EXTRA_TMUX_SESSIONS+=("$other_taisho" "$other_multi")

  run shogun stop
  [ "$status" -eq 0 ]

  run tmux has-session -t "=${session_taisho}"
  [ "$status" -ne 0 ]
  run tmux has-session -t "=${session_multi}"
  [ "$status" -ne 0 ]
  run tmux has-session -t "=${other_taisho}"
  [ "$status" -eq 0 ]
  run tmux has-session -t "=${other_multi}"
  [ "$status" -eq 0 ]

}

@test "stop: does not kill legacy sessions without hash by default" {
  local project_name legacy_safe_name
  project_name="$(basename "${TEST_PROJECT}")"
  legacy_safe_name="$(test_legacy_safe_name "$project_name")"

  tmux new-session -d -s "taisho-${legacy_safe_name}"
  tmux new-session -d -s "multiagent-${legacy_safe_name}"

  run shogun stop
  [ "$status" -eq 0 ]

  run tmux has-session -t "=taisho-${legacy_safe_name}"
  [ "$status" -eq 0 ]
  run tmux has-session -t "=multiagent-${legacy_safe_name}"
  [ "$status" -eq 0 ]
}

@test "stop --legacy: also kills legacy sessions without hash" {
  local project_name legacy_safe_name
  project_name="$(basename "${TEST_PROJECT}")"
  legacy_safe_name="$(test_legacy_safe_name "$project_name")"

  tmux new-session -d -s "taisho-${legacy_safe_name}"
  tmux new-session -d -s "multiagent-${legacy_safe_name}"

  run shogun stop --legacy
  [ "$status" -eq 0 ]
  [[ "$output" == *"taisho-${legacy_safe_name}"* ]]
  [[ "$output" == *"multiagent-${legacy_safe_name}"* ]]

  run tmux has-session -t "=taisho-${legacy_safe_name}"
  [ "$status" -ne 0 ]
  run tmux has-session -t "=multiagent-${legacy_safe_name}"
  [ "$status" -ne 0 ]
}

@test "start: does not kill legacy sessions without hash by default" {
  local project_name legacy_safe_name session_taisho session_multi
  project_name="$(basename "${TEST_PROJECT}")"
  legacy_safe_name="$(test_legacy_safe_name "$project_name")"
  read -r session_taisho session_multi <<< "$(test_session_names "$project_name" "$TEST_PROJECT")"

  tmux new-session -d -s "taisho-${legacy_safe_name}"
  tmux new-session -d -s "multiagent-${legacy_safe_name}"

  run shogun start --setup
  [ "$status" -eq 0 ]

  run tmux has-session -t "=${session_taisho}"
  [ "$status" -eq 0 ]
  run tmux has-session -t "=${session_multi}"
  [ "$status" -eq 0 ]
  run tmux has-session -t "=taisho-${legacy_safe_name}"
  [ "$status" -eq 0 ]
  run tmux has-session -t "=multiagent-${legacy_safe_name}"
  [ "$status" -eq 0 ]
}

@test "start --legacy-cleanup: also kills legacy sessions without hash" {
  local project_name legacy_safe_name session_taisho session_multi
  project_name="$(basename "${TEST_PROJECT}")"
  legacy_safe_name="$(test_legacy_safe_name "$project_name")"
  read -r session_taisho session_multi <<< "$(test_session_names "$project_name" "$TEST_PROJECT")"

  tmux new-session -d -s "taisho-${legacy_safe_name}"
  tmux new-session -d -s "multiagent-${legacy_safe_name}"

  run shogun start --setup --legacy-cleanup
  [ "$status" -eq 0 ]

  run tmux has-session -t "=${session_taisho}"
  [ "$status" -eq 0 ]
  run tmux has-session -t "=${session_multi}"
  [ "$status" -eq 0 ]
  run tmux has-session -t "=taisho-${legacy_safe_name}"
  [ "$status" -ne 0 ]
  run tmux has-session -t "=multiagent-${legacy_safe_name}"
  [ "$status" -ne 0 ]
}

@test "stop: uses same hash for symlink and physical path" {
  local project_name link_dir physical_hash link_hash session_taisho session_multi
  project_name="$(basename "${TEST_PROJECT}")"
  link_dir="$(mktemp -d)/linked-project"
  EXTRA_DIRS+=("$(dirname "$link_dir")")
  ln -s "$TEST_PROJECT" "$link_dir"

  physical_hash="$(test_root_hash "$TEST_PROJECT")"
  link_hash="$(test_root_hash "$link_dir")"
  [ "$link_hash" = "$physical_hash" ]

  read -r session_taisho session_multi <<< "$(test_session_names "$project_name" "$link_dir")"
  tmux new-session -d -s "$session_taisho"
  tmux new-session -d -s "$session_multi"

  run shogun stop
  [ "$status" -eq 0 ]

  run tmux has-session -t "=${session_taisho}"
  [ "$status" -ne 0 ]
  run tmux has-session -t "=${session_multi}"
  [ "$status" -ne 0 ]
}

@test "stop: fails in uninitialized directory" {
  local no_init_dir
  no_init_dir="$(mktemp -d)"
  EXTRA_DIRS+=("$no_init_dir")
  cd "$no_init_dir"

  run shogun stop
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "stop --help: shows usage even in uninitialized directory" {
  local no_init_dir
  no_init_dir="$(mktemp -d)"
  EXTRA_DIRS+=("$no_init_dir")
  cd "$no_init_dir"

  run shogun stop --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: shogun stop [--legacy]"* ]]
}

@test "stop: .shogun error takes priority over unknown option in uninitialized directory" {
  local no_init_dir
  no_init_dir="$(mktemp -d)"
  EXTRA_DIRS+=("$no_init_dir")
  cd "$no_init_dir"

  run shogun stop --unknown
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *".shogun"* ]]
}
