# shogun view コマンド 設計ドキュメント

**作成日**: 2026-06-17  
**ステータス**: 承認済み

---

## 概要

`shogun view` は、実行中の全エージェントの状態をリアルタイムで表示するライブモニターコマンドです。複数エージェントが並列動作する Shogun では、「誰が何をしているか」が秒単位で変わるため、自動更新される監視画面として実装します。

---

## アーキテクチャ

### 実装方針

`bin/shogun` に `cmd_view()` 関数を追加します。新規ファイルは作らず、既存コードへの追加のみで完結します。

```
shogun view
  └─ cmd_view()
       ├─ require_init           # 未初期化プロジェクトを弾く
       ├─ tput smcup             # 代替スクリーンへ切り替え
       ├─ trap 'tput rmcup; exit' INT TERM   # Ctrl+C で元画面に復帰
       └─ while true; do
            _view_render()       # 画面描画関数
            sleep 2
          done
```

### データソース

| 表示項目 | ソース |
|----------|--------|
| エージェント一覧 | `config.yaml` の `agents.ashigaru_count` |
| busy/idle 状態 | `/tmp/shogun_idle_<key>_<role>` の存在有無 |
| inbox 未読数 | `packages/mcp-queue/cli.js inbox_unread_count` |
| 現在のタスク | `.shogun/queue/tasks/<agent>.yaml` |
| コマンドキュー | `.shogun/queue/shogun_to_karo.yaml` |
| tmux セッション稼働 | `tmux has-session` |

`_view_render()` は独立した関数として実装し、ライブループとは分離します。これによりテストからも直接呼び出せます。

---

## 出力フォーマット

```
╔══════════════════════════════════════════════════╗
  ⛩  Shogun View: myproject       更新: 14:32:05
╚══════════════════════════════════════════════════╝

[ コマンドキュー ]
  #cmd-001 [pending] APIサーバーを実装してください
  #cmd-002 [done]    テスト環境の構築

[ エージェント ]
taisho    ● BUSY   inbox:0
  ↳ 設計方針の確定と各エージェントへの指示出し

karo      ● idle   inbox:2
  ↳ （タスクなし）

gunshi    ● idle   inbox:0
  ↳ （タスクなし）

metsuke   ● idle   inbox:0
  ↳ （タスクなし）

ashigaru1 ● BUSY   inbox:0
  ↳ REST APIエンドポイントの実装

ashigaru2 ● idle   inbox:1
  ↳ テストコードの作成 [done ✓]

ashigaru3 ● BUSY   inbox:0
  ↳ フロントエンドコンポーネントの実装

──────────────────────────────────────────────────
tmux: ● taisho-myproject  ● multiagent-myproject
Ctrl+C で終了
```

### 表示ルール

- **BUSY**: idle フラグファイルが存在しない状態。黄色でハイライト
- **idle**: idle フラグファイルが存在する状態。緑色で表示
- **タスク名**: `tasks/<agent>.yaml` の `task.description`（単一タスク形式）または `tasks[].description`（配列形式）を先頭80文字で切り詰め。`in_progress` のタスクを優先表示
- **タスクステータス**: `done` の場合は `[done ✓]`、`in_progress` の場合は表示をそのまま（BUSYバッジと連動）
- **コマンドキュー**: 最大5件表示（多い場合は `... 他X件` と省略）
- **更新時刻**: `date '+%H:%M:%S'` で現在時刻を毎サイクル更新

---

## エラーハンドリング

| ケース | 挙動 |
|--------|------|
| `shogun init` 未実行 | `require_init` で弾く（他サブコマンドと同様） |
| tmux セッション停止中 | フッターに `○ 停止` と表示して続行 |
| `queue.db` 不在（MCP未起動） | inbox を 0 件として扱い続行 |
| タスクファイル不在 | `（タスクなし）` として扱い続行 |
| `tput` 非対応環境 | 代替スクリーンをスキップし `clear` で fallback |
| Ctrl+C / SIGTERM | `trap` で `tput rmcup` を実行し元画面を復元してから終了 |

基本方針: どのエラーも「表示を止めずに続行」。`_view_render()` 内の個別エラーはサイレントに無視し、クラッシュしない。

---

## テスト方針

`tests/integration/` に以下を追加します。ライブループ（`while true`）はテスト対象外とし、`_view_render()` を直接呼び出して出力を検証します。

| テストケース | 確認内容 |
|---|---|
| init 前の `shogun view` 実行 | エラー終了する（exit code 非ゼロ） |
| busy エージェントの表示 | `● BUSY` が出力に含まれる |
| idle エージェントの表示 | `● idle` が出力に含まれる |
| inbox 未読数の反映 | `inbox:N` 形式の表示が出る |
| タスクファイルなし | エラーにならず `（タスクなし）` が表示される |
| tmux セッション停止中 | エラーにならずフッターに `○ 停止` が表示される |
| queue.db 不在 | エラーにならず inbox:0 が表示される |

---

## スコープ外（将来の拡張候補）

以下は今回の実装に含めません：

- `--interval N` オプション（更新間隔の変更）
- `shogun view <agent>` によるペインアタッチ
- `--once` フラグ（スナップショット出力）
- ログの末尾表示

---

## 実装箇所

- **追加先**: `bin/shogun`
- **追加関数**: `cmd_view()`、`_view_render()`
- **サブコマンド登録**: `case "$1" in ... view) cmd_view "$@" ;;` を追加
- **ヘルプ更新**: `cmd_help()` に `view` の説明を追加
- **テスト追加**: `tests/integration/view.bats`（新規ファイル）
