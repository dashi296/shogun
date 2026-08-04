# agmsg tmux 1セッション統合・通信層配線 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `shogun start`をtmux 1セッション構成に変更してTaishoのみを常駐起動し、Taisho/Karoがオンデマンドでspawnできる`shogun spawn <role>`サブコマンドを提供し、`shogun task`をagmsg送信経由に置き換える。

**Architecture:** Karo/Gunshi/Metsuke/Ashigaruを起こす判断はエージェント自身（LLM）が行う。Bash側（`bin/shogun`）はTaishoの起動と、エージェントが呼び出す決定的な補助コマンド（`shogun spawn`、run_id状態管理）だけを提供する。

**Tech Stack:** Bash（`set -euo pipefail`、`bin/shogun`はエントリポイント）、bats、既存の`scripts/agmsg_adapter.sh`（計画1で実装済み）。

## Global Constraints

- 役職名・team名・agent名は `^[A-Za-z0-9_-]+$` でバリデーションする。
- エントリポイントスクリプト（`bin/shogun`）は `set -euo pipefail` の下で動く。source専用ライブラリ（新設する `scripts/agmsg_run_state.sh` を含む）は `set` 行を持たず、644パーミッションとする（`scripts/flag_names.sh`/`scripts/agmsg_adapter.sh` の既存規約）。
- agmsgの呼び出しは必ず `scripts/agmsg_adapter.sh` のアダプタ関数（`agmsg_join`/`agmsg_send`/`agmsg_spawn`/`agmsg_get_placement`等）経由で行い、agmsgの生スクリプトパスを直接組み立てない。
- YAML操作は既存の `node_yaml` ヘルパー経由で行う。
- テストは `tests/unit/` に bats で単体、`tests/integration/` に bats で統合（fake tmux/fake agmsg）を追加する。
- 対応 agmsg バージョンは commit `1c7efbc005c50a7eb3cbd4bac9b1f6ab17825827`（`v1.1.12` 系）に固定（計画1と同じ）。

---

### Task 1: run_id 状態管理ヘルパー

**Files:**
- Create: `scripts/agmsg_run_state.sh`
- Create: `tests/unit/agmsg_run_state.bats`

**Interfaces:**
- Consumes: `SHOGUN_ROOT` 環境変数（既存、`bin/shogun` が export 済み）
- Produces:
  - `agmsg_run_state_new_run()` — 新しい run_id（UUID）を発行し、`fresh_done/` マーカーを全消去し、標準出力に新しい run_id を返す。exit 0 固定。
  - `agmsg_run_state_current()` — 現在の run_id を標準出力に返す（未発行なら空文字）。exit 0 固定。
  - `agmsg_run_state_fresh_needed(role)` — `role` の fresh spawn が今回の run で未成立なら exit 0、成立済みなら exit 1、`role` が不正なら exit 2。
  - `agmsg_run_state_mark_fresh_done(role)` — `role` の fresh spawn 成立を記録する。`role` が不正なら exit 2、それ以外は exit 0。

- [ ] **Step 1: Write the failing test**

```bash
cat > tests/unit/agmsg_run_state.bats <<'EOF'
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
EOF
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/bats/bin/bats tests/unit/agmsg_run_state.bats`
Expected: FAIL — `scripts/agmsg_run_state.sh` は存在せず `source` がエラーになる（全テスト失敗）。

- [ ] **Step 3: Write minimal implementation**

```bash
cat > scripts/agmsg_run_state.sh <<'EOF'
#!/usr/bin/env bash
# shogun start の実行（run）ごとの状態管理。
#
# Taisho/Karo が agmsg spawn 時に --fresh を付けるべきか判定するために使う
# （docs/superpowers/specs/2026-08-02-agmsg-orchestration-design.md §8「resume と
# --fresh の使い分け」参照）。run_id は shogun start のたびに発行し直し、
# 役職ごとの「この run で fresh spawn が成立済みか」フラグをマーカーファイルで
# 管理する。
#
# このファイルは source して使う（実行しない）。

_agmsg_run_state_dir() {
  printf '%s/.shogun/state' "${SHOGUN_ROOT:?SHOGUN_ROOT required}"
}

# 新しい run を開始する: run_id を新規発行し、前回の run の fresh_done マーカーを
# 全消去する。標準出力に新しい run_id を返す。
agmsg_run_state_new_run() {
  local dir
  dir="$(_agmsg_run_state_dir)"
  mkdir -p "${dir}/fresh_done"
  rm -f "${dir}"/fresh_done/*
  local run_id
  run_id="$(node -e 'process.stdout.write(require("crypto").randomUUID())')"
  printf '%s' "$run_id" > "${dir}/run_id"
  printf '%s' "$run_id"
}

# 現在の run_id を返す（未発行なら空文字）。
agmsg_run_state_current() {
  local file
  file="$(_agmsg_run_state_dir)/run_id"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    printf ''
  fi
}

# role の fresh spawn が今回の run でまだ成立していなければ exit 0（--fresh が
# 必要）、成立済みなら exit 1。role が不正なら exit 2。
agmsg_run_state_fresh_needed() {
  local role="${1:?role required}"
  [[ "$role" =~ ^[A-Za-z0-9_-]+$ ]] || return 2
  local marker
  marker="$(_agmsg_run_state_dir)/fresh_done/${role}"
  [[ ! -f "$marker" ]]
}

# role の fresh spawn が成立したことを記録する。role が不正なら exit 2。
agmsg_run_state_mark_fresh_done() {
  local role="${1:?role required}"
  [[ "$role" =~ ^[A-Za-z0-9_-]+$ ]] || return 2
  local dir
  dir="$(_agmsg_run_state_dir)"
  mkdir -p "${dir}/fresh_done"
  : > "${dir}/fresh_done/${role}"
}
EOF
chmod 644 scripts/agmsg_run_state.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `tests/bats/bin/bats tests/unit/agmsg_run_state.bats`
Expected: PASS（8 tests, 0 failures）

- [ ] **Step 5: Commit**

```bash
git add scripts/agmsg_run_state.sh tests/unit/agmsg_run_state.bats
git commit -m "feat(agmsg): run_id状態管理ヘルパー(agmsg_run_state.sh)を追加"
```

---

### Task 2: team命名関数と `shogun init` でのsystem identity登録

**Files:**
- Modify: `bin/shogun`（`project_agmsg_team_name` 関数、`cmd_init` への登録処理追加）
- Create: `tests/unit/agmsg_team_name.bats`
- Modify: `tests/integration/init.bats`（system identity登録のテスト追加）

**Context:** agmsg の `join.sh` は `<type>` を `scripts/drivers/types/<name>/type.conf` に登録済みの既知の type に限定する（未知の type は exit 1 で拒否される）。`shogun` という送信専用の system identity には、agmsg 自身が「デスクトップアプリ等、spawn不可・monitor不可の人間側identity」向けに用意している `agmsg-app` type（`spawnable=no`, `monitor=no`, `delivery_modes=off`）を使う。これは commit `1c7efbc005c...` の `scripts/drivers/types/agmsg-app/type.conf` で確認済み。

**Interfaces:**
- Consumes: `project_safe_name()`・`project_root_hash()`（既存、`bin/shogun` 内 131行目付近）、`agmsg_join()`（計画1、`scripts/agmsg_adapter.sh`）、`read_agmsg_cmd_name()`（計画1、`bin/shogun`）
- Produces: `project_agmsg_team_name(project_name, project_root)` — agmsg team名を1つ返す文字列関数。

- [ ] **Step 1: Write the failing test**

```bash
cat > tests/unit/agmsg_team_name.bats <<'EOF'
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
EOF
```

Note: 3つ目のテストは Task 3 で新設する `project_session_name`（単数形、1セッション名を返す関数）を参照する。Task 2 の時点ではこの関数がまだ存在しないため、3つ目のテストは Task 3 完了まで failing のままでよい（Step 2 ではこのテストの失敗理由が「関数が無い」であることも許容する）。

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/bats/bin/bats tests/unit/agmsg_team_name.bats`
Expected: FAIL — `project_agmsg_team_name` が存在せず、1つ目・2つ目のテストが失敗する（3つ目は `project_session_name` 未定義でも失敗するが、これは想定内）。

