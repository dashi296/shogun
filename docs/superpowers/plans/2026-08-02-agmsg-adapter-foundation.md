# agmsg 通信基盤（アダプタ層）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shogun が agmsg（外部 OSS のクロスベンダーメッセージングツール）の実際の
シェルスクリプト API を呼び出すための薄いアダプタ層 `scripts/agmsg_adapter.sh` を実装し、
`shogun doctor`・`shogun init` から使えるようにする。

**Architecture:** agmsg は単一の CLI コマンドではなく、
`~/.agents/skills/<cmd_name>/scripts/*.sh` に配置される個別スクリプト群として動作する。
Shogun 側は各スクリプトへの薄いラッパー関数（`agmsg_send`/`agmsg_spawn`/`agmsg_despawn`/
`agmsg_join`/`agmsg_set_delivery`/`agmsg_inbox`/`agmsg_history`）と、
spawn 時に agmsg が記録する placement record（tmux pane/window ID の記録）を読む
アクセサ（`agmsg_get_placement`）を提供する。バージョン確認は agmsg のインストール先に
置かれる `VERSION` ファイルを直接読む。

**Tech Stack:** Bash（`set -euo pipefail`）、bats（テスト）、既存の `bin/shogun` の
`node_yaml`/`read_*` ヘルパー規約に従う。

## Global Constraints

- 対応 agmsg バージョン: `fujibee/agmsg` commit `1c7efbc005c50a7eb3cbd4bac9b1f6ab17825827`
  （`VERSION` ファイルの内容は `v1.1.12` または `v1.1.12-N-g<sha>[-dirty]` 形式）。
- 役職名・team 名・agent 名は `^[A-Za-z0-9_-]+$` でバリデーションする
  （CLAUDE.md のパストラバーサル防止規約に従う。この制約により、agmsg 内部の
  percent-encoding を経由せずファイルパスを直接組み立てられる — 詳細は Task 3 参照）。
- `cmd_name`（`.shogun/config.yaml` 由来。ユーザーのリポジトリにコミットされ得る値）も
  同様に `^[A-Za-z0-9_-]+$` でバリデーションする対象である
  （`_agmsg_home` の先頭で検証し、不一致なら `return 2` する — レビュー・fix round 1 で対応）。
- エントリポイントスクリプト（`bin/shogun`、直接実行されるスクリプト）は
  `#!/usr/bin/env bash` + `set -euo pipefail` を先頭に置く。source 専用ライブラリ
  （`scripts/flag_names.sh`・`scripts/agmsg_adapter.sh` 等）は `set` 行を持たず、
  呼び出し元のシェルオプションに委ねる。
- テストは `tests/unit/` に bats で追加し、既存の `tests/test_helper.bash` を
  `load '../test_helper'` する。

---

### Task 1: agmsg インストール先の解決とバージョン確認

**Files:**
- Create: `scripts/agmsg_adapter.sh`
- Create: `tests/unit/agmsg_adapter.bats`

**Interfaces:**
- Consumes: なし（このタスクが土台）
- Produces:
  - `_agmsg_home <cmd_name>` — `~/.agents/skills/<cmd_name>` を返す関数
    （`AGMSG_HOME_OVERRIDE` 環境変数が設定されていればそちらを優先する。
    テストで実際の `$HOME` を汚さずに検証するためのフック）。
  - `agmsg_version <cmd_name>` — インストール先の `VERSION` ファイルの内容を返す
    （ファイルが無ければ `unknown` を返す）。
  - `agmsg_version_ok <cmd_name>` — `agmsg_version` の出力が `v1.1.12` で始まる場合に
    exit 0、それ以外は exit 1（`shogun doctor` から使う）。

- [ ] **Step 1: Write the failing test**

