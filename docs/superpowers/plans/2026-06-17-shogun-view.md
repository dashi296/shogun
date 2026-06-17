# shogun view Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `bin/shogun` に `shogun view` サブコマンドを追加し、全エージェントの busy/idle・タスク・inbox 未読数をリアルタイムで表示するライブモニターを実装する。

**Architecture:** `cmd_view()` が代替スクリーン（`tput smcup/rmcup`）に切り替え、2秒ごとに `_view_render()` を呼び出してカーソルをホームへ戻しながら再描画する。`_view_render()` はループから独立した関数として実装し、テストから直接呼べるようにする。新規ファイルは `tests/integration/view.bats` のみ。

**Tech Stack:** Bash, bats-core（テスト）, node + js-yaml（YAML読み取り）, tput（ターミナル制御）

---

## File Structure

| ファイル | 変更種別 | 役割 |
|----------|----------|------|
| `bin/shogun` | Modify | `_view_render()` と `cmd_view()` を追加。`case` ディスパッチャと `cmd_help()` に `view` を登録 |
| `tests/integration/view.bats` | Create | `shogun view` の統合テスト |

---

### Task 1: init guard テスト + `cmd_view()` スタブ + ディスパッチャ登録

**Files:**
- Create: `tests/integration/view.bats`
- Modify: `bin/shogun`

- [ ] **Step 1: テストファイルを作成する**

`tests/integration/view.bats` を以下の内容で作成する：

```bash
#!/usr/bin/env bats
# Integration tests for shogun view

load '../test_helper'

setup() {
  init_test_project
  cd "${TEST_PROJECT}"
}

teardown() {
  teardown_test_project
}

@test "view: init されていないディレクトリで失敗する" {
  local no_init_dir
  no_init_dir="$(mktemp -d)"
  cd "$no_init_dir"

  run shogun view
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR"* ]]

  rm -rf "$no_init_dir"
}
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
npm run test:integration -- --filter view
```

Expected: `view: init されていないディレクトリで失敗する` が FAIL（`shogun view` が "unknown command" エラーになる）

- [ ] **Step 3: `cmd_view()` スタブと `_view_render()` スケルトンを `bin/shogun` に追加する**

`bin/shogun` の `cmd_status()` 定義の直前（`# ════ shogun status` の行の直前）に以下を挿入する：

```bash
# ════════════════════════════════════════════════════════════
# shogun view の描画関数（テストから直接呼び出し可能）
# ════════════════════════════════════════════════════════════
_view_render() {
  echo "TODO"
}

# ════════════════════════════════════════════════════════════
# shogun view
# ════════════════════════════════════════════════════════════
cmd_view() {
  require_init
  _view_render
}
```

- [ ] **Step 4: `case` ディスパッチャに `view` を追加する**

`bin/shogun` の `case "$COMMAND" in` ブロック内、`status)  cmd_status "$@" ;;` の直前に以下を追加する：

```bash
  view)    cmd_view "$@" ;;
```

- [ ] **Step 5: テストが通ることを確認する**

```bash
npm run test:integration -- --filter view
```

Expected: `view: init されていないディレクトリで失敗する` が PASS

- [ ] **Step 6: コミットする**

```bash
git add bin/shogun tests/integration/view.bats
git commit -m "feat(view): cmd_view スタブとテスト骨格を追加"
```

---

### Task 2: `_view_render()` — エージェント状態（busy/idle・inbox）

**Files:**
- Modify: `bin/shogun` (`_view_render()` を実装)
- Modify: `tests/integration/view.bats` (テストを追加)

**前提知識:**
- busy/idle の判定は `/tmp/shogun_idle_<cksum_key>_<role>` ファイルの存在有無で行う
- `cksum_key` は `printf '%s' "${SHOGUN_ROOT}" | cksum | cut -d' ' -f1` で生成する（`scripts/flag_names.sh` の `_shogun_flag_root_key()` と同一ロジック）
- inbox 未読数は `packages/mcp-queue/cli.js inbox_unread_count --root=... --role=...` で取得する

- [ ] **Step 1: テストを追加する**

`tests/integration/view.bats` に以下を追加する：