- [ ] **Step 3: Write minimal implementation**

`bin/shogun` の `project_session_names()` 関数（131行目付近、`# project_name と SHOGUN_ROOT から Shogun が管理する tmux セッション名を生成` の直前）の直後に追加する:

```bash
# project_name と SHOGUN_ROOT から agmsg team 名を生成する
# （tmux セッション名とは別の命名空間。他プロジェクトとの衝突防止に
# project_safe_name/project_root_hash を再利用する）。
project_agmsg_team_name() {
  local project_name="$1"
  local project_root="$2"
  local safe_name root_hash
  safe_name="$(project_safe_name "$project_name")" || return 1
  root_hash="$(project_root_hash "$project_root")"
  printf '%s-%s' "${safe_name}" "${root_hash}"
}
```

次に、`cmd_init()` の末尾（`success "初期化完了! プロジェクト: ${project_name}"` の直前、`.claude/settings.json` へのフックマージ処理の後）に追加する:

```bash
  # agmsg team への shogun system identity 登録。
  # agmsg が未導入でも shogun init 自体は使えるよう、失敗しても継続する
  # （shogun doctor で後から確認できる）。
  # shellcheck source=scripts/agmsg_adapter.sh
  source "${SHOGUN_BIN_DIR}/scripts/agmsg_adapter.sh"
  local _agmsg_cmd_name _agmsg_team
  _agmsg_cmd_name="$(read_agmsg_cmd_name "${shogun_dir}/config.yaml")"
  _agmsg_team="$(project_agmsg_team_name "$project_name" "$project_dir")"
  if agmsg_join "$_agmsg_cmd_name" "$_agmsg_team" shogun agmsg-app "$project_dir" 2>/dev/null; then
    info "agmsg team '${_agmsg_team}' に shogun を登録しました。"
  else
    warn "agmsg team への登録に失敗しました（agmsg が未導入の可能性があります）。shogun doctor で確認してください。"
  fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `tests/bats/bin/bats tests/unit/agmsg_team_name.bats`
Expected: 1つ目・2つ目は PASS。3つ目は `project_session_name: command not found` で FAIL のまま（Task 3 で解消される想定通りの状態）。この時点で 2/3 PASS であることを確認する。

- [ ] **Step 5: Add and verify the init integration test**

`tests/integration/init.bats` に追記する:

```bash
cat >> tests/integration/init.bats <<'EOF'

@test "init: registers shogun as an agmsg system identity when agmsg is not installed" {
  run shogun init
  [ "$status" -eq 0 ]
  [[ "$output" == *"agmsg"* ]]
}
EOF
```

Run: `tests/bats/bin/bats tests/integration/init.bats`
Expected: PASS（agmsg が未導入の環境でも `shogun init` は exit 0 で継続し、出力に "agmsg" を含む警告が出ることを確認する）。

- [ ] **Step 6: Commit**

```bash
git add bin/shogun tests/unit/agmsg_team_name.bats tests/integration/init.bats
git commit -m "feat(agmsg): agmsg team命名とshogun system identity登録をinitに追加"
```

---

### Task 3: tmuxセッションを1つに統合（セッション名ヘルパーの置き換え）

**Files:**
- Modify: `bin/shogun`（`project_session_names`→`project_session_name`、全呼び出し箇所）

**Context:** agmsg の `spawn.sh` は tmux 経由の場合、呼び出し元の現在の window/session にしか spawn できないため、`taisho-*`/`multiagent-*` の2セッション構成を1セッション（`shogun-<safe_name>-<hash>`）に統合する。この Task では「名前解決の一本化」と「既存の2セッション前提コードを1セッション前提へ機械的に置き換える」ことに集中し、実際にどのペインを起動するか（Taishoのみにする等）は Task 4 で扱う。

**Interfaces:**
- Consumes: `project_safe_name()`・`project_root_hash()`（既存）
- Produces: `project_session_name(project_name, project_root)` — 単一のtmuxセッション名を返す（`project_session_names`の複数形版を置き換える）。

- [ ] **Step 1: Write the failing test**

```bash
cat > tests/unit/project_session_name.bats <<'EOF'
#!/usr/bin/env bats
# Unit tests for project_session_name (bin/shogun) — 1セッション統合後の命名

