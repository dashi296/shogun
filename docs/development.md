# 開発環境セットアップ & 動作確認手順

## 前提ツール

| ツール | 用途 | インストール方法 |
|--------|------|-----------------|
| Node.js 18+ | js-yaml (YAML読み書き) | [nodejs.org](https://nodejs.org/) |
| Git | リポジトリ管理 | `brew install git` |
| tmux | エージェント用マルチセッション | `brew install tmux` |
| flock | inbox_write.sh の排他制御 | `brew install util-linux` (macOS) |
| fswatch | inbox_watcher.sh のファイル監視 | `brew install fswatch` (macOS) |
| bats-core | テストランナー | サブモジュールとして同梱（追加インストール不要） |
| Claude Code CLI | エージェント実行（動作確認時のみ） | [claude.ai/download](https://claude.ai/download) |

> **macOS の注意**: `flock` は `util-linux` が keg-only のため PATH に入りません。
> `tests/test_helper.bash` と `scripts/inbox_write.sh` が `/opt/homebrew/opt/util-linux/bin` を自動補完するため、手動設定は不要です。

---

## 1. リポジトリのセットアップ

```bash
# クローン（サブモジュール込み）
git clone --recursive git@github.com:dashi296/shogun.git
cd shogun

# サブモジュールを後から初期化する場合
git submodule update --init --recursive

# 依存パッケージをインストール（js-yaml）
npm install
```

---

## 2. テストの実行

### 全テスト

```bash
npm test
```

期待される出力:

```
1..32
ok 1 inbox_write: exits 0 on valid message
ok 2 inbox_write: writes message to YAML file
...
ok 32 task: fails outside initialized directory
```

### テスト種別を絞って実行

```bash
npm run test:unit          # 単体テストのみ (tests/unit/)
npm run test:integration   # 統合テストのみ (tests/integration/)
```

### テストファイルを直接指定

```bash
tests/bats/bin/bats tests/unit/inbox_write.bats
tests/bats/bin/bats tests/integration/init.bats
```

### 特定のテストケースのみ実行

```bash
tests/bats/bin/bats --filter "inbox_write: writes message" tests/unit/inbox_write.bats
```

---

## 3. CLI の手動動作確認

`bin/` を PATH に追加して shogun コマンドを直接使います。

```bash
export PATH="$(pwd)/bin:$PATH"
export PATH="/opt/homebrew/opt/util-linux/bin:$PATH"   # macOS のみ
```

### 3-1. shogun doctor（環境診断）

```bash
mkdir -p /tmp/shogun-test && cd /tmp/shogun-test
shogun doctor
```

期待される出力（環境が整っている場合）:

```
=== Shogun Doctor ===

[ 依存ツール ]
  ✓ tmux
  ✓ Claude Code CLI
  ✓ Node.js
  ✓ flock
  ✓ js-yaml (...)
  ✓ fswatch
  ...
```

### 3-2. shogun init（プロジェクト初期化）

```bash
mkdir -p /tmp/shogun-test && cd /tmp/shogun-test
shogun init
```

確認すること:

```bash
# ディレクトリ構造が作成されている
find .shogun -type f | sort

# config.yaml に project_name が設定されている
cat .shogun/config.yaml

# 各エージェントの inbox が空の YAML で初期化されている
cat .shogun/queue/inbox/karo.yaml   # → "messages: []\n"
```

### 3-3. shogun task（タスク投入）

```bash
cd /tmp/shogun-test
shogun task "認証機能を実装してください"
```

確認すること:

```bash
# コマンドキューに追加されている
cat .shogun/queue/shogun_to_karo.yaml
# → id: cmd_001, status: pending

# karo の inbox に通知が届いている
cat .shogun/queue/inbox/karo.yaml
# → messages に 1 件 (status: unread)
```

複数タスクの連番確認:

```bash
shogun task "テスト追加"
shogun task "ドキュメント更新"
cat .shogun/queue/shogun_to_karo.yaml
# → cmd_001, cmd_002, cmd_003
```

### 3-4. shogun status（状態確認）

```bash
cd /tmp/shogun-test
shogun status
```

確認すること:

- コマンドキュー一覧 (id・status・説明) が表示される
- `taisho / karo / gunshi / metsuke / ashigaru1〜3` のタスク数が表示される
- tmux セッション稼働状況が表示される

### 3-5. ashigaru_count の変更確認

```bash
# config.yaml で人数を変更
cd /tmp/shogun-test
sed -i '' 's/ashigaru_count: 3/ashigaru_count: 5/' .shogun/config.yaml

shogun status
# → ashigaru1〜5 が全て表示されること
```

### 3-6. scripts の単体確認

```bash
cd /tmp/shogun-test
mkdir -p .shogun/queue/inbox

# inbox_write.sh を直接実行
SHOGUN_ROOT="$(pwd)" SHOGUN_ROLE="taisho" \
  bash /path/to/shogun-repo/scripts/inbox_write.sh karo "テスト件名" "テスト本文"

# 書き込み結果を確認
cat .shogun/queue/inbox/karo.yaml
```

### 後片付け

```bash
rm -rf /tmp/shogun-test
```

---

## 4. テストの追加方法

### ファイル配置

| テスト対象 | 配置場所 |
|-----------|----------|
| `scripts/*.sh` の関数レベル | `tests/unit/` |
| `bin/shogun` サブコマンドの振る舞い | `tests/integration/` |

### テンプレート

```bash
#!/usr/bin/env bats
load '../test_helper'

setup() {
  # 単体テスト: setup_test_project
  # 統合テスト: init_test_project && cd "${TEST_PROJECT}"
  init_test_project
  cd "${TEST_PROJECT}"
}

teardown() {
  teardown_test_project
}

@test "feature: does something expected" {
  run shogun <command>
  [ "$status" -eq 0 ]
  [[ "$output" == *"expected string"* ]]
}
```

### YAML の値を検証する

`yaml_query` ヘルパーを使います:

```bash
@test "example: checks yaml value" {
  shogun task "some task"
  run node -e "
const yaml = require('js-yaml');
const d = yaml.load(require('fs').readFileSync('.shogun/queue/shogun_to_karo.yaml', 'utf8'));
process.stdout.write(d.commands[0].status);
"
  [ "$output" = "pending" ]
}
```

---

## 5. ディレクトリ構成（開発者向け）

```
shogun/
├── bin/
│   └── shogun              # グローバル CLI（Bash）
├── scripts/
│   ├── inbox_write.sh      # エージェント間メッセージ送信
│   └── inbox_watcher.sh    # ファイル変更監視 → tmux wake-up
├── templates/              # shogun init でプロジェクトにコピーされる雛形
│   ├── CLAUDE.md
│   ├── .gitignore.append
│   ├── config/
│   │   └── settings.yaml   # デフォルト設定（ashigaru_count: 3 など）
│   ├── instructions/       # 各役職のプロンプト
│   └── memory/
├── tests/
│   ├── bats/               # bats-core（git submodule）
│   ├── test_helper.bash    # 共通ヘルパー（PATH / NODE_PATH 設定など）
│   ├── unit/
│   │   └── inbox_write.bats
│   └── integration/
│       ├── init.bats
│       ├── task.bats
│       └── status.bats
├── docs/
│   └── development.md      # このファイル
├── install.sh              # curl | bash インストーラー
└── package.json            # js-yaml 依存 + テストスクリプト
```

---

## 6. トラブルシューティング

### `flock: command not found`

```bash
# macOS
brew install util-linux
# PATH に追加（シェルを再起動するか source ~/.zshrc）
echo 'export PATH="/opt/homebrew/opt/util-linux/bin:$PATH"' >> ~/.zshrc
```

### `Cannot find module 'js-yaml'`

```bash
# リポジトリルートで実行
npm install
```

### `bats: command not found`

サブモジュールが初期化されていません:

```bash
git submodule update --init --recursive
```

### `shogun: command not found`

```bash
export PATH="/path/to/shogun-repo/bin:$PATH"
```