```bash
# ─── _view_render() を bash -c で呼ぶ共通ヘルパー ───────────
_run_view_render() {
  run bash -c "
    export SHOGUN_ROOT='${TEST_PROJECT}'
    export SHOGUN_BIN_DIR='${SHOGUN_REPO}'
    source '${SHOGUN_REPO}/bin/shogun'
    _view_render
  "
}

# idle フラグのパスを返す（flag_names.sh と同一ロジック）
_idle_flag_path() {
  local agent="$1"
  local root_key
  root_key="$(printf '%s' "${TEST_PROJECT}" | cksum | cut -d' ' -f1)"
  echo "/tmp/shogun_idle_${root_key}_${agent}"
}

@test "view render: BUSY エージェントが '● BUSY' と表示される" {
  # karo の idle フラグを削除して BUSY 状態にする
  rm -f "$(_idle_flag_path karo)"

  _run_view_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"● BUSY"* ]]
}

@test "view render: idle エージェントが '● idle' と表示される" {
  # karo に idle フラグを作成して idle 状態にする
  touch "$(_idle_flag_path karo)"

  _run_view_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"● idle"* ]]

  rm -f "$(_idle_flag_path karo)"
}

@test "view render: inbox 未読数が 'inbox:N' 形式で表示される" {
  _run_view_render
  [ "$status" -eq 0 ]
  [[ "$output" =~ inbox:[0-9] ]]
}
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
npm run test:integration -- --filter view
```

Expected: `view render: BUSY` など3テストが FAIL（`_view_render()` が "TODO" しか出力しないため）

- [ ] **Step 3: `_view_render()` のエージェント状態セクションを実装する**

`bin/shogun` の `_view_render()` を以下に置き換える：

```bash
_view_render() {
  local config_file="${SHOGUN_ROOT}/.shogun/config.yaml"
  local project_name
  project_name="$(read_project_name "$config_file")"

  local session_taisho session_multi
  read -r session_taisho session_multi <<< "$(project_session_names "$project_name" "$SHOGUN_ROOT")" || true

  local now
  now="$(date '+%H:%M:%S')"

  # ─── ヘッダー
  echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${MAGENTA}  ⛩  Shogun View: ${project_name}       更新: ${now}${RESET}"
  echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════╝${RESET}"
  echo ""

  # ─── コマンドキュー（後タスクで実装、ここでは省略）
  echo -e "${BOLD}[ コマンドキュー ]${RESET}"
  echo "  （準備中）"
  echo ""

  # ─── エージェント一覧
  echo -e "${BOLD}[ エージェント ]${RESET}"

  local ashigaru_count
  ashigaru_count="$(read_ashigaru_count "$config_file")"

  local agents
  read -ra agents <<< "$(ashigaru_agents "$ashigaru_count")"

  # flag_names.sh の shogun_idle_flag() を利用するために source
  source "${SHOGUN_BIN_DIR}/scripts/flag_names.sh"

  local project_id="${SHOGUN_PROJECT_ID:-}"

  for agent in "${agents[@]}"; do
    # busy/idle 判定
    local flag
    flag="$(shogun_idle_flag "$agent" "$project_id")"
    local state_label state_color
    if [[ -f "$flag" ]]; then
      state_label="idle"
      state_color="${GREEN}"
    else
      state_label="BUSY"
      state_color="${YELLOW}"
    fi

    # inbox 未読数
    local inbox_count=0
    if [[ -n "${SHOGUN_BIN_DIR:-}" ]]; then
      inbox_count=$(node "${SHOGUN_BIN_DIR}/packages/mcp-queue/cli.js" \
        inbox_unread_count \
        "--root=${SHOGUN_ROOT}" \
        "--role=${agent}" \
        ${project_id:+"--project-id=${project_id}"} 2>/dev/null || echo 0)
    fi

    printf "${BOLD}%-9s${RESET} ${state_color}● %-4s${RESET}  inbox:%s\n" \
      "$agent" "$state_label" "$inbox_count"

    # タスク名（後タスクで実装、ここでは「（タスクなし）」固定）
    echo "  ↳ （タスクなし）"
    echo ""
  done

  # ─── フッター（後タスクで実装、ここでは省略）
  echo -e "──────────────────────────────────────────────────"
  echo -e "${CYAN}Ctrl+C で終了${RESET}"
}
```

- [ ] **Step 4: テストが通ることを確認する**

```bash
npm run test:integration -- --filter view
```

Expected: 追加した3テストすべてが PASS

- [ ] **Step 5: コミットする**

```bash
git add bin/shogun tests/integration/view.bats
git commit -m "feat(view): _view_render にエージェント busy/idle・inbox 表示を実装"
```

---

### Task 3: `_view_render()` — タスク名表示 + エラー耐性

**Files:**
- Modify: `bin/shogun` (`_view_render()` のタスク名セクション)
- Modify: `tests/integration/view.bats` (テストを追加)

**前提知識:**
- タスクファイルは `.shogun/queue/tasks/<agent>.yaml`
- スキーマは2種類ある：
  - 単一形式: `task: { task_id, description, status, ... }`
  - 配列形式: `tasks: [{ task_id, description, status, ... }]`
- 表示優先: `in_progress` > `done` > 先頭要素の順。`done` は `[done ✓]` を付記

- [ ] **Step 1: テストを追加する**