load '../test_helper'

setup() {
  TEST_ROOT="$(mktemp -d)"
}

teardown() {
  rm -rf "${TEST_ROOT}"
}

@test "project_session_name: returns a single 'shogun-' prefixed session name" {
  run bash -c "source '${SHOGUN_REPO}/bin/shogun' 2>/dev/null; project_session_name 'my project' '${TEST_ROOT}'"
  [ "$status" -eq 0 ]
  [[ "$output" == shogun-my_project-* ]]
  # 空白を含まない（1つの tmux セッション名として妥当）
  [[ "$output" != *" "* ]]
}

@test "project_session_name: is stable for the same project_name and root" {
  local a b
  a="$(bash -c "source '${SHOGUN_REPO}/bin/shogun' 2>/dev/null; project_session_name 'proj' '${TEST_ROOT}'")"
  b="$(bash -c "source '${SHOGUN_REPO}/bin/shogun' 2>/dev/null; project_session_name 'proj' '${TEST_ROOT}'")"
  [ "$a" = "$b" ]
}
EOF
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/bats/bin/bats tests/unit/project_session_name.bats`
Expected: FAIL — `project_session_name` が存在しない（`project_session_names` の複数形しかない）。

- [ ] **Step 3: Write minimal implementation**

`bin/shogun` の `project_session_names()` 関数を、以下の単数形の実装に**置き換える**（関数名を変更し、返り値を1つにする）:

```bash
# project_name と SHOGUN_ROOT から Shogun が管理する tmux セッション名を生成する
# （1セッション構成。agmsg の spawn は呼び出し元の現在 session にしか
# spawn できないため、Taisho も含め全役職が同一セッション内に配置される）。
project_session_name() {
  local project_name="$1"
  local project_root="$2"
  local safe_name root_hash
  safe_name="$(project_safe_name "$project_name")" || return 1
  root_hash="$(project_root_hash "$project_root")"
  printf "shogun-%s-%s" "${safe_name}" "${root_hash}"
}
```

`legacy_project_session_names()` はそのまま残す（`--legacy-cleanup`/`--legacy` オプションが旧2セッション構成の掃除に引き続き使うため、変更しない）。

続けて、以下の既存呼び出し箇所をすべて「1セッション名を受け取る形」に書き換える。

**1. `stop_project_watchers()`（155行目付近）**: 引数を `session` 1つに変更する。

```bash
stop_project_watchers() {
  local session="$1" root="$2"
  # inbox_watcher.sh はペイン引数にセッション名（ハッシュ込み）を含む
  pkill -f "inbox_watcher\.sh .*${session}" 2>/dev/null || true
  # fswatch は監視対象パスに <root>/.shogun/queue を含む（dot を正規表現エスケープ）
  local root_re="${root//./\\.}"
  pkill -f "fswatch .*${root_re}/\.shogun/queue" 2>/dev/null || true
}
```

**2. `stop_sessions_and_watchers()`（170行目付近）**:

```bash
stop_sessions_and_watchers() {
  local include_legacy="${1:-0}"
  local project_name
  project_name="$(read_project_name "${SHOGUN_ROOT}/.shogun/config.yaml")"
  local session
  session="$(project_session_name "$project_name" "$SHOGUN_ROOT")" || return 1

  local sessions=("$session")
  if [[ "$include_legacy" -eq 1 ]]; then
    local legacy_session_taisho legacy_session_multi
    read -r legacy_session_taisho legacy_session_multi <<< "$(legacy_project_session_names "$project_name")" || return 1
    sessions+=("$legacy_session_taisho" "$legacy_session_multi")
  fi

  _SHOGUN_STOPPED_COUNT=0
  local s
  for s in "${sessions[@]}"; do
    if tmux kill-session -t "$(tmux_exact_target "$s")" 2>/dev/null; then
      info "セッション ${s} を終了しました。"
      _SHOGUN_STOPPED_COUNT=$(( _SHOGUN_STOPPED_COUNT + 1 ))
    else
      info "セッション ${s} は停止済みです。"
    fi
  done

  stop_project_watchers "$session" "$SHOGUN_ROOT"
}
```

**3. `cmd_attach()`（856行目付近）**: `multi`/`multiagent` ターゲットを廃止し、単一セッションへの attach のみにする。

```bash
cmd_attach() {
  require_init

  local config_file="${SHOGUN_ROOT}/.shogun/config.yaml"
  local project_name
  project_name="$(read_project_name "$config_file")"

  local session
  session="$(project_session_name "$project_name" "$SHOGUN_ROOT")" || exit 1

  if ! tmux has-session -t "$(tmux_exact_target "$session")" 2>/dev/null; then
    error "セッション ${session} が見つかりません。"
    echo "       先に shogun start を実行してください。"
    exit 1
  fi

  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$(tmux_exact_target "$session")"
  else
    exec tmux attach-session -t "$(tmux_exact_target "$session")"
  fi
}
```

**4. `cmd_status()`（1015行目付近）**: `session_taisho`/`session_multi` の2行表示を、単一セッションの1行表示に変更する。

```bash
  local session
  session="$(project_session_name "$project_name" "$SHOGUN_ROOT")" || exit 1
```
（`local session_taisho session_multi` の宣言行と `read -r session_taisho session_multi <<< ...` を上記に置き換える）

```bash
  # tmux セッション稼働確認
  echo -e "${BOLD}[ tmux セッション ]${RESET}"

  if tmux has-session -t "$(tmux_exact_target "$session")" 2>/dev/null; then
    echo -e "  ${GREEN}●${RESET} ${session} (稼働中)"
  else
    echo -e "  ${RED}○${RESET} ${session} (停止)"
  fi
