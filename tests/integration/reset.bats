#!/usr/bin/env bats
# shogun reset の統合テスト

load '../test_helper'

declare -a EXTRA_DIRS=()

test_safe_name() {
  local project_name="$1"
  local safe_name
  safe_name="$(printf "%s" "$project_name" | LC_ALL=C tr -c 'A-Za-z0-9_-' '_')"
  if [[ -z "$safe_name" ]]; then
    safe_name="shogun"
  fi
  printf "%s" "$safe_name"
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

test_session_name() {
  local project_name="$1"
  local root="$2"
  local safe_name root_hash
  safe_name="$(test_safe_name "$project_name")"
  root_hash="$(test_root_hash "$root")"
  printf "shogun-%s-%s" "${safe_name}" "${root_hash}"
}

# flag_names.sh と同じアルゴリズムで root_key を計算する。
# cd で正規化するのは、require_init 内の find_shogun_root が $(pwd) で
# 二重スラッシュなどを除いた論理パスを返すため。
test_flag_root_key() {
  local root="$1"
  local normalized
  normalized="$(cd "$root" && pwd)"
  printf '%s' "$normalized" | cksum | cut -d' ' -f1
}

setup() {
  init_test_project
  cd "${TEST_PROJECT}"
}

# shogun task はもはや shogun_to_karo.yaml に書き込まないため（agmsg send 経由に
# 置き換え済み）、reset がキューを実際に空へ戻すことを検証するために直接書き込む。
_seed_command_queue() {
  local desc="$1"
  node -e "
const fs = require('fs');
const yaml = require('js-yaml');
const data = { commands: [{ id: 'cmd_001', timestamp: new Date().toISOString(), command: process.argv[1], priority: 'normal', status: 'pending' }] };
fs.writeFileSync('.shogun/queue/shogun_to_karo.yaml', yaml.dump(data, { allowUnicode: true }));
" "$desc"
}

teardown() {
  local project_name session extra_dir
  if [[ -f "${TEST_PROJECT}/.shogun/config.yaml" ]]; then
    project_name="$(yaml_query "${TEST_PROJECT}/.shogun/config.yaml" "process.stdout.write(String(d.project_name || 'shogun'));")"
    session="$(test_session_name "$project_name" "$TEST_PROJECT")"
    tmux kill-session -t "=${session}" 2>/dev/null || true
  fi
  for extra_dir in "${EXTRA_DIRS[@]}"; do
    rm -rf "$extra_dir"
  done
  teardown_test_project
}

@test "reset: fails in uninitialized directory" {
  local no_init_dir
  no_init_dir="$(mktemp -d)"
  EXTRA_DIRS+=("$no_init_dir")
  cd "$no_init_dir"

  run shogun reset -y
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "reset: does nothing on No answer to prompt" {
  _seed_command_queue "テストタスク"
  local before
  before="$(cat .shogun/queue/shogun_to_karo.yaml)"

  run bash -c "printf 'n\n' | shogun reset"
  [ "$status" -eq 0 ]
  [[ "$output" == *"キャンセル"* ]]

  local after
  after="$(cat .shogun/queue/shogun_to_karo.yaml)"
  [ "$after" = "$before" ]
}

@test "reset: does nothing on empty answer (default No)" {
  _seed_command_queue "テストタスク"
  local before
  before="$(cat .shogun/queue/shogun_to_karo.yaml)"

  run bash -c "printf '\n' | shogun reset"
  [ "$status" -eq 0 ]
  [[ "$output" == *"キャンセル"* ]]

  local after
  after="$(cat .shogun/queue/shogun_to_karo.yaml)"
  [ "$after" = "$before" ]
}

@test "reset -y: resets shogun_to_karo.yaml to commands: []" {
  _seed_command_queue "テストタスク"

  run shogun reset -y
  [ "$status" -eq 0 ]

  run cat .shogun/queue/shogun_to_karo.yaml
  [ "$output" = "commands: []" ]
}

@test "reset -y: resets inbox files to messages: []" {
  run shogun reset -y
  [ "$status" -eq 0 ]

  run cat .shogun/queue/inbox/taisho.yaml
  [ "$output" = "messages: []" ]

  run cat .shogun/queue/inbox/ashigaru1.yaml
  [ "$output" = "messages: []" ]
}

@test "reset -y: resets tasks files to tasks: []" {
  run shogun reset -y
  [ "$status" -eq 0 ]

  run cat .shogun/queue/tasks/ashigaru1.yaml
  [ "$output" = "tasks: []" ]
}

@test "reset -y: resets report files to reports: []" {
  run shogun reset -y
  [ "$status" -eq 0 ]

  run cat .shogun/queue/reports/ashigaru1_report.yaml
  [ "$output" = "reports: []" ]
}

@test "reset -y: resets review files to reviews: []" {
  run shogun reset -y
  [ "$status" -eq 0 ]

  run cat .shogun/queue/reviews/ashigaru1_review.yaml
  [ "$output" = "reviews: []" ]
}

@test "reset -y: clears project-specific queue subtree" {
  # SHOGUN_PROJECT_ID 経由で書かれる project 別キュー（残ると古い状態が再利用される）
  local proj_dir=".shogun/queue/projects/myproject"
  mkdir -p "${proj_dir}/inbox" "${proj_dir}/reports"
  printf 'messages:\n  - id: msg_old\n    status: unread\n' > "${proj_dir}/inbox/taisho.yaml"
  printf 'reports:\n  - id: rep_old\n' > "${proj_dir}/reports/ashigaru1_report.yaml"

  run shogun reset -y
  [ "$status" -eq 0 ]

  [ ! -e ".shogun/queue/projects/myproject" ]
}

@test "reset --yes: resets queue (long form option)" {
  _seed_command_queue "テストタスク"

  run shogun reset --yes
  [ "$status" -eq 0 ]

  run cat .shogun/queue/shogun_to_karo.yaml
  [ "$output" = "commands: []" ]
}

@test "reset -y: removes /tmp idle flags" {
  local root_key
  root_key="$(test_flag_root_key "${SHOGUN_ROOT}")"
  local flag_idle="/tmp/shogun_idle_${root_key}_taisho"
  touch "$flag_idle"

  run shogun reset -y
  [ "$status" -eq 0 ]

  [ ! -f "$flag_idle" ]
}

@test "reset -y: removes /tmp reports_pending flags" {
  local root_key
  root_key="$(test_flag_root_key "${SHOGUN_ROOT}")"
  local flag_pending="/tmp/shogun_reports_pending_${root_key}_karo"
  touch "$flag_pending"

  run shogun reset -y
  [ "$status" -eq 0 ]

  [ ! -f "$flag_pending" ]
}

@test "reset -y: removes /tmp flags with project_id prefix" {
  local root_key
  root_key="$(test_flag_root_key "${SHOGUN_ROOT}")"
  local flag_with_pid="/tmp/shogun_idle_${root_key}_myproject_ashigaru1"
  touch "$flag_with_pid"

  run shogun reset -y
  [ "$status" -eq 0 ]

  [ ! -f "$flag_with_pid" ]
}

@test "reset -y: kills tmux sessions if running" {
  local project_name session
  project_name="$(basename "${TEST_PROJECT}")"
  session="$(test_session_name "$project_name" "$TEST_PROJECT")"

  tmux new-session -d -s "$session"

  run shogun reset -y
  [ "$status" -eq 0 ]

  run tmux has-session -t "=${session}"
  [ "$status" -ne 0 ]
}

@test "reset -y: succeeds even when sessions are not running" {
  run shogun reset -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"リセット完了"* ]]
}