```bash
cat > tests/unit/agmsg_adapter.bats <<'EOF'
#!/usr/bin/env bats
# Unit tests for scripts/agmsg_adapter.sh

load '../test_helper'

setup() {
  source "${SHOGUN_REPO}/scripts/agmsg_adapter.sh"
  export AGMSG_TEST_HOME="$(mktemp -d)"
  export AGMSG_HOME_OVERRIDE="${AGMSG_TEST_HOME}"
}

teardown() {
  rm -rf "${AGMSG_TEST_HOME}"
}

@test "agmsg_adapter: _agmsg_home honors AGMSG_HOME_OVERRIDE" {
  run _agmsg_home "mycmd"
  [ "$status" -eq 0 ]
  [ "$output" = "${AGMSG_TEST_HOME}" ]
}

@test "agmsg_adapter: agmsg_version reads the VERSION file" {
  echo "v1.1.12-3-g1c7efbc" > "${AGMSG_TEST_HOME}/VERSION"
  run agmsg_version "mycmd"
  [ "$status" -eq 0 ]
  [ "$output" = "v1.1.12-3-g1c7efbc" ]
}

@test "agmsg_adapter: agmsg_version returns 'unknown' when VERSION is missing" {
  run agmsg_version "mycmd"
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "agmsg_adapter: agmsg_version_ok succeeds for v1.1.12 prefix" {
  echo "v1.1.12" > "${AGMSG_TEST_HOME}/VERSION"
  run agmsg_version_ok "mycmd"
  [ "$status" -eq 0 ]
}

@test "agmsg_adapter: agmsg_version_ok succeeds for v1.1.12-N-g<sha> variant" {
  echo "v1.1.12-3-g1c7efbc" > "${AGMSG_TEST_HOME}/VERSION"
  run agmsg_version_ok "mycmd"
  [ "$status" -eq 0 ]
}

@test "agmsg_adapter: agmsg_version_ok fails for a mismatched version" {
  echo "v2.0.0" > "${AGMSG_TEST_HOME}/VERSION"
  run agmsg_version_ok "mycmd"
  [ "$status" -eq 1 ]
}
EOF
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/bats/bin/bats tests/unit/agmsg_adapter.bats`
Expected: FAIL — `scripts/agmsg_adapter.sh` does not exist yet, so `source` errors out
(all 6 tests fail with a "No such file or directory" style error).

- [ ] **Step 3: Write minimal implementation**

```bash
cat > scripts/agmsg_adapter.sh <<'EOF'
#!/usr/bin/env bash
# agmsg（外部 OSS のエージェント間メッセージングツール）への薄いアダプタ層。
#
# agmsg は単一の CLI コマンドではなく、~/.agents/skills/<cmd_name>/scripts/*.sh に
# 配置される個別スクリプト群として動作する。このファイルは各スクリプトへの
# 薄いラッパー関数を提供する（対応 commit: 1c7efbc005c50a7eb3cbd4bac9b1f6ab17825827）。
#
# このファイルは source して使う（実行しない）。
set -euo pipefail

# agmsg のインストール先ディレクトリを返す。
# AGMSG_HOME_OVERRIDE が設定されていればそれを優先する（テスト用フック）。
_agmsg_home() {
  local cmd_name="${1:?cmd_name required}"
  if [[ -n "${AGMSG_HOME_OVERRIDE:-}" ]]; then
    printf '%s' "${AGMSG_HOME_OVERRIDE}"
  else
    printf '%s/.agents/skills/%s' "${HOME}" "$cmd_name"
  fi
}

# インストール済み agmsg のバージョン（VERSION ファイルの内容）を返す。
agmsg_version() {
  local cmd_name="${1:?cmd_name required}"
  local version_file
  version_file="$(_agmsg_home "$cmd_name")/VERSION"
  if [[ -f "$version_file" ]]; then
    cat "$version_file"
  else
    echo "unknown"
  fi
}

# 対応バージョン（v1.1.12 系）であれば exit 0、それ以外は exit 1。
agmsg_version_ok() {
  local cmd_name="${1:?cmd_name required}"
  local version
  version="$(agmsg_version "$cmd_name")"
  [[ "$version" == v1.1.12* ]]
}
EOF
chmod +x scripts/agmsg_adapter.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/bats/bin/bats tests/unit/agmsg_adapter.bats`
Expected: PASS（6 tests, 0 failures）