```
（既存の `session_taisho`/`session_multi` それぞれの `if tmux has-session ...` ブロック2つを、上記の1ブロックに置き換える）

**5. `cmd_doctor()` の `[ tmux セッション ]` セクション（1245行目付近）**:

```bash
  echo ""
  echo -e "${BOLD}[ tmux セッション ]${RESET}"
  if SHOGUN_ROOT="$(find_shogun_root 2>/dev/null)"; then
    local config_file="${SHOGUN_ROOT}/.shogun/config.yaml"
    if [[ -f "$config_file" ]]; then
      local project_name
      project_name="$(read_project_name "$config_file" 2>/dev/null || echo "shogun")"
      local s
      s="$(project_session_name "$project_name" "$SHOGUN_ROOT")"
      if tmux has-session -t "$(tmux_exact_target "$s")" 2>/dev/null; then
        echo -e "  ${GREEN}●${RESET} ${s} (稼働中)"
      else
        echo -e "  ${RED}○${RESET} ${s} (停止)"
      fi
    else
      echo -e "  ${YELLOW}!${RESET} config.yaml が見つかりません"
    fi
  else
    echo -e "  ${YELLOW}!${RESET} .shogun/ が見つかりません"
  fi
```
（既存の `s1`/`s2` 2行版ブロックを上記に置き換える。既存コードの `if/else` 構造・インデントは維持し、中身だけ単一セッション版にする）

**6. `cmd_start()`（693行目付近の宣言と694行目の呼び出し）**: この時点では宣言だけ更新し、実際のセッション作成ロジックの書き換えは Task 4 で行う。

```bash
  local session
  session="$(project_session_name "$project_name" "$SHOGUN_ROOT")" || exit 1
```

（`local session_taisho session_multi` と `read -r session_taisho session_multi <<< ...` の行を上記に置き換えるが、この Task の時点では 767 行目以降の `$session_taisho`/`$session_multi` を使う本体コードはまだ書き換えない。Task 4 で本体ごと書き換えるため、この Task では `cmd_start` 内で一時的に `session_taisho="$session"` のように前方互換のダミー代入を追加して、既存コードが動くようにする）

```bash
  local session
  session="$(project_session_name "$project_name" "$SHOGUN_ROOT")" || exit 1
  local session_taisho="$session" session_multi="$session"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `tests/bats/bin/bats tests/unit/project_session_name.bats tests/unit/agmsg_team_name.bats`
Expected: PASS（`project_session_name.bats` 2 tests、`agmsg_team_name.bats` 3 tests、計 5 tests, 0 failures — Task 2 で保留していた3つ目のテストもここで解消される）。

続けて既存の統合テスト一式が壊れていないか確認する:

Run: `tests/bats/bin/bats tests/integration`
Expected: 一部の既存テスト（`attach.bats`・`status.bats`・`start.bats` 内で `multiagent-`/`taisho-` という文字列や `session_multi` を直接アサートしているもの）が FAIL する可能性がある。FAIL したテストは、この Task の変更に合わせて `shogun-<name>-<hash>` という新しいセッション名・「1セッションのみ」という前提にテスト内容を更新する（`grep -rn "multiagent-\|taisho-.*multi\|attach multi" tests/integration/` で該当箇所を洗い出すこと）。既存テストの意図（何を検証しているか）は保ったまま、アサート対象の文字列・セッション数だけを更新する。

- [ ] **Step 5: Commit**

```bash
git add bin/shogun tests/unit/project_session_name.bats tests/integration/
git commit -m "refactor(session): tmuxセッション名を1セッション構成(project_session_name)に統合"
```

---

### Task 4: `cmd_start` を1セッション化しTaishoのみ起動する

**Files:**
- Modify: `bin/shogun`（`cmd_start()` の本体書き換え）
- Modify: `tests/integration/start.bats`

**Context:** `cmd_start()` は現在、`taisho-*` セッションに Taisho を、`multiagent-*` セッションに Karo/Gunshi/Metsuke/Ashigaru×N を一括起動している。この Task で、単一の `shogun-*` セッションに Taisho のみを起動する形に書き換える。Taisho の agmsg join（最小版、readiness の堅牢化は行わない）もここで行う。Karo 以下の起動は行わない（Task 5 の `shogun spawn` をエージェントが後で呼ぶ）。

**Interfaces:**
- Consumes: `project_session_name()`（Task 3）、`agmsg_join()`/`agmsg_set_delivery()`（計画1）、`agmsg_run_state_new_run()`（Task 1）、`read_agmsg_cmd_name()`（計画1）、`project_agmsg_team_name()`（Task 2）
- Produces: `cmd_start()` の新しい振る舞い（Taishoのみ起動）。`shogun spawn`（Task 5）はこの Task が発行する run_id 状態に依存する。

- [ ] **Step 1: Write the failing test**

`tests/integration/start.bats` の既存テストのうち、`multiagent-*` セッションへの Karo/Gunshi/Metsuke/Ashigaru 起動を前提にしたもの（`inbox_watcher.sh karo `・`inbox_watcher.sh gunshi ` 等への `SHOGUN_REPORT_SOURCES` 検証）はこの Task で廃止対象になる。まず新しい期待動作のテストを追加する:

```bash
cat >> tests/integration/start.bats <<'EOF'

@test "start: creates exactly one tmux session (no multiagent session)" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep -c "^new-session " "$TMUX_LOG"
  [ "$output" = "1" ]
}

@test "start: does not spawn inbox_watcher for karo/gunshi/metsuke/ashigaru at startup" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "inbox_watcher.sh karo \|inbox_watcher.sh gunshi \|inbox_watcher.sh metsuke \|inbox_watcher.sh ashigaru" "$TMUX_LOG"
  [ "$status" -ne 0 ]
}

@test "start: does not launch inbox_watcher for taisho either (superseded by agmsg monitor)" {
  _stub_tmux
  run shogun start --setup
  [ "$status" -eq 0 ]

  run grep "inbox_watcher.sh taisho " "$TMUX_LOG"
  [ "$status" -ne 0 ]
}
EOF
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/bats/bin/bats tests/integration/start.bats`
Expected: FAIL — 新規3テストが失敗する（現行の `cmd_start` はまだ `multiagent-*` セッションを作り、Taisho含む全役職で `inbox_watcher.sh` を起動しているため）。

- [ ] **Step 3: Write minimal implementation**