@test "reset -y: deletes SQLite queue database" {
  # MCP 移行後: inbox は queue.db に書かれるため reset で削除される必要がある
  node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" inbox_send \
    "--root=${TEST_PROJECT}" "--from=karo" "--to=taisho" "--subject=old-msg" 2>/dev/null
  [ -f ".shogun/queue/queue.db" ]

  run shogun reset -y
  [ "$status" -eq 0 ]
  [ ! -f ".shogun/queue/queue.db" ]
}

@test "start --clean: deletes SQLite queue database before restart" {
  # --clean もリセット相当なので queue.db を消去する必要がある
  local stub_bin="${TEST_PROJECT}/stub-bin-clean"
  mkdir -p "$stub_bin"
  cat > "${stub_bin}/tmux" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "${stub_bin}/tmux"
  local orig_path="$PATH"
  export PATH="${stub_bin}:${PATH}"

  node "${SHOGUN_REPO}/packages/mcp-queue/cli.js" inbox_send \
    "--root=${TEST_PROJECT}" "--from=karo" "--to=taisho" "--subject=old-msg" 2>/dev/null
  [ -f ".shogun/queue/queue.db" ]

  run shogun start --clean --setup
  [ "$status" -eq 0 ]
  export PATH="$orig_path"
  [ ! -f ".shogun/queue/queue.db" ]
}
