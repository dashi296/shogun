# agmsg 通信基盤への移行設計 — オンデマンド spawn/despawn オーケストレーション

- 日付: 2026-08-02（改訂: Codex レビュー5回目の指摘を反映）
- ステータス: 設計承認済み（実装計画は未作成）
- 対象: Shogun フレームワークのエージェント間通信・起動管理の再設計
- **関係**: [`2026-07-17-ichiryo-ichinin-architecture-design.md`](2026-07-17-ichiryo-ichinin-architecture-design.md) を置き換える。
  同ドキュメントは本設計の採用に伴い**廃止（superseded）**とする。
- **対応 agmsg バージョン**: `fujibee/agmsg` commit `1c7efbc005c50a7eb3cbd4bac9b1f6ab17825827`
  （tag `v1.1.12` = commit `6248bb0` の 3 コミット後）に固定する。
  role resume・herdr spawn 対応・tmux-resurrect 連携はいずれもこの commit
  **より前**（7月中）に導入済みの機能であり、本設計はそれらを前提として書かれている
  （「今後の main 追従で新たに入る機能」ではない点に注意）。

## 1. 背景と問題

現行の Shogun は 5 役職（Taisho / Karo / Gunshi / Metsuke / Ashigaru×N）すべてを
tmux ペイン上の常駐 LLM セッションとして起動し、`.shogun/queue/*.yaml` の
ファイル監視（fswatch/inotifywait）+ `packages/mcp-queue`（SQLite pull 型キュー）
の二重構成で通信する。

この構成には次の課題がある。

1. **常駐コスト**: `shogun start` のたびに 4+N 体の LLM セッションが一括起動し、
   実際にタスクがないロール（Gunshi/Metsuke など）もトークン・プロセスを常に消費する。
2. **通信機構の自前実装コスト**: YAML キュー + fswatch wake-up + SQLite pull キューの
   二重構成、busy/idle フラグ管理、Agent Self-Watch の 3 段階エスカレーションなど、
   通信・生存監視のための自前実装が `scripts/` に集中し、保守コストが高い。