- [ ] **Step 5: Commit**

```bash
git add scripts/agmsg_adapter.sh tests/unit/agmsg_adapter.bats
git commit -m "feat(agmsg): agmsgインストール先解決とバージョン確認関数を追加"
```

---

### Task 2: 送受信・spawn/despawn アダプタ関数

**Files:**
- Modify: `scripts/agmsg_adapter.sh`
- Modify: `tests/unit/agmsg_adapter.bats`

**Interfaces:**
- Consumes: `_agmsg_home()`（Task 1）
- Produces（すべて委譲先スクリプトの exit code・stdout をそのまま返す）:
  - `agmsg_send <cmd_name> <team> <from> <to> <message> [--force]`
  - `agmsg_join <cmd_name> <team> <agent> <type> <project> [--force]`
  - `agmsg_set_delivery <cmd_name> set <mode> <type> <project>`
  - `agmsg_spawn <cmd_name> <type> <name> [--boot-prompt TEXT] [--project PATH] [--team TEAM] [--window] [--split h|v] [--terminal TMPL] [--no-wait] [--ready-timeout N] [--model ID] [--fresh]`
  - `agmsg_despawn <cmd_name> <team> <from> <name> [--force] [--timeout N]`
  - `agmsg_inbox <cmd_name> <team> <agent>`
  - `agmsg_history <cmd_name> <team> [--limit N]`

- [ ] **Step 1: Write the failing test**

```bash
# tests/unit/agmsg_adapter.bats に追記
cat >> tests/unit/agmsg_adapter.bats <<'EOF'

# --- pass-through wrapper functions ---
# 各委譲先スクリプトを fake 実装に差し替え、渡された引数をそのまま echo する。

_fake_agmsg_script() {
  local name="$1"
  mkdir -p "${AGMSG_TEST_HOME}/scripts"
  cat > "${AGMSG_TEST_HOME}/scripts/${name}" <<'FAKE'
#!/usr/bin/env bash
echo "${0##*/} $*"
FAKE
  chmod +x "${AGMSG_TEST_HOME}/scripts/${name}"
}

@test "agmsg_adapter: agmsg_send delegates to send.sh with all args" {
  _fake_agmsg_script "send.sh"
  run agmsg_send "mycmd" "team1" "karo" "taisho" "done"
  [ "$status" -eq 0 ]
  [ "$output" = "send.sh team1 karo taisho done" ]
}

@test "agmsg_adapter: agmsg_join delegates to join.sh with all args" {
  _fake_agmsg_script "join.sh"
  run agmsg_join "mycmd" "team1" "taisho" "claude-code" "/proj"
  [ "$output" = "join.sh team1 taisho claude-code /proj" ]
}

@test "agmsg_adapter: agmsg_set_delivery delegates to delivery.sh with all args" {
  _fake_agmsg_script "delivery.sh"
  run agmsg_set_delivery "mycmd" set monitor claude-code /proj
  [ "$output" = "delivery.sh set monitor claude-code /proj" ]
}

@test "agmsg_adapter: agmsg_spawn delegates to spawn.sh with all args" {
  _fake_agmsg_script "spawn.sh"
  run agmsg_spawn "mycmd" claude-code karo --model sonnet --fresh
  [ "$output" = "spawn.sh claude-code karo --model sonnet --fresh" ]
}

@test "agmsg_adapter: agmsg_despawn delegates to despawn.sh with all args" {
  _fake_agmsg_script "despawn.sh"
  run agmsg_despawn "mycmd" team1 karo ashigaru1 --force
  [ "$output" = "despawn.sh team1 karo ashigaru1 --force" ]
}

@test "agmsg_adapter: agmsg_inbox delegates to inbox.sh with all args" {
  _fake_agmsg_script "inbox.sh"
  run agmsg_inbox "mycmd" team1 karo
  [ "$output" = "inbox.sh team1 karo" ]
}

@test "agmsg_adapter: agmsg_history delegates to history.sh with all args" {
  _fake_agmsg_script "history.sh"
  run agmsg_history "mycmd" team1 --limit 20
  [ "$output" = "history.sh team1 --limit 20" ]
}
EOF
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/bats/bin/bats tests/unit/agmsg_adapter.bats`
Expected: FAIL — the 7 new tests fail with "command not found" for each
`agmsg_*` wrapper function.

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/agmsg_adapter.sh に追記
cat >> scripts/agmsg_adapter.sh <<'EOF'