`bin/shogun` の `cmd_start()` を以下の内容に書き換える（`local session` の宣言以降、関数末尾までを丸ごと置き換える。Task 3 の Step 3 で追加した `session_taisho="$session" session_multi="$session"` のダミー代入は削除する）:

```bash
  local session
  session="$(project_session_name "$project_name" "$SHOGUN_ROOT")" || exit 1

  info "プロジェクト: ${project_name}"
  info "Taisho モデル: ${taisho_model} / Worker モデル: ${worker_model}"

  # --clean: バックアップ & キューリセット
  if [[ "$do_clean" == "true" ]]; then
    local backup_dir
    backup_dir="${SHOGUN_ROOT}/.shogun/logs/backup_$(date +%Y%m%d_%H%M%S)"
    info "--clean: キューを ${backup_dir} にバックアップ"
    mkdir -p "$backup_dir"
    cp -r "${SHOGUN_ROOT}/.shogun/queue/." "${backup_dir}/"

    reset_queue_files "$ashigaru_count"
    success "キューをリセットしました。"
  fi

  # 既存セッションと孤児 watcher を停止
  local _include_legacy_int=0
  [[ "$legacy_cleanup" == "true" ]] && _include_legacy_int=1
  _SHOGUN_STOPPED_COUNT=0
  stop_sessions_and_watchers "$_include_legacy_int"

  # claude コマンドのオプション
  local claude_opts=""
  if [[ "$skip_permissions" == "true" ]]; then
    claude_opts="--dangerously-skip-permissions"
  fi

  # SHOGUN_PROJECT_ID が設定されている場合は環境変数として伝播させる
  local project_id_env=""
  if [[ -n "${SHOGUN_PROJECT_ID:-}" ]]; then
    project_id_env="SHOGUN_PROJECT_ID=${SHOGUN_PROJECT_ID} "
  fi

  # MCP サーバを Taisho 用だけ起動する（Karo 以下はオンデマンド spawn 時に
  # 別途起動する。Karo 以下の MCP 起動は計画外のスコープとし、現時点では
  # Taisho の既存 MCP 構成のみ維持する）。
  info "MCP サーバを起動中..."
  bash "${SHOGUN_BIN_DIR}/scripts/mcp_manager.sh" start \
    "taisho" "$SHOGUN_ROOT" "karo" 2>/dev/null || {
      error "MCP サーバの起動に失敗しました: taisho"
      exit 1
    }
  success "MCP サーバを起動しました。"

  # 新しい run_id を発行する（shogun spawn の --fresh 判定に使う）。
  # shellcheck source=scripts/agmsg_run_state.sh
  source "${SHOGUN_BIN_DIR}/scripts/agmsg_run_state.sh"
  local run_id
  run_id="$(agmsg_run_state_new_run)"
  info "run_id: ${run_id}"

  # agmsg: Taisho の最小 join（readiness の堅牢化は別issueで行う）。
  # shellcheck source=scripts/agmsg_adapter.sh
  source "${SHOGUN_BIN_DIR}/scripts/agmsg_adapter.sh"
  local _agmsg_cmd_name _agmsg_team
  _agmsg_cmd_name="$(read_agmsg_cmd_name "$config_file")"
  _agmsg_team="$(project_agmsg_team_name "$project_name" "$SHOGUN_ROOT")"
  if agmsg_join "$_agmsg_cmd_name" taisho claude-code "$SHOGUN_ROOT" 2>/dev/null &&
     agmsg_set_delivery "$_agmsg_cmd_name" set monitor claude-code "$SHOGUN_ROOT" 2>/dev/null; then
    info "agmsg: taisho をチーム '${_agmsg_team}' に登録しました（monitor配信）。"
  else
    warn "agmsg: taisho の登録に失敗しました（agmsg が未導入の可能性があります）。shogun doctor で確認してください。"
  fi

  # ─── shogun-<safe_name>-<hash> セッション（Taisho のみ、1ペイン）
  tmux new-session -d -s "$session" -x 220 -y 50
  tmux set-option -t "$session" status-style "bg=magenta,fg=white"
  tmux set-option -t "$session" pane-border-status top 2>/dev/null || true
  tmux set-option -t "$session" pane-border-format " #[fg=#{@shogun_color},bold]#{@shogun_role}#[default] │ #{pane_title} " 2>/dev/null || true

  local taisho_pane="${session}:0"
  _set_pane_role_label "$taisho_pane" "taisho"

  if [[ "$setup_only" == "false" ]]; then
    local taisho_cmd taisho_mcp_cfg
    taisho_mcp_cfg="${SHOGUN_ROOT}/.shogun/mcp/taisho.json"
    taisho_cmd="cd ${SHOGUN_ROOT} && SHOGUN_ROLE=taisho SHOGUN_ROOT=${SHOGUN_ROOT} SHOGUN_BIN_DIR=${SHOGUN_BIN_DIR} ${project_id_env}claude --model ${taisho_model} ${claude_opts} --add-dir ${SHOGUN_ROOT}/.shogun --mcp-config ${taisho_mcp_cfg}"
    tmux send-keys -t "$taisho_pane" "$taisho_cmd" Enter
  fi

  echo ""
  success "Shogun 起動完了!"
  echo ""
  echo -e "  ${BOLD}セッションに接続:${RESET}"
  echo -e "  ${CYAN}shogun attach${RESET}"
  echo ""
  echo -e "  ${BOLD}タスク投入:${RESET}"
  echo -e "  ${CYAN}shogun task \"やること\"${RESET}"
}
```

`cmd_start()` の引数パース部分（`--count` オプション含む）はそのまま残してよい（`ashigaru_count`・`--count` は `shogun spawn` や将来の計画で引き続き使うため）。ただし `ashigaru_count`/`worker_model` を計算する既存の node_yaml 呼び出しはそのまま残す（Task 5 の `shogun spawn` が `worker_model` を必要とする）。

