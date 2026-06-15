# CLAUDE.md

このファイルは Shogun リポジトリ**そのものを開発する際**に Claude Code が参照する
コーディングガイドです。

> **混同に注意**: `templates/CLAUDE.md` と `shogun init` 後に生成される
> `.shogun/CLAUDE.md` は、Shogun フレームワークの**エージェント実行時**（Karo や Ashigaru など）が
> 読むための別物です。本ファイル（リポジトリルートの `CLAUDE.md`）とは役割が異なります。

## プロジェクト概要

Shogun は AI エージェントを武家社会の階層構造で統率する、ローカルオーケストレーションフレームワークです。
本体は Bash で書かれた CLI（`bin/shogun`）と、エージェント間通信を担う YAML キューで構成されます。
エージェント間通信はポーリングせず、`fswatch`（macOS）/ `inotifywait`（Linux）による
ファイル変更検知で wake-up します。

詳細は [README.md](README.md)、開発環境の構築・動作確認は
[DEVELOPMENT.md](DEVELOPMENT.md) を参照してください。

## ディレクトリ構成と役割

新しいファイルをどこに置くか迷ったら、まずこの表を確認してください。

| ディレクトリ / ファイル | 役割 |
|------------------------|------|
| `bin/` | グローバル CLI 本体（`shogun`）。`init` / `start` / `task` / `status` などのサブコマンドを実装。 |
| `scripts/` | **フレームワーク実行時のランタイムスクリプト**。`shogun start` で起動したエージェントが実際に使う。エージェント間通信系（`inbox_write.sh`：メッセージ送信、`inbox_watcher.sh`：ファイル監視 → tmux wake-up）と、Claude Code フック系（`inject_role.sh`・`stop_hook.sh`・`mark_busy.sh`）、共有ヘルパー（`flag_names.sh`：busy/idle フラグ名の単一情報源）から成る。フックの呼び出し経路は後述の「フック機構」を参照。 |
| `.github/scripts/` | **リポジトリ管理用の開発ツール**。リリース作業など、フレームワークの実行とは無関係に開発者・CI が使う。例: `release.sh`。 |
| `.github/workflows/` | GitHub Actions のワークフロー定義（`release.yml` など）。 |
| `templates/` | `shogun init` でユーザーのプロジェクトにコピーされる雛形。エージェント用の `CLAUDE.md`・`instructions/`・`config/settings.yaml`・`.claude/settings.json`（フック定義）・`dashboard.md`（進捗ボード雛形）・`memory/`（永続記憶）などを含む。 |
| `tests/unit/` | `scripts/*.sh` の関数レベルのテスト（bats）。 |
| `tests/integration/` | `bin/shogun` サブコマンドの振る舞いのテスト（bats）。 |
| `tests/bats/` | テストランナー bats-core（git submodule）。直接編集しない。 |
| `tests/test_helper.bash` | テスト共通ヘルパー（PATH / NODE_PATH 設定など）。 |
| `docs/` | 開発者向けドキュメント（`development.md`）。 |
| `install.sh` | `curl \| bash` 用インストーラー。リリース時にバージョンが埋め込まれる。 |
| `package.json` | `js-yaml` 依存とテストスクリプト（`npm test` ほか）。 |

### `scripts/` と `.github/scripts/` の使い分け

新しいスクリプトを追加するときの判断基準:

- **エージェント実行時に動くもの** → `scripts/`
  （`shogun start` 後のランタイムで呼ばれる。`SHOGUN_ROOT` などの環境変数に依存する）
- **リポジトリの開発・運用で使うもの** → `.github/scripts/`
  （リリース、CI 補助など。フレームワークのランタイムからは呼ばれない）

## フック機構

エージェントの自律実行と状態管理は、Claude Code の**フック**で実現している。
フック定義は `templates/.claude/settings.json` にあり、`shogun init` で各プロジェクトの
`.claude/settings.json` にコピーされる。各フックは `$SHOGUN_BIN_DIR/scripts/` 配下の
スクリプトを呼び出す（`SHOGUN_BIN_DIR` は `shogun start` が自動設定）。

| フックイベント | 呼び出すスクリプト | 役割 |
|----------------|--------------------|------|
| `SessionStart` | `scripts/inject_role.sh` | 起動 / resume / clear / compact のたびに、役職アイデンティティと役割定義を `additionalContext` として注入する。 |
| `Stop` | `scripts/stop_hook.sh` | ターン完了時に idle フラグを立て、inbox 未読があれば自己 wake-up メッセージを出力して自律継続を担保する（#55・#86）。 |
| `UserPromptSubmit` | `scripts/mark_busy.sh` | ターン開始時に idle フラグを削除して busy 状態へ遷移し、busy/idle 判定を正確に保つ。 |

busy/idle・reports pending フラグの**命名は `scripts/flag_names.sh` に集約**されており、
フックスクリプト群と `inbox_watcher.sh`、テストはこれを source して同じ命名規則を共有する。
フック系スクリプトを変更するときは、フラグ名の単一情報源である `flag_names.sh` との整合に注意する。

## 開発時のルール

- **言語**: Bash（`bin/`・`scripts/`・`.github/scripts/`）。すべて `set -euo pipefail` を先頭に置く。
- **YAML 操作**: `node` + `js-yaml` を使う（`scripts/` 配下では `NODE_PATH` を `../node_modules` に設定済み）。
- **テスト**: 変更後は必ず `npm test` を通す。スクリプトの関数は `tests/unit/`、CLI の振る舞いは `tests/integration/` にテストを追加する。
- **セキュリティ**: 役職名・エージェント ID を扱う箇所では、パストラバーサル防止のため
  `^[A-Za-z0-9_-]+$` でバリデーションする（既存実装に倣う）。
- **macOS の flock**: `util-linux` は keg-only のため、`/opt/homebrew/opt/util-linux/bin` を
  PATH に補完する処理が `scripts/inbox_write.sh` と `tests/test_helper.bash` にある。手動設定は不要。
- **submodule**: クローン・CI では `--recursive`（または `git submodule update --init --recursive`）が必要。

## テストの実行

```bash
npm test                   # 全テスト（unit + integration）
npm run test:unit          # tests/unit/ のみ
npm run test:integration   # tests/integration/ のみ
```

## リリース

リリース手順は `.github/scripts/release.sh`（`main` ブランチ・semver 必須）で行い、
タグ push をトリガーに `.github/workflows/release.yml` が GitHub Release を作成します。
`package.json` の `version` とタグが一致している必要があります。