# 委譲先スクリプトのパスを返す。
_agmsg_script() {
  local cmd_name="$1" script="$2"
  printf '%s/scripts/%s' "$(_agmsg_home "$cmd_name")" "$script"
}

agmsg_send() {
  local cmd_name="$1"; shift
  bash "$(_agmsg_script "$cmd_name" send.sh)" "$@"
}

agmsg_join() {
  local cmd_name="$1"; shift
  bash "$(_agmsg_script "$cmd_name" join.sh)" "$@"
}

agmsg_set_delivery() {
  local cmd_name="$1"; shift
  bash "$(_agmsg_script "$cmd_name" delivery.sh)" "$@"
}

agmsg_spawn() {
  local cmd_name="$1"; shift
  bash "$(_agmsg_script "$cmd_name" spawn.sh)" "$@"
}

agmsg_despawn() {
  local cmd_name="$1"; shift
  bash "$(_agmsg_script "$cmd_name" despawn.sh)" "$@"
}

agmsg_inbox() {
  local cmd_name="$1"; shift
  bash "$(_agmsg_script "$cmd_name" inbox.sh)" "$@"
}

agmsg_history() {
  local cmd_name="$1"; shift
  bash "$(_agmsg_script "$cmd_name" history.sh)" "$@"
}
EOF
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/bats/bin/bats tests/unit/agmsg_adapter.bats`
Expected: PASS（13 tests, 0 failures）

- [ ] **Step 5: Commit**

```bash
git add scripts/agmsg_adapter.sh tests/unit/agmsg_adapter.bats
git commit -m "feat(agmsg): send/join/delivery/spawn/despawn/inbox/historyのアダプタ関数を追加"
```

---

### Task 3: placement record アクセサ

**Files:**
- Modify: `scripts/agmsg_adapter.sh`
- Modify: `tests/unit/agmsg_adapter.bats`

**Context:** agmsg は `spawn` 実行時、`$SKILL_DIR/run/spawn.<team>__<agent>` に
`id<TAB>project<TAB>type`（tab 区切り、1行）の形式で placement record を書く
（`scripts/lib/actas-lock.sh` の `agmsg_spawn_path()`/`spawn.sh` 519行目付近を根拠とする）。
team/agent 名は agmsg 内部で percent-encoding されるが、Shogun が渡す team/agent 名は
常に `^[A-Za-z0-9_-]+$` にバリデーション済み（CLAUDE.md 規約）であり、この文字集合は
percent-encoding の対象にならない。したがって Shogun 側はエンコード関数を呼ばずに
直接パスを組み立ててよい（バリデーションをこの関数自身でも行い、想定外の文字が
紛れ込んだ場合はエラーにする）。

**Interfaces:**
- Consumes: `_agmsg_home()`（Task 1）
- Produces:
  - `agmsg_get_placement <cmd_name> <team> <agent>` —
    placement record が存在すれば `<id>\t<project>\t<type>` を1行 stdout に出力し
    exit 0。存在しなければ何も出力せず exit 1。
    `team`/`agent` が `^[A-Za-z0-9_-]+$` に一致しない場合は exit 2
    （呼び出し側はこの3つの exit code を区別して扱う）。

- [ ] **Step 1: Write the failing test**

```bash
cat >> tests/unit/agmsg_adapter.bats <<'EOF'

# --- placement record accessor ---