**削除する既存コード**:
- `pane_roles` 配列の構築、`_mcp_karo_sources`/`_mcp_all_roles` を使った Karo 以下への MCP 一括起動ループ、`multiagent-*` セッションの `tmux new-session`/`split-window` ループ、Karo 以下への `inbox_watcher.sh` 起動ループ、Karo 以下への `claude` 起動ループ——これらはすべて上記の書き換えで丸ごと削除する。
- `escalation_policy`（Agent Self-Watch）を読む `asw_raw`/`asw_enabled`/`asw_phase1`/`asw_phase2`/`asw_phase3`/`asw_check_interval`/`asw_env` の計算ブロック（`# escalation_policy（Agent Self-Watch）— 1回の node 呼び出しで全フィールドを取得` というコメントの付いたブロック、`local session` 宣言より前、`# --count オプションで上書き` の直前にある）も削除する。この値は `inbox_watcher.sh` 起動時にのみ渡していたが、この Task で `inbox_watcher.sh` を一切起動しなくなるため、削除しないと未使用変数（デッドコード）になる。

- [ ] **Step 4: Run test to verify it passes**

Run: `tests/bats/bin/bats tests/integration/start.bats`
Expected: 新規3テストが PASS。既存テストのうち、`inbox_watcher.sh` の起動を前提にしたもの——`SHOGUN_REPORT_SOURCES=karo をtaisho watcherに渡す`等、および `SHOGUN_ASW_ENABLED` を watcher に渡すことを検証する3テスト（`start: passes SHOGUN_ASW_ENABLED=false to taisho watcher by default`・`start: passes SHOGUN_ASW_ENABLED=false to worker watchers by default`・`start: passes SHOGUN_ASW_ENABLED=true when escalation_policy.enabled is true`）——は、この Task により意味を失うため削除する（`inbox_watcher.sh` 自体をもう起動しないため）。該当する既存テストを削除し、削除後に残るテスト全体を実行して PASS することを確認する。

- [ ] **Step 5: Run the full suite and commit**

Run: `tests/bats/bin/bats tests/unit tests/integration`
Expected: PASS（全件）。回帰があれば、Task 1〜3 の変更ではなく Task 4 の `cmd_start` 書き換えに起因する箇所（`cmd_reset`・`cmd_stop` 等、`stop_sessions_and_watchers`/MCP停止を経由する既存テスト）を確認し、必要なら該当テストも新しい1セッション・Taisho単独起動の前提に更新する。

```bash
git add bin/shogun tests/integration/start.bats
git commit -m "feat(start): shogun startを1セッション化しTaishoのみ起動するよう書き換え"
```

---

### Task 5: `shogun spawn <role>` サブコマンド

**Files:**
- Modify: `bin/shogun`（`cmd_spawn()` 新設、ディスパッチへの追加、ヘルプ更新）
- Create: `tests/integration/spawn.bats`

**Context:** Taisho/Karo が部下を起こす際に呼ぶ、決定的なラッパー。モデル選択・`--fresh` 判定・pane label付けを担う。agmsg 呼び出し自体は fake `agmsg_spawn`/`agmsg_get_placement`（`scripts/agmsg_adapter.sh` の関数をテストでオーバーライドする）でテストする。

**Interfaces:**
- Consumes: `agmsg_spawn()`・`agmsg_get_placement()`（計画1）、`agmsg_run_state_fresh_needed()`・`agmsg_run_state_mark_fresh_done()`（Task 1）、`project_agmsg_team_name()`（Task 2）、`_set_pane_role_label()`（既存）、`read_agmsg_cmd_name()`（計画1）
- Produces: `cmd_spawn()` — `shogun spawn <role> [--boot-prompt TEXT]`

- [ ] **Step 1: Write the failing test**

```bash
cat > tests/integration/spawn.bats <<'EOF'
#!/usr/bin/env bats
# Integration tests for shogun spawn

load '../test_helper'

setup() {
  init_test_project
  cd "${TEST_PROJECT}"
  shogun start --setup >/dev/null 2>&1

  # agmsg_adapter.sh の関数を fake に差し替える。
  # AGMSG_SPAWN_LOG に呼び出し引数を記録し、常に成功して固定の placement を返す。
  export AGMSG_SPAWN_LOG="${TEST_PROJECT}/agmsg_spawn.log"
  : > "$AGMSG_SPAWN_LOG"
  local fake_dir="${TEST_PROJECT}/fake-adapter"
  mkdir -p "$fake_dir"
  cat > "${fake_dir}/agmsg_adapter.sh" <<'FAKE'
agmsg_spawn() {
  echo "spawn $*" >> "${AGMSG_SPAWN_LOG}"
}
agmsg_get_placement() {
  printf '%%1\t/proj\tclaude-code\n'
}
FAKE
  export SHOGUN_FAKE_AGMSG_ADAPTER="${fake_dir}/agmsg_adapter.sh"

  _stub_tmux
}

teardown() {
  teardown_test_project
}

_stub_tmux() {
  local stub_bin="${TEST_PROJECT}/stub-bin"
  mkdir -p "$stub_bin"
  export TMUX_LOG="${TEST_PROJECT}/tmux.log"
  : > "$TMUX_LOG"
  cat > "${stub_bin}/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
exit 0
STUB
  chmod +x "${stub_bin}/tmux"
  export PATH="${stub_bin}:${PATH}"
}

@test "spawn: rejects an invalid role name" {
  run shogun spawn "../evil"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "不正" ]]
}

@test "spawn: passes worker_model to agmsg_spawn" {
  run shogun spawn karo
  [ "$status" -eq 0 ]
  run grep -- "--model sonnet" "$AGMSG_SPAWN_LOG"
  [ "$status" -eq 0 ]
}

@test "spawn: uses --window for karo" {
  run shogun spawn karo
  [ "$status" -eq 0 ]
  run grep -- "--window" "$AGMSG_SPAWN_LOG"
  [ "$status" -eq 0 ]
}

@test "spawn: does not use --window for ashigaru1" {
  run shogun spawn ashigaru1
  [ "$status" -eq 0 ]
  run grep -- "--window" "$AGMSG_SPAWN_LOG"
  [ "$status" -ne 0 ]
}

@test "spawn: adds --fresh on the first spawn of a role in this run" {
  run shogun spawn karo
  [ "$status" -eq 0 ]
  run grep -- "--fresh" "$AGMSG_SPAWN_LOG"
  [ "$status" -eq 0 ]
}

@test "spawn: does not add --fresh on a second spawn of the same role in the same run" {
  shogun spawn karo >/dev/null
  : > "$AGMSG_SPAWN_LOG"
  run shogun spawn karo
  [ "$status" -eq 0 ]
  run grep -- "--fresh" "$AGMSG_SPAWN_LOG"
  [ "$status" -ne 0 ]
}
EOF
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/bats/bin/bats tests/integration/spawn.bats`
Expected: FAIL — `shogun spawn` コマンド自体が存在しない（`不明なコマンド: spawn`）。

