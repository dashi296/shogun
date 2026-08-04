#!/usr/bin/env bats
# shogun stop の統合テスト

load '../test_helper'

declare -a EXTRA_TMUX_SESSIONS=()
declare -a EXTRA_DIRS=()
declare -a EXTRA_PIDS=()

# 残留 watcher を模した単一プロセスを起動する。
# exec -a で argv[0] にセッション名込みの文字列を設定し、pkill -f の対象を再現する。
# exec により bash 自身が sleep に置換されるため子 sleep を orphan させない。
spawn_fake_watcher() {
  local argv0="$1"
  bash -c 'exec -a "$0" sleep 600' "$argv0" &
  local pid=$!
  EXTRA_PIDS+=("$pid")
  # プロセスがプロセステーブルに現れるまで待つ
  local i=0
  while ! pgrep -f "$argv0" >/dev/null 2>&1; do
    sleep 0.05
    i=$((i + 1))
    [ "$i" -gt 40 ] && break
  done
  printf "%s" "$pid"
}

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

# 1セッション構成: project_session_name() が返す単一の tmux セッション名
test_session_name() {
  local project_name="$1"
  local root="$2"
  local safe_name root_hash
  safe_name="$(test_safe_name "$project_name")"
  root_hash="$(test_root_hash "$root")"
  printf "shogun-%s-%s" "${safe_name}" "${root_hash}"
}

teardown() {
  local project_name safe_name legacy_safe_name session extra_session extra_dir
  if [[ -f "${TEST_PROJECT}/.shogun/config.yaml" ]]; then
    project_name="$(yaml_query "${TEST_PROJECT}/.shogun/config.yaml" "process.stdout.write(String(d.project_name || 'shogun'));")"
    safe_name="$(test_safe_name "$project_name")"
    legacy_safe_name="$(test_legacy_safe_name "$project_name")"
    session="$(test_session_name "$project_name" "$TEST_PROJECT")"
    tmux kill-session -t "=${session}" 2>/dev/null || true
    tmux kill-session -t "=${session}-other" 2>/dev/null || true
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
  local extra_pid
  for extra_pid in "${EXTRA_PIDS[@]}"; do
    kill "$extra_pid" 2>/dev/null || true
  done
  teardown_test_project
}

@test "stop: kills project tmux sessions" {
  local project_name session
  project_name="$(basename "${TEST_PROJECT}")"
  session="$(test_session_name "$project_name" "$TEST_PROJECT")"

  tmux new-session -d -s "$session"

  run shogun stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"$session"* ]]

  run tmux has-session -t "=${session}"
  [ "$status" -ne 0 ]
}

@test "stop: kills leftover inbox_watcher processes for the project" {
  local project_name session
  project_name="$(basename "${TEST_PROJECT}")"
  session="$(test_session_name "$project_name" "$TEST_PROJECT")"

  tmux new-session -d -s "$session"

  # このプロジェクトの残留 watcher を模したプロセスを起動
  spawn_fake_watcher "bash inbox_watcher.sh ashigaru1 ${session}:0.3" >/dev/null
  run pgrep -f "inbox_watcher.sh.*${session}"
  [ "$status" -eq 0 ]

  run shogun stop
  [ "$status" -eq 0 ]

  # stop 後は watcher が停止している
  local j=0
  while pgrep -f "inbox_watcher.sh.*${session}" >/dev/null 2>&1; do
    sleep 0.05
    j=$((j + 1))
    [ "$j" -gt 40 ] && break
  done
  run pgrep -f "inbox_watcher.sh.*${session}"
  [ "$status" -ne 0 ]
}

@test "stop: does not kill watcher processes of another project" {
  local project_name session
  project_name="$(basename "${TEST_PROJECT}")"
  session="$(test_session_name "$project_name" "$TEST_PROJECT")"

  tmux new-session -d -s "$session"

  # 別プロジェクト（別 root → 別ハッシュ）の watcher。停止対象外であること
  local other_root other_session
  other_root="$(mktemp -d)"
  EXTRA_DIRS+=("$other_root")
  other_session="$(test_session_name "$project_name" "$other_root")"

  spawn_fake_watcher "bash inbox_watcher.sh ashigaru1 ${other_session}:0.3" >/dev/null

  run shogun stop
  [ "$status" -eq 0 ]
  sleep 0.3

  # 別プロジェクトの watcher は生存している
  run pgrep -f "inbox_watcher.sh.*${other_session}"
  [ "$status" -eq 0 ]
}

@test "stop: succeeds even when sessions are already stopped" {
  run shogun stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"停止"* || "$output" == *"stopped"* ]]
}