`tests/integration/view.bats` に以下を追加する：

```bash
@test "view render: タスクファイルがなくてもエラーにならず '（タスクなし）' が表示される" {
  # 全エージェントのタスクファイルが存在しない状態（init 直後の状態）
  rm -f "${TEST_PROJECT}/.shogun/queue/tasks/"*.yaml

  _run_view_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"（タスクなし）"* ]]
}

@test "view render: タスクの description が表示される" {
  # karo にタスクを書き込む
  cat > "${TEST_PROJECT}/.shogun/queue/tasks/karo.yaml" <<'YAML'
task:
  task_id: task_001
  description: "APIサーバーを実装する"
  status: in_progress
YAML

  _run_view_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"APIサーバーを実装する"* ]]
}

@test "view render: done タスクに [done ✓] が付く" {
  cat > "${TEST_PROJECT}/.shogun/queue/tasks/karo.yaml" <<'YAML'
task:
  task_id: task_001
  description: "テストを書く"
  status: done
YAML

  _run_view_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"done ✓"* ]]
}

@test "view render: queue.db が存在しなくても inbox:0 が表示される" {
  rm -f "${TEST_PROJECT}/.shogun/queue/queue.db"

  _run_view_render
  [ "$status" -eq 0 ]
  [[ "$output" =~ inbox:0 ]]
}
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
npm run test:integration -- --filter view
```

Expected: `タスクの description が表示される` と `done タスクに [done ✓] が付く` が FAIL

- [ ] **Step 3: `_view_render()` のタスク名表示を実装する**

`_view_render()` の `echo "  ↳ （タスクなし）"` の行を以下に置き換える：

```bash
    # タスク名
    local task_file="${SHOGUN_ROOT}/.shogun/queue/tasks/${agent}.yaml"
    local task_desc="（タスクなし）"
    if [[ -f "$task_file" ]]; then
      task_desc=$(node_yaml -e '
const yaml = require("js-yaml");
const d = yaml.load(require("fs").readFileSync(process.argv[1], "utf8")) || {};
let desc = "";
let isDone = false;
if (Array.isArray(d.tasks)) {
  const inProgress = d.tasks.find(t => t && t.status === "in_progress");
  const done = d.tasks.find(t => t && t.status === "done");
  const t = inProgress || done || d.tasks[0];
  if (t) {
    desc = (t.description || "").slice(0, 80);
    isDone = t.status === "done";
  }
} else if (d.task) {
  desc = (d.task.description || "").slice(0, 80);
  isDone = d.task.status === "done";
}
if (desc) {
  process.stdout.write(desc + (isDone ? " [done ✓]" : ""));
} else {
  process.stdout.write("（タスクなし）");
}
' -- "$task_file" 2>/dev/null || echo "（タスクなし）")
    fi
    echo "  ↳ ${task_desc}"
```

- [ ] **Step 4: テストが通ることを確認する**

```bash
npm run test:integration -- --filter view
```

Expected: Task 3 で追加した4テストすべてが PASS

- [ ] **Step 5: コミットする**

```bash
git add bin/shogun tests/integration/view.bats
git commit -m "feat(view): _view_render にタスク名表示とエラー耐性を実装"
```

---

### Task 4: `_view_render()` — コマンドキュー + tmux フッター

**Files:**
- Modify: `bin/shogun` (`_view_render()` のキュー・フッターセクション)
- Modify: `tests/integration/view.bats` (テストを追加)

- [ ] **Step 1: テストを追加する**

`tests/integration/view.bats` に以下を追加する：

```bash
@test "view render: コマンドキューの内容が表示される" {
  shogun task "APIサーバーを実装してください" >/dev/null

  _run_view_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"APIサーバーを実装してください"* ]]
  [[ "$output" == *"pending"* ]]
}

@test "view render: tmux セッションが停止中でもエラーにならない" {
  # tmux セッションは存在しない状態（テスト環境では未起動）
  _run_view_render
  [ "$status" -eq 0 ]
  # 停止マーク '○' か稼働マーク '●' のどちらかが表示される
  [[ "$output" == *"tmux:"* ]]
}
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
npm run test:integration -- --filter view
```

Expected: `コマンドキューの内容が表示される` が FAIL（`（準備中）` しか出ない）

- [ ] **Step 3: コマンドキューセクションを実装する**

`_view_render()` の以下の行：

```bash
  # ─── コマンドキュー（後タスクで実装、ここでは省略）
  echo -e "${BOLD}[ コマンドキュー ]${RESET}"
  echo "  （準備中）"
  echo ""
```

を以下に置き換える：