@test "agmsg_adapter: agmsg_get_placement reads an existing record" {
  mkdir -p "${AGMSG_TEST_HOME}/run"
  printf '%%3\t/proj\tclaude-code\n' > "${AGMSG_TEST_HOME}/run/spawn.team1__karo"
  run agmsg_get_placement "mycmd" "team1" "karo"
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r id project type <<< "$output"
  [ "$id" = "%3" ]
  [ "$project" = "/proj" ]
  [ "$type" = "claude-code" ]
}

@test "agmsg_adapter: agmsg_get_placement fails when no record exists" {
  run agmsg_get_placement "mycmd" "team1" "karo"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "agmsg_adapter: agmsg_get_placement rejects an invalid team name" {
  run agmsg_get_placement "mycmd" "team one" "karo"
  [ "$status" -eq 2 ]
}

@test "agmsg_adapter: agmsg_get_placement rejects an invalid agent name" {
  run agmsg_get_placement "mycmd" "team1" "../evil"
  [ "$status" -eq 2 ]
}
EOF
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/bats/bin/bats tests/unit/agmsg_adapter.bats`
Expected: FAIL — `agmsg_get_placement: command not found`（4 new tests fail）

- [ ] **Step 3: Write minimal implementation**

```bash
# scripts/agmsg_adapter.sh に追記
cat >> scripts/agmsg_adapter.sh <<'EOF'

# agmsg の spawn が記録する placement record（team/agent の tmux 配置先）を読む。
# team/agent は ^[A-Za-z0-9_-]+$ のみ許可する（この文字集合は agmsg 内部の
# percent-encoding の対象にならないため、直接パスを組み立てられる）。
agmsg_get_placement() {
  local cmd_name="$1" team="$2" agent="$3"
  [[ "$team" =~ ^[A-Za-z0-9_-]+$ ]] || return 2
  [[ "$agent" =~ ^[A-Za-z0-9_-]+$ ]] || return 2

  local record_file
  record_file="$(_agmsg_home "$cmd_name")/run/spawn.${team}__${agent}"
  [[ -f "$record_file" ]] || return 1
  cat "$record_file"
}
EOF
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/bats/bin/bats tests/unit/agmsg_adapter.bats`
Expected: PASS（17 tests, 0 failures）

- [ ] **Step 5: Commit**

```bash
git add scripts/agmsg_adapter.sh tests/unit/agmsg_adapter.bats
git commit -m "feat(agmsg): placement recordアクセサ(agmsg_get_placement)を追加"
```

---

### Task 4: `.shogun/config.yaml` への `agmsg.cmd_name` 追加と `shogun doctor` 連携

**Files:**
- Modify: `templates/config/settings.yaml`
- Modify: `bin/shogun`（`read_agmsg_cmd_name` ヘルパー、`cmd_doctor` への追加）
- Create: `tests/unit/agmsg_doctor.bats`

**Interfaces:**
- Consumes: `agmsg_version_ok()`（Task 1）
- Produces:
  - `read_agmsg_cmd_name <config.yaml>` — `agmsg.cmd_name` を返す（デフォルト `agmsg`）。
  - `shogun doctor` の出力に `[ agmsg ]` セクションが追加され、
    インストール確認・バージョン確認の結果を表示する。

- [ ] **Step 1: Write the failing test**

```bash
cat > tests/unit/agmsg_doctor.bats <<'EOF'
#!/usr/bin/env bats
# Unit tests for read_agmsg_cmd_name (bin/shogun) と shogun doctor の agmsg 連携

load '../test_helper'

setup() {
  # bin/shogun 内のヘルパー関数だけを取り出して source する。
  # cmd_* のディスパッチ（case文）は実行させないため、関数定義部分までを抽出する。
  TEST_CONFIG="$(mktemp)"
  cat > "$TEST_CONFIG" <<'YAML'
project_name: testproj
agents:
  ashigaru_count: 3
agmsg:
  cmd_name: mycmd
YAML
}

teardown() {
  rm -f "$TEST_CONFIG"
}

@test "read_agmsg_cmd_name: returns configured cmd_name" {
  run bash -c "source '${SHOGUN_REPO}/bin/shogun' --lib-only 2>/dev/null; read_agmsg_cmd_name '${TEST_CONFIG}'"
  [ "$status" -eq 0 ]
  [ "$output" = "mycmd" ]
}

@test "read_agmsg_cmd_name: defaults to 'agmsg' when unset" {
  echo "project_name: testproj" > "$TEST_CONFIG"
  run bash -c "source '${SHOGUN_REPO}/bin/shogun' --lib-only 2>/dev/null; read_agmsg_cmd_name '${TEST_CONFIG}'"
  [ "$output" = "agmsg" ]
}
EOF
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/bats/bin/bats tests/unit/agmsg_doctor.bats`
Expected: FAIL — `bin/shogun` does not support `--lib-only` yet, and
`read_agmsg_cmd_name` does not exist.

- [ ] **Step 3: Write minimal implementation**

（注記: 当初はここに `--lib-only` ガードを追加する計画だったが、実装時に
`bin/shogun` には既に `[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0` という
source ガードが存在することが判明した。source されると（`BASH_SOURCE` と `$0` が
異なるため）このガードで末尾のディスパッチ部分の実行が止まり、関数定義だけを
安全に読み込める。そのため `--lib-only` ガードは不要と判断し削除した
（レビュー・fix round 1で対応）。）

`read_project_name` の直後に、以下を追加する:

```bash
# config.yaml から agmsg.cmd_name を取得（デフォルト agmsg）
read_agmsg_cmd_name() {
  local config="$1"
  node_yaml -e '
const yaml = require("js-yaml");
const d = yaml.load(require("fs").readFileSync(process.argv[1], "utf8")) || {};
process.stdout.write(String((d.agmsg && d.agmsg.cmd_name) || "agmsg"));
' -- "$config"
}
```

`templates/config/settings.yaml` の `agents:` ブロックの直後に追加する:

```yaml

agmsg:
  cmd_name: agmsg           # agmsg のインストールコマンド名（複数 <cmd> がある環境向け）
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/bats/bin/bats tests/unit/agmsg_doctor.bats`
Expected: PASS（2 tests, 0 failures）

- [ ] **Step 5: Commit**

```bash
git add bin/shogun templates/config/settings.yaml tests/unit/agmsg_doctor.bats
git commit -m "feat(agmsg): config.yamlのagmsg.cmd_name読み取りとlib-onlyガードを追加"
```

---

### Task 5: `shogun doctor` に agmsg チェックを追加

**Files:**
- Modify: `bin/shogun`（`cmd_doctor` 関数）
- Modify: `tests/integration/init.bats` または新規 `tests/integration/doctor.bats`

**Interfaces:**
- Consumes: `agmsg_version_ok()`（Task 1）、`_agmsg_home()`（Task 1）、
  `read_agmsg_cmd_name()`（Task 4）
- Produces: `shogun doctor` 実行時に `[ agmsg ]` セクションが出力される
  （存在チェック・バージョンチェックの結果を表示するのみで、exit code には
  影響させない — agmsg 未導入でも他の機能の doctor 結果は評価できるようにする）。

- [ ] **Step 1: Write the failing test**

```bash
cat > tests/integration/doctor_agmsg.bats <<'EOF'
#!/usr/bin/env bats
# Integration tests for `shogun doctor` の agmsg セクション

load '../test_helper'

setup() {
  init_test_project
  cd "${TEST_PROJECT}"
  export AGMSG_TEST_HOME="$(mktemp -d)"
  export AGMSG_HOME_OVERRIDE="${AGMSG_TEST_HOME}"
}

teardown() {
  rm -rf "${AGMSG_TEST_HOME}"
  teardown_test_project
}

@test "doctor: reports agmsg as missing when not installed" {
  run shogun doctor
  [[ "$output" == *"agmsg"* ]]
  [[ "$output" == *"見つかりません"* ]]
}

@test "doctor: reports agmsg version when installed and matching" {
  mkdir -p "${AGMSG_TEST_HOME}/scripts"
  echo "v1.1.12-3-g1c7efbc" > "${AGMSG_TEST_HOME}/VERSION"
  run shogun doctor
  [[ "$output" == *"v1.1.12-3-g1c7efbc"* ]]
}

@test "doctor: warns when agmsg version does not match the expected series" {
  mkdir -p "${AGMSG_TEST_HOME}/scripts"
  echo "v2.0.0" > "${AGMSG_TEST_HOME}/VERSION"
  run shogun doctor
  [[ "$output" == *"想定外"* ]]
}
EOF
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/bats/bin/bats tests/integration/doctor_agmsg.bats`
Expected: FAIL — `shogun doctor` の出力に `agmsg` の文字列が含まれず3テストとも失敗する。

- [ ] **Step 3: Write minimal implementation**

`bin/shogun` の `cmd_doctor()` 内、`fswatch / inotifywait` チェックの直後
（`bin/shogun:1371` 付近、`echo ""` の前）に追加する:

```bash
  # agmsg
  echo ""
  echo -e "${BOLD}[ agmsg ]${RESET}"
  local _agmsg_cmd_name="agmsg"
  if SHOGUN_ROOT="$(find_shogun_root 2>/dev/null)" && [[ -f "${SHOGUN_ROOT}/.shogun/config.yaml" ]]; then
    _agmsg_cmd_name="$(read_agmsg_cmd_name "${SHOGUN_ROOT}/.shogun/config.yaml")"
  fi
  local _agmsg_home_dir
  _agmsg_home_dir="$(_agmsg_home "$_agmsg_cmd_name")"
  if [[ -d "${_agmsg_home_dir}/scripts" ]]; then
    local _agmsg_ver
    _agmsg_ver="$(agmsg_version "$_agmsg_cmd_name")"
    if agmsg_version_ok "$_agmsg_cmd_name"; then
      echo -e "  ${GREEN}✓${RESET} agmsg (${_agmsg_ver})"
    else
      echo -e "  ${YELLOW}!${RESET} agmsg バージョンが想定外です (${_agmsg_ver})"
      echo -e "       想定: v1.1.12 系（commit 1c7efbc005c...）"
    fi
  else
    echo -e "  ${RED}✗${RESET} agmsg が見つかりません → npx agmsg でインストール"
  fi
```

`bin/shogun` の冒頭（`NODE_PATH_ARG` 定義の直後あたり）に、アダプタの source を追加する:

```bash
# shellcheck source=scripts/agmsg_adapter.sh
source "${SHOGUN_BIN_DIR}/scripts/agmsg_adapter.sh"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/bats/bin/bats tests/integration/doctor_agmsg.bats`
Expected: PASS（3 tests, 0 failures）

Run the full suite to check for regressions: `npm test`
Expected: PASS（既存テストすべてに影響がないこと）

- [ ] **Step 5: Commit**

```bash
git add bin/shogun tests/integration/doctor_agmsg.bats
git commit -m "feat(agmsg): shogun doctorにagmsgインストール・バージョン確認を追加"
```

---

## Self-Review

**Spec coverage:**
- §3（agmsg API契約・アダプタ）: Task 1〜3 でカバー。
- §3・§12（バージョン固定・`shogun doctor`）: Task 4〜5 でカバー。
- §6（`shogun` system identity 登録）、§5（1セッション統合）、§7（Taisho readiness）、
  §9（無応答復旧）、§10（タスクプロトコル）、§11（hook移行）は**別の実装計画
  （計画2〜6）でカバーする**（今回のスコープ外）。

**Placeholder scan:** なし（各 Step に具体的なコードを記載済み）。

**Type consistency:** `agmsg_get_placement` の出力形式（`id\tproject\ttype`）は
Task 3 で定義し、Task 5 では使用していない（Task 5 は存在確認・バージョン確認のみ）。
後続の計画（spawn/despawn 運用・無応答復旧）がこの関数を利用する際は、
この tab 区切り出力形式・exit code 規約（0=成功, 1=record無し, 2=不正な引数）に従うこと。