@test "stop: does not kill sessions with similar names" {
  local project_name session
  project_name="$(basename "${TEST_PROJECT}")"
  session="$(test_session_name "$project_name" "$TEST_PROJECT")"

  tmux new-session -d -s "$session"
  tmux new-session -d -s "${session}-other"

  run shogun stop
  [ "$status" -eq 0 ]

  run tmux has-session -t "=${session}-other"
  [ "$status" -eq 0 ]
}

@test "stop: does not modify queue YAML" {
  # shogun task はもはや shogun_to_karo.yaml に書き込まないため（agmsg send 経由に
  # 置き換え済み）、既存キューを stop が変更しないことを検証するために直接書き込む。
  node -e "
const fs = require('fs');
const yaml = require('js-yaml');
const data = { commands: [{ id: 'cmd_001', timestamp: new Date().toISOString(), command: 'stop 後も保持されるタスク', priority: 'normal', status: 'pending' }] };
fs.writeFileSync('.shogun/queue/shogun_to_karo.yaml', yaml.dump(data, { allowUnicode: true }));
"
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

  local session
  session="$(test_session_name "bad:name.with space" "$TEST_PROJECT")"
  tmux new-session -d -s "$session"

  run shogun stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"$session"* ]]

  run tmux has-session -t "=${session}"
  [ "$status" -ne 0 ]
}

@test "stop: does not kill sessions from other project with same safe name" {
  local project_name session other_root other_session
  project_name="same:name"
  node - <<'NODE'
const fs = require('fs');
const yaml = require('js-yaml');
const file = '.shogun/config.yaml';
const data = yaml.load(fs.readFileSync(file, 'utf8')) || {};
data.project_name = 'same:name';
fs.writeFileSync(file, yaml.dump(data));
NODE

  session="$(test_session_name "$project_name" "$TEST_PROJECT")"
  other_root="$(mktemp -d)"
  EXTRA_DIRS+=("$other_root")
  other_session="$(test_session_name "$project_name" "$other_root")"

  tmux new-session -d -s "$session"
  tmux new-session -d -s "$other_session"
  EXTRA_TMUX_SESSIONS+=("$other_session")

  run shogun stop
  [ "$status" -eq 0 ]

  run tmux has-session -t "=${session}"
  [ "$status" -ne 0 ]
  run tmux has-session -t "=${other_session}"
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
  local project_name legacy_safe_name session
  project_name="$(basename "${TEST_PROJECT}")"
  legacy_safe_name="$(test_legacy_safe_name "$project_name")"
  session="$(test_session_name "$project_name" "$TEST_PROJECT")"

  tmux new-session -d -s "taisho-${legacy_safe_name}"
  tmux new-session -d -s "multiagent-${legacy_safe_name}"

  run shogun start --setup
  [ "$status" -eq 0 ]

  run tmux has-session -t "=${session}"
  [ "$status" -eq 0 ]
  run tmux has-session -t "=taisho-${legacy_safe_name}"
  [ "$status" -eq 0 ]
  run tmux has-session -t "=multiagent-${legacy_safe_name}"
  [ "$status" -eq 0 ]
}

@test "start --legacy-cleanup: also kills legacy sessions without hash" {
  local project_name legacy_safe_name session
  project_name="$(basename "${TEST_PROJECT}")"
  legacy_safe_name="$(test_legacy_safe_name "$project_name")"
  session="$(test_session_name "$project_name" "$TEST_PROJECT")"

  tmux new-session -d -s "taisho-${legacy_safe_name}"
  tmux new-session -d -s "multiagent-${legacy_safe_name}"

  run shogun start --setup --legacy-cleanup
  [ "$status" -eq 0 ]

  run tmux has-session -t "=${session}"
  [ "$status" -eq 0 ]
  run tmux has-session -t "=taisho-${legacy_safe_name}"
  [ "$status" -ne 0 ]
  run tmux has-session -t "=multiagent-${legacy_safe_name}"
  [ "$status" -ne 0 ]
}

@test "stop: uses same hash for symlink and physical path" {
  local project_name link_dir physical_hash link_hash session
  project_name="$(basename "${TEST_PROJECT}")"
  link_dir="$(mktemp -d)/linked-project"
  EXTRA_DIRS+=("$(dirname "$link_dir")")
  ln -s "$TEST_PROJECT" "$link_dir"

  physical_hash="$(test_root_hash "$TEST_PROJECT")"
  link_hash="$(test_root_hash "$link_dir")"
  [ "$link_hash" = "$physical_hash" ]

  session="$(test_session_name "$project_name" "$link_dir")"
  tmux new-session -d -s "$session"

  run shogun stop
  [ "$status" -eq 0 ]

  run tmux has-session -t "=${session}"
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