```bash
  # ─── コマンドキュー
  echo -e "${BOLD}[ コマンドキュー ]${RESET}"
  local queue_file="${SHOGUN_ROOT}/.shogun/queue/shogun_to_karo.yaml"
  if [[ -f "$queue_file" ]]; then
    node_yaml -e '
const yaml = require("js-yaml");
const data = yaml.load(require("fs").readFileSync(process.argv[1], "utf8")) || {commands: []};
const cmds = data.commands || [];
const max = 5;
const shown = cmds.slice(0, max);
if (shown.length === 0) {
  console.log("  （なし）");
} else {
  shown.forEach(c => {
    const id    = String(c.id || "?");
    const status = c.status || "unknown";
    const cmd60  = (c.command || "").slice(0, 60);
    const color  = status === "done" ? "\x1b[32m" : "\x1b[33m";
    console.log("  " + id + " " + color + "[" + status + "]\x1b[0m " + cmd60);
  });
  if (cmds.length > max) {
    console.log("  ... 他" + (cmds.length - max) + "件");
  }
}
' -- "$queue_file" 2>/dev/null || echo "  （読み取り失敗）"
  else
    echo "  （なし）"
  fi
  echo ""
```

- [ ] **Step 4: フッターセクションを実装する**

`_view_render()` の以下の行：

```bash
  # ─── フッター（後タスクで実装、ここでは省略）
  echo -e "──────────────────────────────────────────────────"
  echo -e "${CYAN}Ctrl+C で終了${RESET}"
```

を以下に置き換える：

```bash
  # ─── フッター
  echo -e "──────────────────────────────────────────────────"
  local taisho_status multi_status
  if tmux has-session -t "$(tmux_exact_target "$session_taisho")" 2>/dev/null; then
    taisho_status="${GREEN}●${RESET} ${session_taisho}"
  else
    taisho_status="${RED}○${RESET} ${session_taisho} (停止)"
  fi
  if tmux has-session -t "$(tmux_exact_target "$session_multi")" 2>/dev/null; then
    multi_status="${GREEN}●${RESET} ${session_multi}"
  else
    multi_status="${RED}○${RESET} ${session_multi} (停止)"
  fi
  echo -e "tmux: ${taisho_status}  ${multi_status}"
  echo -e "${CYAN}Ctrl+C で終了${RESET}"
```

- [ ] **Step 5: テストが通ることを確認する**

```bash
npm run test:integration -- --filter view
```

Expected: Task 4 で追加した2テストが PASS

- [ ] **Step 6: コミットする**

```bash
git add bin/shogun tests/integration/view.bats
git commit -m "feat(view): _view_render にコマンドキューと tmux フッターを実装"
```

---

### Task 5: `cmd_view()` ライブループ実装 + ヘルプ更新 + 全テスト通過

**Files:**
- Modify: `bin/shogun` (`cmd_view()` をライブループに置き換え、`cmd_help()` に `view` を追加)

- [ ] **Step 1: `cmd_view()` をライブループに置き換える**

`bin/shogun` の `cmd_view()` を以下に置き換える：

```bash
cmd_view() {
  require_init

  # tput smcup（代替スクリーン）の対応確認と切り替え
  # 対応していれば smcup が既に実行されているので tput cup 0 0 で先頭へ戻す
  # 非対応環境（TERM=dumb など）では clear で fallback
  local use_altscreen=true
  if ! tput smcup 2>/dev/null; then
    use_altscreen=false
  fi

  if [[ "$use_altscreen" == "true" ]]; then
    trap 'tput rmcup; exit 0' INT TERM
  else
    trap 'exit 0' INT TERM
  fi

  while true; do
    if [[ "$use_altscreen" == "true" ]]; then
      tput cup 0 0
      tput ed 2>/dev/null || true
    else
      clear
    fi
    _view_render
    sleep 2
  done
}
```

- [ ] **Step 2: `cmd_help()` に `view` を追加する**

`bin/shogun` の `cmd_help()` 内、`status` の行：

```bash
  echo -e "  ${CYAN}status${RESET}                       現在の状態を表示"
```

の直後に以下を挿入する：

```bash
  echo -e "  ${CYAN}view${RESET}                         エージェント状態をライブ表示（Ctrl+C で終了）"
```

- [ ] **Step 3: 全テストを実行する**

```bash
npm test
```

Expected: 全テスト PASS、エラーなし

- [ ] **Step 4: コミットする**

```bash
git add bin/shogun
git commit -m "feat(view): cmd_view ライブループとヘルプ更新を実装"
```

---

## 動作確認（手動テスト）

実際の Shogun プロジェクトで以下を確認する：

```bash
cd /path/to/your-shogun-project
shogun view
# → 代替スクリーンに切り替わり、2秒ごとに更新される
# Ctrl+C で元の画面に戻ることを確認する

shogun help
# → 一覧に "view" が表示されることを確認する
```
