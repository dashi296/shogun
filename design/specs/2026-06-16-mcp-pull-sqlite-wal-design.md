# エージェント間通信 MCP プル型（案B）＋ SQLite WAL 移行設計

- 日付: 2026-06-16
- ステータス: ドラフト（実装判断前）
- 対象: Shogun フレームワークのエージェント間通信（配信層・保管層）
- 関連 issue: [#98](https://github.com/dashi296/shogun/issues/98), [#111](https://github.com/dashi296/shogun/issues/111)

## 背景

### 現行方式（案A ベース）

現行の通信は **YAML ファイル + fswatch/inotifywait + `tmux send-keys`** で構成される。

**スクリプト構成（`scripts/` 配下）:**

| スクリプト | 役割 |
|---|---|
| `inbox_write.sh` | `flock` + `node + js-yaml` で YAML に append。`MSG_ID` = `date + PID` で採番。 |
| `inbox_watcher.sh` の `watch_inbox` | `fswatch -o` / `inotifywait -e close_write` で YAML 更新を検知 → `wake_up_inbox` を呼び出し、未読件数を node でパースし `notify_pane` へ渡す |
| `inbox_watcher.sh` の `watch_reports` | 同様に `reports/` を監視。`should_wake_on_report` で allowlist に一致するファイルのみ `wake_up_reports` を起動 |
| `inbox_watcher.sh` の `watch_escalation` | ASW（Agent Self-Watch）。`pane_activity` を定期ポーリングし、3段階（nudge / Ctrl-C / /clear）でエスカレーション |
| `inbox_watcher.sh` の `notify_pane` | `flock -w 5` でペイン単位の排他を取り、`tmux send-keys` で「本文 → sleep → Enter」の2段送出 |
| `flag_names.sh` | `shogun_idle_flag` / `shogun_reports_pending_flag` の命名を単一管理。`SHOGUN_ROOT` 由来の cksum キーでリポジトリ間の名前空間を分離 |

**保管形式:**

- 通常時: `.shogun/queue/inbox/{role}.yaml`
- プロジェクト時: `.shogun/queue/projects/{project_id}/inbox/{role}.yaml`
- 構造: `messages: [{id, from, timestamp, subject, body, status}]`

### 現行方式の問題点

根本原因は**配信層が「対話 TUI への外部キー注入」**であること:

1. 同一ペインに最大3つのバックグラウンド監視（`watch_inbox` / `watch_reports` / `watch_escalation`）が独立して `tmux send-keys` を撃つ
2. `notify_pane` は「本文 → sleep 0.3s → Enter」の非アトミック2段構成。ペイン単位の `flock` で排他はあるが、3プロセス間の送出タイミングが競合しうる
3. `wake_up_inbox` と `wake_up_reports` は `is_agent_idle` フラグ（`/tmp/shogun_idle_*`）で busy 中のナッジを防いでいるが、フラグの立て下げとエージェントの実際の処理状態の間にレース条件がある
4. Claude のターン処理中（ヒアドキュメント実行・TUI 描画中）への注入が出力破損を引き起こす

→ **保管層を変えても配信が外部注入のままなら破損は残る。**

## 設計方針（案B + SQLite WAL）

**配信を「外部からの注入」から「Claude 自身のターン中のプル」へ転換する。**

外部からの `tmux send-keys` 本文注入を廃止し、Claude が MCP ツール（`inbox_check` 等）を
自分のターン中に呼び出してメッセージを取得する。保管層を SQLite（WAL モード）に置き換え、
YAML の read-modify-write 競合と `flock` 運用・`node + js-yaml` 都度パースを解消する。

## アーキテクチャ

### 層の対応

| 層 | 現状（案A ベース） | 本案（案B + SQLite） |
|---|---|---|
| 保管・搬送 | YAML ファイル（`inbox_write.sh` が flock + node で append） | **SQLite（WAL モード）** — `messages` / `reports` テーブル |
| 配信（Claude に届ける） | `tmux send-keys` で TUI に本文を注入（`notify_pane`） | **MCP ツールでプル**（`inbox_check` / `inbox_send` 等）— 外部注入ゼロ |
| 待機中エージェントの起動 | `watch_inbox` / `watch_reports` が未読検知 → send-keys でナッジ | **idle 限定の最小ナッジ**（中身なし単発打鍵のみ）— 案A の idle フラグ流用 |

### 保管層：SQLite（WAL モード）

**スキーマ（概案）:**

```sql
-- メッセージ（inbox に相当）
CREATE TABLE messages (
  id          TEXT PRIMARY KEY,          -- msg_{timestamp}_{pid}
  project_id  TEXT NOT NULL DEFAULT '',  -- 空文字 = プロジェクト未設定
  from_role   TEXT NOT NULL,
  to_role     TEXT NOT NULL,
  subject     TEXT NOT NULL,
  body        TEXT NOT NULL DEFAULT '',
  status      TEXT NOT NULL DEFAULT 'unread',  -- unread | read
  created_at  TEXT NOT NULL,
  read_at     TEXT
);

-- 報告（reports に相当）
CREATE TABLE reports (
  id          TEXT PRIMARY KEY,
  project_id  TEXT NOT NULL DEFAULT '',
  src_role    TEXT NOT NULL,
  payload     TEXT NOT NULL,             -- YAML 文字列 or JSON
  created_at  TEXT NOT NULL,
  consumed_at TEXT
);
```

**WAL モードの利点:**
- 複数リーダー + 単一ライターを許容（現行の `flock` 排他が不要）
- トランザクションによる原子的更新（read-modify-write 競合の解消）
- `node + js-yaml` の都度パースが不要になる

**ファイル配置（案）:**
- 通常時: `.shogun/queue/queue.db`
- プロジェクト時: `.shogun/queue/projects/{project_id}/queue.db`
- `.gitignore` 方針: YAML と同様に除外（`.shogun/` が既に除外対象）

### 配信層：MCP サーバ（プル型）

MCP サーバを `.mcp.json` でプロジェクトに配布し、Claude が自分のターン中にツールを呼び出す。
外部からのキー注入が完全に廃止される。

**想定 MCP ツール（案）:**

| ツール名 | 引数 | 戻り値 | 現行対応 |
|---|---|---|---|
| `inbox_check(role, project_id?)` | role: string | 未読メッセージ一覧 | `wake_up_inbox` → node パース |
| `inbox_send(from, to, subject, body, project_id?)` | — | 採番 id | `inbox_write.sh` 全体 |
| `inbox_mark_read(message_ids)` | ids: string[] | — | YAML の status 書き換え |
| `report_submit(src, payload, project_id?)` | — | id | `inbox_write.sh` の reports 書き込み |
| `report_poll(sources, project_id?)` | sources: string[] | 未消費報告一覧 | `watch_reports` + `should_wake_on_report` |

**MCP サーバの実体:**
- SQLite を裏に持つ単一 Node.js プロセス（例: `@shogun/mcp-queue`）
- `shogun start` がプロセスを起動・停止。ライフサイクルは PID ファイルで管理

### wake（待機中エージェントの起動）

純プルでは idle エージェントがターンを開始しない。最小ナッジが必要:

- **内容**: 中身を持たない単発の打鍵のみ（ペインを起こすだけ）。メッセージ本文は MCP プルで取得するため注入文字列は最小
- **送出タイミング**: `is_agent_idle` が true のときのみ（案A と同じ idle フラグ流用）
- **既存流用**: `flag_names.sh` の `shogun_idle_flag` / `mark_busy.sh` / `stop_hook.sh` の idle 管理ロジックはそのまま使える

### report_poll の allowlist セマンティクス（階層バイパス防止）

> 関連 issue: [#111](https://github.com/dashi296/shogun/issues/111)

#### 現行の「階層フィルタ」責務

現行では `scripts/inbox_watcher.sh` の `should_wake_on_report` と、`shogun start` が設定する
`SHOGUN_REPORT_SOURCES` 環境変数が組み合わさって**報告集約の階層を強制**している。

```bash
# inbox_watcher.sh: Taisho の起動例（bin/shogun が設定）
# SHOGUN_REPORT_SOURCES=karo  →  Karo の集約報告にのみ反応
should_wake_on_report() {
  local base="$1" sources="$2" src
  [[ "$base" == *_report.yaml ]] || return 1
  for src in $sources; do
    [[ "$base" == "${src}_report.yaml" ]] && return 0
  done
  return 1
}
```

これにより Taisho は Ashigaru の個別報告では起動せず、必ず Karo の集約報告を経由する。
MCP プル型では任意のエージェントが `report_poll(sources=["ashigaru1"])` を呼べば
Karo を介さずに直接 Ashigaru の報告を取得でき、この階層が崩れる。

#### 設計オプション比較

| オプション | 概要 | 利点 | 欠点 |
|---|---|---|---|
| **(A) MCP サーバ側 role-based AC** | 呼び出し元の `from_role` に応じてサーバが `sources` フィルタを強制する。`SHOGUN_REPORT_SOURCES` を起動時設定としてサーバに渡す | 技術的強制。instructions に依存しない。既存 env 変数を継承可能 | MCP サーバの実装コスト増。role 認証が必要 |
| **(B) instructions での規約定義** | 役職ごとに呼び出せる `sources` の範囲を `instructions/*.md` に記載し、エージェントが自律的に守る | 実装コスト最小 | 技術的強制がないため逸脱が検知できない |
| **(C) SHOGUN_REPORT_SOURCES を MCP 設定として継承** | サーバ起動時に `SHOGUN_REPORT_SOURCES` を環境変数として渡し、サーバが呼び出し元問わずフィルタを適用する | 既存の `bin/shogun` 設定ロジックをほぼ流用できる | グローバル1プロセス構成を前提とした場合は全呼び出しに同一フィルタになる（役職ごとに個別プロセスを起動すれば役職別フィルタも実現可能だが、その場合は Option A と実質同一になる） |

#### 推奨: オプション (A) MCP サーバ側 role-based AC

**推奨理由:**
- `should_wake_on_report` の「技術的強制」という性質を MCP 層でも維持できる（単なる規約ではなくサーバが強制）
- `SHOGUN_REPORT_SOURCES` の命名・値をサーバ起動設定として継承することで、`bin/shogun` 側の変更を最小化できる（`shogun start` で既に役職ごとに異なる値を設定している実績がある）
- オプション (C) との差分は「`from_role` の真正性をサーバが検証するか否か」であり、実装コストの差は小さい

**from_role の真正性担保（Option A の実装方式）:**

MCP プロトコルには呼び出し元エージェントを認証する組み込み機構がないため、**MCP サーバを役職ごとに1プロセス起動し、起動引数（`--role=karo` 等）でサーバが自分の管轄 role を固定する**方式を採る。

```
# bin/shogun が役職ごとに個別の MCP サーバプロセスを起動（概念図）
shogun-mcp-server --role=taisho --allowed-sources="karo"       # Taisho 用
shogun-mcp-server --role=karo   --allowed-sources="gunshi metsuke ashigaru1 ..."  # Karo 用
```

各サーバプロセスは自分が管轄する role の `report_poll` リクエストのみを受け付け、
許可された `sources` 以外のデータを返さない。呼び出し元が `from_role` を引数で渡す設計は採らない（詐称可能なため）。
Claude の `.mcp.json` にはそれぞれの役職用サーバが設定され、エージェントは自分の role のサーバに接続する。

この方式は Option C と実質同一の環境変数継承を使いながら、サーバプロセス分離によって技術的強制を実現する。

#### allowlist 設計（役職ごとの poll 可能 src_role）

| 役職（呼び出し元） | poll 可能な src_role | 現行の対応 |
|---|---|---|
| **Taisho** | `["karo"]` のみ | `SHOGUN_REPORT_SOURCES=karo` |
| **Karo** | `["gunshi", "metsuke", "ashigaru1", "ashigaru2", ...]`（下位全員） | `SHOGUN_REPORT_SOURCES="gunshi metsuke ashigaru1 ..."` |
| **Metsuke** | `["ashigaru1", "ashigaru2", ...]`（レビュー対象 Ashigaru） | 監視なし（現行未実装。`*_review.yaml` は Ashigaru が直接書き込む。`SHOGUN_REPORT_SOURCES` は Metsuke に設定されない） |
| **Ashigaru** | `[]`（poll 権限なし。自分の report を submit するのみ） | reports/ への書き込みのみ |
| **Gunshi** | 役職定義に依存（未確定） | — |

`report_poll` を受け取った MCP サーバは、サーバプロセス起動時の `--role` 引数で固定された
管轄 role（リクエスト引数による `from_role` 渡しは採らない）と上記 allowlist を照合し、
`sources` に含まれる `src_role` のうち許可されたものだけを返す。

#### project_id スコープとの関係

`report_poll(sources, project_id?)` の `project_id` は**保管層のスコープ**（どの DB or テーブルを見るか）を決定し、allowlist（誰が誰の report を見られるか）とは直交する概念として扱う。

- `project_id` を指定すると `.shogun/queue/projects/{project_id}/queue.db` のデータのみを対象とする
- allowlist フィルタはその後に適用する（`project_id` フィルタ → allowlist フィルタの順）
- `project_id` 未指定はデフォルト DB を対象とし、同じ allowlist が適用される

両フィルタは直交するため適用順序は最終結果に影響しない。`project_id` フィルタを先にすることで DB クエリ（WHERE 句）レベルでデータを絞り込み、allowlist フィルタをアプリケーションレベルで適用する順序が実装上自然なため、上記の順序を採用する。

## 確定・未確定の判断

| 論点 | 判断 | 備考 |
|---|---|---|
| 配信をプル型へ転換 | **確定**（案B の核心） | 外部注入による出力破損の根本解決 |
| 保管を SQLite（WAL）へ | **確定**（案B の核心） | flock・js-yaml 都度パースを解消 |
| MCP サーバの言語・ランタイム | **未確定** | Node.js / Python 等。現行 node_modules 資産を流用か |
| DB ファイルの配置 | **未確定** | `.shogun/queue/queue.db` 案を提示。.gitignore 方針は現行踏襲 |
| MCP サーバのスコープ | **未確定** | プロジェクト単位1プロセス vs グローバル1プロセス + project_id スコープ |
| 移行戦略（YAML との共存期） | **未確定** | 段階移行かハードカットオーバーか |
| ヘッドレス/CI での MCP 不在 | **未確定** | 起動経路の差異・フォールバック方針 |
| report_poll の allowlist 方式 | **確定（推奨 A）** | MCP サーバを役職ごとに1プロセス起動し `--role` 引数で管轄 role を固定することで技術的強制を実現。`SHOGUN_REPORT_SOURCES` を起動設定として継承。役職ごとの poll 可能 src_role は上記テーブルのとおり |

## 案A との比較

| 観点 | 案A（Stop フック一本化＋idle 限定ナッジ） | 案B + SQLite WAL |
|---|---|---|
| 出力破損の根治 | ◯（本文注入を廃止し idle 限定ナッジへ） | ◎（注入を原理的に排除。Claude 自身がプル） |
| 実装コスト | 小（既存資産の延長・スクリプト修正のみ） | 中〜大（MCP サーバ新設 + SQLite スキーマ + 配布） |
| 保管の堅牢性 | 変わらず（YAML + flock のまま） | 向上（トランザクション・競合解消） |
| flock 運用 | 残る | 解消 |
| js-yaml 都度パース | 残る | 解消 |
| MCP プロセス管理 | 不要 | 必要（起動・停止・ヘルスチェック） |
| 既存テストの移行 | 最小（bash/bats テストほぼ流用） | 大（YAML ベース統合テストの全面改訂） |
| 依存・運用の複雑さ | 低 | 中（MCP サーバのライフサイクル管理） |
| 観測性 | 維持（tmux ペインは残る） | 維持（ペインは残す。MCP ログで補完） |
| CI / ヘッドレス対応 | 変わらず | 要検討（MCP 不在時のフォールバック） |

## スコープ外

- 直近の出力破損対策（案A の実装）— 別途 Stop フック一本化で対応済みまたは対応予定
- エージェントを完全ヘッドレス化（`claude -p`）する案C — 別途検討

## 未解決の論点

1. **MCP サーバのプロセス境界**: プロジェクト単位で1プロセスを起動するか、グローバル1プロセス + `project_id` カラムスコープにするか。前者はプロジェクト分離が明確だが起動管理が複雑。後者はシンプルだがプロジェクト間でDB を共有するリスクがある。

2. **SQLite ファイルの配置と .gitignore**: `.shogun/queue/queue.db` が自然だが、`.shogun/` は `.gitignore` 対象であり既存の YAML と同様に追跡対象外となる。WAL のジャーナルファイル（`-wal` / `-shm`）も除外が必要。

3. **未読ナッジの最小実装**: idle フラグの信頼性は現行 `flag_names.sh` + `stop_hook.sh` に依存する。ナッジの冪等性（二重打鍵の防止）をどう保証するか。

4. **YAML ベース統合テストの移行戦略**: `tests/unit/` と `tests/integration/` は YAML ファイル操作・bats テストで構成されている。SQLite 移行後は全面改訂が必要。段階的移行（YAML → SQLite デュアルライト期）か一括切り替えか。

5. **ASW（Agent Self-Watch）との整合**: `watch_escalation` の `pane_activity` 判定と3段階エスカレーションはペイン監視を前提とする。MCP プル型でもエスカレーションは必要だが、`pane_activity` の意味が変わる可能性がある。