- [ ] **Step 3: Write minimal implementation**

`bin/shogun` の `scripts/agmsg_adapter.sh` を source する箇所（Task 1〜4 で `cmd_doctor`/`cmd_init`/`cmd_start` それぞれがローカルに source している）と同じパターンで、`cmd_spawn()` 内でも source する。テストから fake アダプタへ差し替え可能にするため、source パスを `SHOGUN_FAKE_AGMSG_ADAPTER` 環境変数で上書きできるようにする。

`bin/shogun` の `cmd_stop()` の直前に追加する:

```bash
# ════════════════════════════════════════════════════════════
# shogun spawn <role> [--boot-prompt TEXT]
# ════════════════════════════════════════════════════════════
cmd_spawn() {
  require_init

  local role="${1:-}"
  shift || true
  local boot_prompt=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --boot-prompt)
        boot_prompt="${2:?--boot-prompt には値が必要です}"
        shift 2
        ;;
      *)
        error "不明なオプション: $1"
        exit 1
        ;;
    esac
  done

  if ! [[ "$role" =~ ^[A-Za-z0-9_-]+$ ]]; then
    error "不正な role: ${role}"
    exit 1
  fi

  # shellcheck source=scripts/agmsg_adapter.sh
  source "${SHOGUN_FAKE_AGMSG_ADAPTER:-${SHOGUN_BIN_DIR}/scripts/agmsg_adapter.sh}"
  # shellcheck source=scripts/agmsg_run_state.sh
  source "${SHOGUN_BIN_DIR}/scripts/agmsg_run_state.sh"

  local config_file="${SHOGUN_ROOT}/.shogun/config.yaml"
  local worker_model
  worker_model=$(node_yaml -e '
const yaml = require("js-yaml");
const d = yaml.load(require("fs").readFileSync(process.argv[1], "utf8")) || {};
process.stdout.write(String((d.agents && d.agents.worker_model) || "sonnet"));
' -- "$config_file")

  local project_name
  project_name="$(read_project_name "$config_file")"
  local _agmsg_cmd_name _agmsg_team
  _agmsg_cmd_name="$(read_agmsg_cmd_name "$config_file")"
  _agmsg_team="$(project_agmsg_team_name "$project_name" "$SHOGUN_ROOT")"

  local -a spawn_args=(claude-code "$role" --model "$worker_model")
  if [[ "$role" == "karo" ]]; then
    spawn_args+=(--window)
  fi
  if [[ -n "$boot_prompt" ]]; then
    spawn_args+=(--boot-prompt "$boot_prompt")
  fi
  if agmsg_run_state_fresh_needed "$role"; then
    spawn_args+=(--fresh)
  fi

  if ! agmsg_spawn "$_agmsg_cmd_name" "${spawn_args[@]}"; then
    error "spawn に失敗しました: ${role}"
    exit 1
  fi

  agmsg_run_state_mark_fresh_done "$role"

  # placement record からペインラベルを引き継ぐ（取得できなくても致命的ではない）
  local placement
  if placement="$(agmsg_get_placement "$_agmsg_cmd_name" "$_agmsg_team" "$role" 2>/dev/null)"; then
    local pane_id
    pane_id="$(printf '%s' "$placement" | cut -f1)"
    case "$pane_id" in
      %*) _set_pane_role_label "$pane_id" "$role" ;;
      @*)
        local root_pane
        root_pane="$(tmux list-panes -t "$pane_id" -F '#{pane_id}' 2>/dev/null | head -n1)"
        [[ -n "$root_pane" ]] && _set_pane_role_label "$root_pane" "$role"
        ;;
    esac
  fi

  success "spawn しました: ${role}"
}
```

ディスパッチの `case "$COMMAND" in` に追加する（`stop)` の直前）:

```bash
  spawn)   cmd_spawn "$@" ;;
```

`cmd_help()` にも1行追加する（`shogun task` の説明の近く）:

```bash
  echo -e "  ${CYAN}shogun spawn <role>${RESET}           役職をオンデマンドで起動（karo/gunshi/metsuke/ashigaruN）"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `tests/bats/bin/bats tests/integration/spawn.bats`
Expected: PASS（6 tests, 0 failures）

- [ ] **Step 5: Run the full suite and commit**

Run: `tests/bats/bin/bats tests/unit tests/integration`
Expected: PASS（全件）

```bash
git add bin/shogun tests/integration/spawn.bats
git commit -m "feat(spawn): shogun spawn <role> サブコマンドを追加"
```

---

### Task 6: `shogun task` を agmsg send 経由に置き換える

**Files:**
- Modify: `bin/shogun`（`cmd_task()` の書き換え）
- Modify: `tests/integration/task.bats`

**Context:** `shogun task "..."` は現在、`shogun_to_karo.yaml` への追記と `packages/mcp-queue` への SQLite 通知を行っている。これを `agmsg_send` 経由の Taisho への直接送信に置き換える（設計仕様書 §6「既存の`shogun_to_karo.yaml`は廃止」）。

**Interfaces:**
- Consumes: `agmsg_send()`（計画1）、`project_agmsg_team_name()`（Task 2）、`read_agmsg_cmd_name()`（計画1）

- [ ] **Step 1: Write the failing test**

`tests/integration/task.bats` の既存テスト（`shogun_to_karo.yaml` への追記を前提にしたもの）はこの Task で置き換え対象になる。新しい期待動作のテストを追加する:

```bash
cat >> tests/integration/task.bats <<'EOF'

# --- agmsg 送信への置き換え後の振る舞い ---

