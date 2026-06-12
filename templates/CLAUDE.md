# Shogun システム共通設定

## セッション開始時に必ず行うこと

1. `echo "$SHOGUN_ROLE"` を実行して自分の役職を確認する（例: taisho / karo / ashigaru1）
2. `.shogun/instructions/<役職>.md` を読む（`ashigaru1` や `ashigaru2` など番号付きの場合は番号を除いた `ashigaru.md` を読む）
3. `.shogun/memory/MEMORY.md` を読む（存在する場合）
4. `.shogun/config.yaml` で現在の設定を確認

## 全エージェント共通の禁止事項

- ポーリングループ（`while true; do sleep 1; done` 等）の実行
- User への直接報告（必ず階層を通す）
- 担当外のファイルへの書き込み

## 通信プロトコル

> 以下の `{自分の役職}` は `$SHOGUN_ROLE` の値そのまま（ashigaru は番号付き。例: `ashigaru1` → `inbox/ashigaru1.yaml`）。
> 番号を除くのは instructions（`ashigaru.md`）を読むときだけで、inbox / tasks / reports のパスには番号付きの役職名を使う点に注意。

- 受信: `.shogun/queue/inbox/{自分の役職}.yaml` を読む
- 送信: `bash $SHOGUN_BIN_DIR/scripts/inbox_write.sh {相手} "{subject}" "{body}"` を実行
  （`$SHOGUN_BIN_DIR` は `shogun start` によって自動設定される。通常 `~/.local/share/shogun`）
- タスク: `.shogun/queue/tasks/{自分の役職}.yaml` を読む
- 報告: `.shogun/queue/reports/{自分の役職}_report.yaml` に書き込む

## Memory MCP（クロスセッション永続記憶）

`shogun init` で生成された `.mcp.json` により、Memory MCP サーバーが設定されます。
Memory MCP はナレッジグラフ形式で記憶を保持し、`/clear` やセッション再開後も文脈を復元できます。
記憶データは `.shogun/memory/memory.jsonl` に保存されます。

### Memory MCP とファイルベース記憶（.shogun/memory/）の使い分け

| | Memory MCP | ファイルベース記憶（MEMORY.md） |
|---|---|---|
| **形式** | ナレッジグラフ（エンティティ・関係） | Markdown（自由記述） |
| **書き込み** | MCP ツール経由（自動） | 手動または agents が記述 |
| **用途** | タスクパターン・エンティティ間の関係 | ユーザーの好み・重要決定の記録 |
| **検索** | エンティティ名・関係で検索可能 | テキスト検索 |

**基本方針**: 構造化された事実（人物・プロジェクト・タスクの関係）は Memory MCP へ、
自由な長期メモ（好み・判断の記録）はファイルベース記憶（`MEMORY.md`）へ書く。

### Memory MCP が未インストールの場合

`npx @modelcontextprotocol/server-memory` が初回実行時に自動インストールされます。
`npx` が使えない環境では `shogun doctor` で案内が表示されます。

## コンテキスト管理（/clear）

YAML キューファイル（inbox / tasks / reports）が状態の正（authoritative source of truth）である。
`/clear` で会話履歴を消してもこれらはファイルシステムに残るため、読み直せば現在地を復元できる。
MEMORY.md は長期記憶（ユーザーの好み・過去の決定）専用とし、セッション状態は書かない。

### /clear するタイミング
ひとつの要求・タスクグループへの対応が完了し、次の wake-up を待つ状態になったとき。

### /clear 後の復元手順
1. CLAUDE.md が自動再読み込みされる
2. `echo "$SHOGUN_ROLE"` を実行して自分の役職を確認する
3. `.shogun/instructions/<役職>.md` を読む（番号付き ashigaru は `ashigaru.md` を読む）
4. `.shogun/memory/MEMORY.md` を読む（存在する場合）
5. YAML ファイルで現在の状態を確認し、中断した作業があれば再開する
   （具体的な確認手順は各役職の instructions を参照）