外部 OSS の **agmsg**（[fujibee/agmsg](https://github.com/fujibee/agmsg)、
CLI エージェント間のクロスベンダーメッセージング）を採用し、通信層を委譲しつつ、
役職を「タスクがある時だけ起こす」オンデマンド spawn モデルに移行する。

### 検討の経緯（herdr 統合の見送り）

当初は agmsg に加えて **herdr**（[herdrdev/herdr](https://github.com/herdrdev/herdr)、
セッション永続化ランタイム）も採用し、tmux をまるごと herdr に置き換える設計を検討した。
Codex による技術レビューを複数ラウンド実施した結果、herdr 統合は以下の理由で
Phase 2（本設計のスコープ外）に切り出すこととした。

- herdr のネイティブセッション復元と agmsg の respawn が同一 CLI セッションを
  二重起動しうる問題があり、`resume_agents_on_restore` を無効化しても
  「復元済み空ペイン」と「agmsg の新規ペイン」が二重配置される新たな問題が生じる。
- agmsg は配送 ACK 付きキューではなく、herdr の cold restart 耐性を得るには
  fencing token・outbox パターン・epoch 管理を伴う永続 task journal が必要になり、
  当初想定した「軽量な移行」の域を超える。
- 詳細な指摘事項は本ドキュメント末尾の「Phase 2（将来課題）」に転記した。

Phase 1（本設計）では **tmux は現状の 2 セッション構成から 1 セッション構成へ変更**し
（理由は §5 参照）、herdr は使わない。

## 2. 設計方針

1. **通信は全面 agmsg 化**: `.shogun/queue/*.yaml`・`scripts/inbox_watcher.sh`・
   `packages/mcp-queue` を廃止し、agmsg の send/inbox/history/spawn/despawn に置換する。
2. **階層構造は維持しつつオンデマンド spawn で実現**: 固定役職名
   （karo/gunshi/metsuke/ashigaru1..N）の思想は残すが、常駐させるのは **Taisho のみ**
   （人間の窓口）。Karo 以下はタスクがある時だけ `agmsg spawn` で起動し、
   完了したら `agmsg despawn` で畳む。
3. **tmux は 1 セッション構成に統合する**: agmsg の tmux spawn 実装の制約
   （呼び出し元の現在 window/session にしか spawn できない）に従う。
4. **無応答復旧は Taisho→Karo、Karo→配下 の階層で行う**（Karo 自身が無応答の場合、
   Karo 自身には復旧できないため、Taisho が Karo を復旧する）。
5. **タスク完了は task_id ベースの軽量プロトコル**で扱う。再起動をまたぐ永続性は
   スコープ外とするが、**同一実行中（同一 `run_id`）の assign/result 双方向の
   retry・受領 ACK・重複排除は必須スコープに含める**。

## 3. agmsg の呼び出し API 契約（実装アダプタ）

agmsg は単一のシェル CLI コマンドではない。npm/インストーラーの `agmsg` 実行ファイルは
セットアップ処理のみを行い、実際のランタイム API は
`~/.agents/skills/<cmd>/scripts/*.sh` を直接呼び出す形で提供される
（`<cmd>` はインストール時に選んだコマンド名。既定 `agmsg`。Shogun は
`.shogun/config.yaml` の `agmsg.cmd_name` で明示的に指定し、複数 `<cmd>` が
存在する環境でも一意に解決できるようにする）。

Shogun 側に `scripts/agmsg_adapter.sh` を新設し、以下の**固定シグネチャ**で
各スクリプトへ委譲する（commit `1c7efbc005c...` 時点の実装に基づく）。

| Shogun アダプタ関数 | 委譲先 | シグネチャ |
|---|---|---|
| `agmsg_send` | `send.sh` | `<team> <from> <to> <message> [--force]` |
| `agmsg_spawn` | `spawn.sh` | `<type> <name> [--boot-prompt TEXT] [--project PATH] [--team TEAM] [--window] [--split h\|v] [--terminal TMPL] [--no-wait] [--ready-timeout N] [--model ID] [--fresh]` |
| `agmsg_despawn` | `despawn.sh` | `<team> <from> <name> [--force] [--timeout N]` |
| `agmsg_join` | `join.sh` | `<team> <agent> <type> <project> [--force]` |
| `agmsg_set_delivery` | `delivery.sh` | `set <mode> <type> <project>` |
| `agmsg_inbox` | `inbox.sh` | `<team> <agent>` |
| `agmsg_history` | `history.sh` | `<team> [--limit N]` |

- 各関数は委譲先スクリプトの **exit code をそのまま返し**、stdout をそのまま
  呼び出し元に渡す（Shogun 側で標準出力の書式を独自変換しない）。
- **導入手順**: agmsg のインストールは commit
  `1c7efbc005c50a7eb3cbd4bac9b1f6ab17825827` を checkout した状態で行う。
  `shogun doctor` は `version.sh` の出力が
  `v1.1.12` または `v1.1.12-N-g<short-sha>`（`git describe` 形式）であることを
  確認する。想定と異なるバージョンが検出された場合は警告し、
  本設計が前提とする API 契約と齟齬がありうることを明示する。
- **placement record**: agmsg の spawn/despawn は内部で
  `id<TAB>project<TAB>type` 形式の placement record ファイルを保持する。
  `scripts/agmsg_adapter.sh` に、このファイルを読む専用アクセサ
  （`agmsg_get_placement <team> <name>` のようなもの）を実装し、
  他のコードから直接パースさせない（フォーマット変更時の影響範囲を限定する）。

テストでは、このアダプタが呼び出す `send.sh`/`spawn.sh`/`despawn.sh`/`inbox.sh`/
`history.sh`/`join.sh`/`delivery.sh` を個別に fake 実装へ差し替える。

## 4. 全体アーキテクチャ

```
あなた
  │ shogun start
  ▼
tmux セッション起動（1 セッション構成、詳細は §5）
  │
  ▼
Taisho（tmux 常駐ペイン・人間の窓口。exclusive watcher 成立手順は §7）
  │ shogun task "..." → agmsg_send <team> shogun taisho "..."
  │
  │ 未起動なら agmsg_spawn claude-code karo --model <worker_model> --boot-prompt "<task>"
  ▼
Karo（オンデマンド、作業完了で despawn。無応答時は Taisho が復旧）
  │ 必要に応じて（無応答時は Karo が復旧）
  ├─ agmsg_spawn claude-code gunshi --model <worker_model>
  ├─ agmsg_spawn claude-code metsuke --model <worker_model>
  └─ agmsg_spawn claude-code ashigaru1..N --model <worker_model>
```

- 常駐するのは Taisho のみ。**Karo/Gunshi/Metsuke/Ashigaru はすべて `worker_model`
  を使う**（Taisho だけが `taisho_model` で直接起動される。Karo は Taisho が
  spawn する worker の一種であり、`taisho_model` は使わない）。

## 5. tmux セッション構成の変更（2 セッション→1 セッション）と pane 管理

agmsg の `spawn.sh` は tmux 経路（`$TMUX` が設定されている場合）で、
`launch_in_tmux()` が呼び出し元の**現在の window を `split-window`** するか、
**現在の session に `new-window`** する実装になっており、任意の tmux session を
target 指定するオプションを持たない。したがって Phase 1 では **1 セッション構成**
に変更する。

- `shogun start` は単一の tmux セッション（`shogun-<safe_name>-<hash>`）のみを
  作成し、Taisho を最初の window（`window 0`）として起動する。
- **配置方針**: Karo は Taisho とは別 window（`agmsg spawn ... --window` 相当）に
  window として追加する。Gunshi/Metsuke/Ashigaru は Karo の window 内に pane として
  追加する（`agmsg spawn` のデフォルトの split 動作をそのまま使う）。
- **pane メタデータの引き継ぎ**: agmsg は生成した window/pane に対して window 名や
  pane title のみを設定し、Shogun 固有のメタデータ
  （`@shogun_role`/`@shogun_color`/`@agent_id`、`_set_pane_role_label()`）は
  設定しない。spawn 成功後、Shogun 側（呼び出した Karo/Taisho 側の adapter 呼び出し）が
  agmsg の placement record から実際の `%pane_id`（または `@window_id` の場合は
  その window の root pane）を取得し、`_set_pane_role_label()` を呼んで
  役職ラベル・色を設定する。
- pane を追加した window では、追加のたびに `tmux select-layout tiled` を
  再適用する。

## 6. 通信層（agmsg）

- 1 Shogun プロジェクト = 1 agmsg チーム。エージェント名 = 役職名
  （`taisho`, `karo`, `gunshi`, `metsuke`, `ashigaru1..N`）とし、
  agmsg の `actas` は原則使わない（Taisho の readiness 成立を除く。§7 参照）。
- 配信モードは `monitor`（リアルタイム push）をデフォルトにする。
- **`shogun` という送信元 identity**: `send.sh` は `from`/`to` が共に
  team に登録済みであることを要求する。`shogun task "..."` の送信元として
  `shogun init` 時に `agmsg_join <team> shogun <type> <project>` で
  system identity として `shogun` を登録する（`<type>` は headless な
  最小 type を割り当て、実際に spawn/actas はしない）。
- `shogun task "..."` は `agmsg_send <team> shogun taisho "..."` に置き換える。
  既存の `shogun_to_karo.yaml` は廃止。
- Karo→Gunshi/Metsuke/Ashigaru へのタスク割り当て・報告も全て agmsg の send/history で
  やり取りする。`.shogun/queue/tasks/*.yaml`・`reports/*.yaml`・`reviews/*.yaml` は廃止。
- **dashboard.md の単一ライター契約**: `dashboard.md` は **Taisho のみ**が更新する
  （既存の `templates/instructions/taisho.md` の運用を踏襲）。Karo は
  `task_id → status` の正本データを **Karo 専用の run-scoped 状態ファイル**
  （dashboard.md ではない）に保持し、進捗を agmsg メッセージで Taisho へ報告する。
  Taisho がそれを受けて dashboard.md に反映する。Karo が dashboard.md を
  直接編集することはない。
- `templates/CLAUDE.md` / `templates/instructions/karo.md` など、
  YAML キュー/MCP を前提にした既存のエージェント指示文書は、agmsg の
  send/inbox/history 前提の記述に書き換える（実装計画のタスクとして明記する）。

## 7. Taisho の join・readiness・exclusive watcher 成立

agmsg の ready sentinel は、`ACTIVE_NAME` を持つ **exclusive watcher**
（= `actas` 経由で役割を確立したセッション）にしか作られない。通常の
broad watcher（team に join しただけの状態）には ready sentinel がない。
Taisho は Shogun が直接 `claude` を起動するため、agmsg の `spawn` 経由の
boot prompt（`/<cmd> actas <name>` を自動実行する仕組み）を通らない。

`shogun start` は以下の手順で Taisho の readiness を成立させ、
**この完了を確認してから成功を返す**（`shogun task` はそれまで拒否する）。

1. Taisho 用の古い ready sentinel（前回実行の残骸）を起動前に削除する。
2. `agmsg_join <team> taisho <type> <project>` を実行する。
3. `agmsg_set_delivery set monitor <type> <project>` で配信モードを設定する
   （§3 の固定シグネチャ `set <mode> <type> <project>` に従う。`team` 引数はない）。
4. Taisho の `claude` 起動時、初期プロンプトとして
   `/<cmd> actas taisho` を実行させる（Taisho 用の boot prompt に含める）。
   これにより Taisho のセッションが exclusive watcher として確立される。
5. 起動後、ready sentinel の存在をポーリングで確認する（タイムアウト付き）。
   確認時は以下を照合する。
   - sentinel 内の `session_id` が今回起動した Taisho の Claude Code
     セッション ID と一致すること。
   - sentinel が指す watcher の PID が実際に生存していること。
6. 5 が確認できて初めて `shogun start` は成功を返す。確認できない場合は
   エラーを返し、tmux セッションを残したまま診断情報を表示する
   （`shogun doctor` 相当の情報）。

## 8. spawn/despawn 運用と resume/`--fresh` の使い分け

- モデル選択は agmsg のネイティブ `--model` オプションで直接指定する
  （`agmsg_spawn claude-code <role> --model "$worker_model"`）。
  Taisho 以外の全ロール（Karo 含む）は `worker_model` を使う。
- `spawn_options.yaml` は agent **type** 単位でしか分岐できないため、role 別設定は
  このファイルに持たせない。role 固有の設定は Shogun 側の spawn 呼び出しが持つ。

### resume と `--fresh` の使い分け（run_id 状態管理）

agmsg は `spawn` 時、`agmsg_role_resume_uuid()` が
「`--fresh` が指定されておらず」「type に `resume_arg` があり」
「`(team, agent)` の role-session record があり」「transcript が存在する」の
すべてを満たす場合に、role の以前のセッションを resume する。

`shogun start` ごとに新しい `run_id`（UUID）を発行し、Shogun 側の
run-scoped 状態ファイル（Karo が保持する run state。§6 参照）に
**role ごとの「この run で fresh spawn が成立済みか」フラグ**を記録する。

- **成立の判定基準**: 単に spawn コマンドを発行した時点ではなく、
  `agmsg spawn` が `status=ready` を返し、かつ当該 role の role-session record
  がこの run の session_id に更新されたことを確認した時点で「成立」とする。
- **新しい run の最初の spawn**（フラグが未成立）:
  明示的に `--fresh` を付与する。
- **spawn がタイムアウト・失敗した場合**: フラグは「未成立」のまま維持する
  （次の spawn 試行でも引き続き `--fresh` を使う。誤って前 run の
  session を resume させない）。
- **フラグが成立済みの状態での再 spawn**（同一 run 内の無応答復旧など）:
  `--fresh` を付けず、agmsg のデフォルト resume を許可する。
- `shogun start` 実行時、前回の run state ファイルは破棄し、新しい `run_id` で
  作り直す。

## 9. 無応答ワーカーの復旧

**復旧の主体は階層で分ける**: Karo/Gunshi/Metsuke/Ashigaru の無応答は
Karo が検知・復旧する。**Karo 自身の無応答は Taisho が検知・復旧する**
（Karo は自分自身を復旧できない）。

以下のステートマシンで統一する（3 段階エスカレーションは廃止）。

1. 無応答検知（一定時間 inbox 未読が変化しない、または pane 出力が停滞）。
2. **force 前の事前検証**:
   - agmsg の placement record から対象ロールの `id` を取得する。
   - `id` が `^%[0-9]+$`（pane）または `^@[0-9]+$`（window）の形式であることを
     検証する。形式が不正、または record 自体が存在しない場合は force しない
     （即座に「孤児」扱いとし、人間の介入を促す）。
   - `tmux display-message -t "$id" -p '#{session_name}'` で取得した
     session が、期待する Shogun の tmux セッションと一致することを確認する
     （他プロジェクトの同名ロールとの誤認を防ぐ）。
3. `agmsg_despawn <team> <from> <role> --force` を実行する
   （`despawn.sh` の force 分岐は tmux 削除失敗を `|| true` で握り潰し、
   常に `status=forced`・exit 0 を返すため、戻り値は信用しない）。
4. **force 後の事後検証**: `tmux list-panes -a -F '#{pane_id}'` および
   `tmux list-windows -a -F '#{window_id}'`（**tmux server 全体**、対象
   セッション内だけではない）を取得し、手順 2 で保存した `id` が
   どこにも存在しないことを確認する。
   - 存在しない → 消失確認済み。手順 5 へ進む。
   - どこかに存在する → 消失していない。respawn せず「孤児ペイン」として
     dashboard に表示し、人間の介入を促す。
5. 消失確認できた場合のみ、同一 `run_id` 内の再 spawn として
   `agmsg_spawn claude-code <role> --model "$worker_model"`（`--fresh` なし、
   §8 のフラグに従う）を実行する。
6. 手順 1〜5 は、当該役職の復旧主体（Karo または Taisho）の単一直列処理に
   限定し、並行実行しない。

## 10. タスク完了プロトコル

agmsg は配送 ACK 付きキューではない。mcp-queue を廃止する代わりに、
以下のプロトコルを Shogun 側に導入する。**永続 task journal・retry/lease/fencing
は Phase 1 のスコープ外**だが、**同一実行中（同一 `run_id`）の assign 側・result
側 双方向の retry・受領 ACK・重複排除は必須**とする。

### メッセージ envelope

```json
{
  "protocol_version": 1,
  "run_id": "<shogun start ごとの UUID>",
  "task_id": "<UUID、run を跨いで再利用しない>",
  "type": "assign | accepted | started | result | ack | reject | failed | status_query",
  "from": "karo",
  "to": "ashigaru1",
  "attempt": 1,
  "payload": { "...": "..." }
}
```

### 状態遷移

```
pending → assigned → accepted → in_progress → done → acked
                  ↘ reject                  ↘ failed / timeout
```

### assign 側の信頼性（Karo → worker）

- `assign` 送信後、Karo は一定時間内に `accepted` を受け取れなければ、
  同じ `task_id`・インクリメントした `attempt` で再送する（リトライ上限あり）。
- worker は同じ `task_id` の重複 `assign` を再実行せず、現在の状態または
  既存の `result` をそのまま返す。

### result 側の信頼性（worker → Karo）— 新設

- `accepted` 後、Karo は **result deadline**（役職・タスク種別ごとに設定可能な
  タイムアウト）を設定する。deadline 超過時、Karo は同じ `task_id` で
  `status_query`（envelope の正式な `type` の一つ）を送る。
- worker は `status_query` を受信したら、その時点の状態
  （`in_progress`/`done`/`failed`）、および `done` であれば既存の `result` を
  即座に返す（新しい `result` を生成し直さない）。
- **worker は `result` を送信後、Karo からの `ack` を受け取るまで
  `result` を定期的に再送する**（一定間隔、上限回数）。
- **worker は `ack` を確認するまで despawn しない**
  （despawn は §9 のプロトコルとは独立して、「完了報告が ACK された後」
  という完了条件が前提になる）。
- Karo は重複 `result`（同じ `task_id`）の受信を冪等に処理する
  （既に `acked` 済みの `task_id` であれば、検証をやり直さず同じ `ack` を
  再送するだけでよい）。
- `reject`/`failed`/timeout の状態は Taisho への報告経由で dashboard に表示し、
  人間判断を仰ぐ。

## 11. hook 移行・`inject_role.sh` リファクタ・終了時 cleanup

- `templates/.claude/settings.json` から `stop_hook.sh`/`mark_busy.sh` の
  フック登録を削除する。既存プロジェクトの `.claude/settings.json` に対しては、
  `shogun upgrade` 時に該当エントリを除去するマイグレーション処理を追加する
  （現行の `_merge_claude_settings()` は追加・保持のみで削除しないため、
  削除専用の処理を別途実装する）。
- `scripts/inject_role.sh` は、現在含まれる idle flag・mcp-queue 未読確認ロジックを
  削除し、役職アイデンティティ注入のみを残すようリファクタする。
- `shogun stop` の終了処理として、以下を明示的に行う。
  - Taisho の exclusive actas lock の解放。
  - Taisho・稼働中 worker の ready sentinel / watcher PID ファイルの消失確認。
  - 稼働中だった worker の placement record の残存有無を確認し、
    残っていれば dashboard 等でユーザーに警告する。
  - team registration は run を跨いで維持する（`shogun reset` の場合のみ、
    team 自体を作り直すか検討する）。

## 12. 設定・CLI の変更点

- `.shogun/config.yaml`: `agents.ashigaru_count` / `agents.worker_model` /
  `agents.taisho_model` は維持。`escalation_policy`（3段階）は
  `unresponsive_timeout_sec` のような単一項目に置き換える。
  `agmsg.cmd_name`（agmsg のインストールコマンド名）を新設する。
- `shogun start` / `shogun stop` / `shogun attach` / `shogun task` / `shogun status` /
  `shogun view` の内部実装を agmsg 呼び出し（§3 のアダプタ経由）に置き換える。
  `shogun attach multi` は 1 セッション構成への変更に伴い廃止する（§5）。
- `shogun doctor` に agmsg の存在確認・対応バージョン（commit
  `1c7efbc005c...`/`v1.1.12` 系）の確認を追加する（§3 参照）。

## 13. 廃止対象ファイル

- `scripts/inbox_write.sh` / `scripts/inbox_watcher.sh` / `scripts/mcp_manager.sh`
- `scripts/mark_busy.sh` / `scripts/stop_hook.sh` / `scripts/flag_names.sh`
  （busy/idle フラグ管理は agmsg の配信モードに置き換わるため不要になる）
- `packages/mcp-queue/` パッケージ全体
- `.shogun/queue/` 配下（tasks/reports/reviews/inbox/*.yaml、shogun_to_karo.yaml）

`scripts/inject_role.sh` は**残す**（§11 の通りリファクタする）。

## 14. テスト方針

- `scripts/agmsg_adapter.sh` が呼び出す agmsg の個別スクリプト
  （`send.sh`/`spawn.sh`/`despawn.sh`/`inbox.sh`/`history.sh`/`join.sh`/`delivery.sh`）は
  `tests/unit/` で fake 実装に差し替えてモックする（§3 のシグネチャ通りに
  引数を検証する）。
- タスク完了プロトコル（envelope のパース、状態遷移、assign/result 双方向の
  retry・重複排除ロジック）は `tests/unit/` で純粋関数としてテストする。
- 無応答復旧のステートマシン（ID 事前検証→force→server 全体での消失確認→
  respawn）は fake tmux コマンドを使って `tests/unit/` でテストする。
- Taisho readiness（ready sentinel 生成・session_id/PID 照合）は
  fake agmsg スクリプトを使って `tests/unit/` でテストする。
- `shogun start`/`stop`/`task` の統合フロー（1 セッション構成、readiness 確認込み）は
  `tests/integration/` で、fake agmsg スクリプト群・fake `claude`/`tmux` を使って検証する。

## 15. スコープ外（Phase 2 として将来検討）

herdr 統合によるセッション永続化は本設計のスコープ外とする。Phase 2 着手時は
以下を仕様に含める必要がある（Codex による複数ラウンドのレビューで判明した論点）。

- **resume 所有権の一本化**: herdr のネイティブ agent auto-resume
  （`resume_agents_on_restore`）を無効化するか、herdr 復元完了を待つ明示的な
  barrier を設けるかを選ぶ。ただし無効化しても「cold restart 後に復元される
  空ペイン」と「agmsg が新規作成するペイン」が二重配置される問題が残るため、
  `herdr agent start --pane <restored-pane-id>` のような、既存ペインを再利用する
  spawn 契約が別途必要。
- **永続 task journal の再設計**: 単一の `tasks` テーブルではなく、
  `tasks`（現在状態）/ `task_events`（追記専用履歴）/ `outbox`
  （agmsg への未送信通知）/ `leases`（fencing token 付き貸出期限）に分割する。
- **force despawn の事前/事後記録**: herdr 環境でも同様に、削除前にペイン ID を
  保存し、削除後に herdr の pane inventory で消失を再確認してから状態を確定する
  仕組みが必要（本設計の §9 の考え方を herdr 環境へ拡張する）。
- **restart 種別の機械的な切り分け**: detach/reattach・Shogun CLI 再起動・
  herdr server cold restart・OS 再起動・live handoff をそれぞれ区別し、
  server epoch・pane inventory・watcher の生存確認などから機械的に判定する。
- **Taisho readiness の検証強化**: §7 の考え方を herdr 環境にも拡張し、
  stale sentinel の誤認防止、herdr 側での agent 入力可能状態の確認を追加する。

## 16. 計画2（tmux 1セッション統合・通信層配線）の詳細設計

`shogun spawn`/`shogun task`実装（issue #128）にあたり、§5・§6・§8の記述を以下の通り具体化する。

### spawn は誰が判断するか

Karo/Gunshi/Metsuke/Ashigaru を起こすかどうかの判断は Taisho/Karo 自身（LLM
エージェント）が行う。`bin/shogun` は `shogun start` 時に Taisho だけを
決定的に起動し、それ以降の spawn 判断には関与しない。エージェントが
spawn を実行するための決定的な処理（モデル選択・`--fresh` 判定・
pane label付け）は `shogun spawn <role>` という内部サブコマンドに集約し、
エージェントの指示書（`templates/instructions/*.md`）はこのラッパーを
呼ぶよう案内する（agmsg の生コマンドを直接叩かせない）。

### `shogun spawn <role>` サブコマンド

```
shogun spawn <role> [--boot-prompt TEXT]
```

内部処理:

1. `role` を `^[A-Za-z0-9_-]+$` で検証する。
2. `.shogun/config.yaml` の `agents.worker_model` を解決する。
3. run_id 状態（後述）を読み、当該 role の fresh フラグが未成立なら
   `--fresh` を付与する。
4. `role` が `karo` なら `--window`、それ以外（gunshi/metsuke/ashigaru*）は
   フラグなし（デフォルトの split 挙動、Karo の window 内に pane 追加）で
   `agmsg_spawn "$agmsg_cmd_name" claude-code "$role" --model "$worker_model" [--fresh] [--window] [--boot-prompt TEXT]`
   を呼ぶ。
5. 成功後、`agmsg_get_placement` で placement record を取得し、
   `_set_pane_role_label()` でペインラベルを設定する
   （`@N` 形式の window ID の場合は、その window の先頭 pane に適用する）。
6. run_id 状態ファイルの当該 role のフラグを「成立」に更新する。
7. 失敗時は agmsg のエラーをそのまま呼び出し元（エージェント）に見える形で返す。

### run_id 状態管理

- `.shogun/state/run_id`: `shogun start` 実行のたびに新しい UUID を書き込む
  （既存ファイルは上書き）。
- `.shogun/state/fresh_done/<role>`: 当該 run でその role の fresh spawn が
  成立したことを示す空マーカーファイル。`shogun start` は起動時に
  `.shogun/state/fresh_done/` ディレクトリを空にしてから新しい `run_id` を書く。
- `.shogun/state/` は `.gitignore` に追加する（プロジェクトごとのローカル状態）。

### `shogun` system identity と team 命名

- team 名は `project_session_names()` と同じ命名規則
  （`project_safe_name(project_name)` + `project_root_hash(SHOGUN_ROOT)`）を
  流用し、`<safe_name>-<hash>` とする（他プロジェクトとの衝突防止）。
- `shogun init` 時に `agmsg_join <team> shogun <type> <project>` で
  `shogun` を system identity として登録する。`<type>` の値は実装時に
  agmsg の `join.sh`/type manifest の実際の検証有無を確認してから決定する
  （固定の type 名が必須かどうか未確認のため、実装タスクで検証する）。

### Taisho の最小 join（このplanのスコープ）

`shogun start` は Taisho 起動前に、以下の**最小限**の処理を行う
（sentinel ポーリング・session_id 照合等の堅牢化は行わない。これは
issue #129 のスコープ）。

1. `agmsg_join <team> taisho <type> <project>`
2. `agmsg_set_delivery set monitor <type> <project>`

これにより `shogun task` → `agmsg_send <team> shogun taisho "..."` が
機能する状態になる。

### dashboard.md

技術的な権限強制は行わない。`templates/instructions/karo.md` に
「dashboard.md は直接編集せず、Taisho へ agmsg で報告すること」を明記する
運用規約のみとする。

### このplanのスコープ外

- Karo → 配下への実際のタスク割り当て・報告メッセージのやり取り
  （envelope プロトコル自体は計画4、issue #130）
- 無応答復旧時の `shogun spawn` の再利用（計画5、issue #131）
- Taisho readiness の堅牢化（sentinel/session_id 照合、計画3、issue #129）