_stub_agmsg_send() {
  local fake_dir="${TEST_PROJECT}/fake-adapter"
  mkdir -p "$fake_dir"
  export AGMSG_SEND_LOG="${TEST_PROJECT}/agmsg_send.log"
  : > "$AGMSG_SEND_LOG"
  cat > "${fake_dir}/agmsg_adapter.sh" <<'FAKE'
agmsg_send() { echo "send $*" >> "${AGMSG_SEND_LOG}"; }
FAKE
  export SHOGUN_FAKE_AGMSG_ADAPTER="${fake_dir}/agmsg_adapter.sh"
}

@test "task: sends the task description to taisho via agmsg" {
  _stub_agmsg_send
  run shogun task "build auth feature"
  [ "$status" -eq 0 ]
  run grep "taisho" "$AGMSG_SEND_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"build auth feature"* ]]
}

@test "task: no longer writes shogun_to_karo.yaml" {
  _stub_agmsg_send
  shogun task "build auth feature" >/dev/null
  [ ! -f ".shogun/queue/shogun_to_karo.yaml" ] || {
    run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/queue/shogun_to_karo.yaml', 'utf8')) || {commands: []};
process.stdout.write(String((d.commands || []).length));
"
    [ "$output" = "0" ]
  }
}
EOF
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tests/bats/bin/bats tests/integration/task.bats`
Expected: FAIL — 新規2テストが失敗する（`cmd_task` はまだ `agmsg_send` を呼ばず、`shogun_to_karo.yaml` に書き込んでいるため）。

- [ ] **Step 3: Write minimal implementation**

`bin/shogun` の `cmd_task()` を以下に置き換える（関数全体を置き換える）:

```bash
cmd_task() {
  require_init

  local task_desc=""
  local priority="normal"

  # 引数パース
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --priority)
        priority="${2:?--priority には値が必要です}"
        shift 2
        ;;
      --priority=*)
        priority="${1#--priority=}"
        shift
        ;;
      -*)
        error "不明なオプション: $1"
        exit 1
        ;;
      *)
        task_desc="$1"
        shift
        ;;
    esac
  done

  # タスク説明が空なら対話入力
  if [[ -z "$task_desc" ]]; then
    echo -n "タスクの説明を入力してください: "
    read -r task_desc
    if [[ -z "$task_desc" ]]; then
      error "タスクの説明が空です。"
      exit 1
    fi
  fi

  # shellcheck source=scripts/agmsg_adapter.sh
  source "${SHOGUN_FAKE_AGMSG_ADAPTER:-${SHOGUN_BIN_DIR}/scripts/agmsg_adapter.sh}"

  local config_file="${SHOGUN_ROOT}/.shogun/config.yaml"
  local project_name
  project_name="$(read_project_name "$config_file")"
  local _agmsg_cmd_name _agmsg_team
  _agmsg_cmd_name="$(read_agmsg_cmd_name "$config_file")"
  _agmsg_team="$(project_agmsg_team_name "$project_name" "$SHOGUN_ROOT")"

  if ! agmsg_send "$_agmsg_cmd_name" "$_agmsg_team" shogun taisho "$task_desc"; then
    error "agmsg 経由でのタスク送信に失敗しました。shogun doctor で agmsg の状態を確認してください。"
    exit 1
  fi

  success "タスクをTaishoへ送信しました。"
  info "説明: ${task_desc}"
  info "優先度: ${priority}"
}
```

**削除する既存コード**: `cmd_id` の生成、`shogun_to_karo.yaml` への追記、`packages/mcp-queue/cli.js inbox_send` の呼び出し——これらはすべて削除する。`priority` はこの Task の時点では `agmsg_send` のメッセージ本文に含めない（envelope化は計画4のスコープ）。表示用の情報として `info` で出力するだけに留める。

- [ ] **Step 4: Run test to verify it passes**

Run: `tests/bats/bin/bats tests/integration/task.bats`
Expected: 新規2テストが PASS。旧 `shogun_to_karo.yaml` 前提の既存テスト（`task: adds command to shogun_to_karo.yaml` 等）は意味を失うため削除する。

- [ ] **Step 5: Run the full suite and commit**

Run: `tests/bats/bin/bats tests/unit tests/integration`
Expected: PASS（全件）。`packages/mcp-queue`関連のnodeテストは今回のスコープ外（計画6で削除予定）のため、`npm run test:mcp` は従来通りパスするはずだが、念のため実行して確認する。

```bash
git add bin/shogun tests/integration/task.bats
git commit -m "feat(task): shogun taskをagmsg send経由でのTaisho直接送信に置き換え"
```

---

## Self-Review

**Spec coverage:**
- §5（tmuxセッション構成の変更）: Task 3・4 でカバー。
- §6（通信層配線: shogun identity登録、shogun task→send）: Task 2・6 でカバー。dashboard.md単一ライター契約は指示書の規約のみとし、既存の`templates/instructions/taisho.md`が既にTaisho=更新者という前提で書かれているため、本計画での追加変更は不要（矛盾なし）。
- §8前半（spawn/despawn運用のモデル選択）: Task 5 でカバー。
- §8後半（run_id状態管理、resume/--fresh）: Task 1・5 でカバー。
- pane label引き継ぎ: Task 5 でカバー。
- `shogun attach multi`の廃止: Task 3 でカバー（`cmd_attach`から`multi`/`multiagent`分岐を削除）。

**Placeholder scan:** なし。各Stepに具体的なコードを記載済み。Task 2で「typeの値を実装時に検証する」としていた保留事項は、ローカルクローン調査により`agmsg-app`と確定済み。

**Type consistency:** `project_session_names`（複数形、旧）→`project_session_name`（単数形、新）への改名はTask 3で一括して行い、以降のTaskはすべて新名称を使う。`agmsg_run_state_*`関数群の命名（`new_run`/`current`/`fresh_needed`/`mark_fresh_done`）はTask 1で確定し、Task 4・5はこれをそのまま利用する。

**Scope check:** Karo→配下への実際のタスク割り当て・報告（envelopeプロトコル）は計画4（#130）、無応答復旧時の`shogun spawn`再利用は計画5（#131）、Taisho readinessの堅牢化（sentinelポーリング等）は計画3（#129）でそれぞれ扱う。本計画はこれらの前提となる基盤（1セッション化・spawn ラッパー・task送信）のみに限定した。
