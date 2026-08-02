# agmsg 通信基盤への移行設計 — オンデマンド spawn/despawn オーケストレーション

- 日付: 2026-08-02（改訂: Codex レビュー4回目の指摘を反映）
- ステータス: 設計承認済み（実装計画は未作成）
- 対象: Shogun フレームワークのエージェント間通信・起動管理の再設計
- **関係**: [`2026-07-17-ichiryo-ichinin-architecture-design.md`](2026-07-17-ichiryo-ichinin-architecture-design.md) を置き換える。
  同ドキュメントは本設計の採用に伴い**廃止（superseded）**とする。
- **対応 agmsg バージョン**: `fujibee/agmsg` commit `1c7efbc`（`main`、2026-08-01 時点、
  `VERSION=1.1.12`）に固定する。それ以降の `main` の変更（role resume の挙動変更、
  tmux-resurrect 連携、herdr spawn 対応など）は追従前に個別に再検証すること。

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
Codex による技術レビューを 3 ラウンド実施した結果、herdr 統合は以下の理由で
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
   セッション永続化（herdr 統合）は Phase 2 に切り出す。
4. **Agent Self-Watch の 3 段階エスカレーションは廃止**し、単純な
   despawn（force、pane/window ID を事前保存）→消失確認→respawn に統一する。
5. **タスク完了は task_id ベースの軽量プロトコル**で扱う。再起動をまたぐ永続性は
   スコープ外とするが、**同一実行中（同一 `run_id`）の retry・受領 ACK・重複排除は
   必須スコープに含める**（永続化なしでも「タスクが永久に停滞する」ことは許容しない）。

## 3. agmsg の呼び出し方式（実装アダプタ）

agmsg は単一のシェル CLI コマンドではない。npm/インストーラーの `agmsg` 実行ファイルは
セットアップ処理のみを行い、実際のランタイム API は
`~/.agents/skills/<cmd>/scripts/*.sh`（`send.sh` / `spawn.sh` / `despawn.sh` /
`inbox.sh` / `history.sh` / `join.sh` / `delivery.sh` 等）を直接呼び出す形で提供される。

Shogun 側に `scripts/agmsg_adapter.sh` を新設し、以下を担当させる。

- agmsg のインストールディレクトリ（既定 `~/.agents/skills/<cmd>/`）を解決する。
- 各操作（send/spawn/despawn/inbox/history/join/delivery mode 設定）を、
  対応する `scripts/*.sh` に正しい引数で委譲する薄いラッパー関数を提供する。
- `bin/shogun` および各ロールの指示ファイルは、agmsg のスクリプトパスやコマンド形式を
  直接知らずに済むよう、このアダプタ経由でのみ agmsg を呼び出す。

テストでは、このアダプタが呼び出す `scripts/*.sh` を fake 実装に差し替える
（`agmsg` という単一 fake バイナリではなく、`send.sh`/`spawn.sh`/`despawn.sh` 等の
個別スクリプトをモックする）。

## 4. 全体アーキテクチャ

```
あなた
  │ shogun start
  ▼
tmux セッション起動（1 セッション構成、詳細は §5）
  │
  ▼
Taisho（tmux 常駐ペイン・人間の窓口）
  │ shogun task "..." → agmsg send taisho
  │
  │ 未起動なら agmsg spawn claude-code karo --model <taisho_model> --boot-prompt "<task>"
  ▼
Karo（オンデマンド、作業完了で despawn）
  │ 必要に応じて
  ├─ agmsg spawn claude-code gunshi --model <worker_model>   （設計相談が必要な時だけ）
  ├─ agmsg spawn claude-code metsuke --model <worker_model>  （レビューが必要な時だけ）
  └─ agmsg spawn claude-code ashigaru1..N --model <worker_model> （実装タスクがある時だけ）
```

- 常駐するのは Taisho のみ。Karo/Gunshi/Metsuke/Ashigaru はタスクがある時だけ
  `agmsg spawn` で起こし、報告完了後は `agmsg despawn` で畳む。

## 5. tmux セッション構成の変更（2 セッション→1 セッション）

agmsg の `spawn.sh` は tmux 経路（`$TMUX` が設定されている場合）で、
呼び出し元の**現在の window を `split-window`** するか、**現在の session に
`new-window`** する実装になっており、任意の tmux session を target 指定する
オプションを持たない。

現行 Shogun は `taisho-*`（Taisho 専用）と `multiagent-*`（Karo/Gunshi/Metsuke/
Ashigaru 用）の 2 セッション構成だが、この構成のまま Taisho が Karo を
`agmsg spawn` すると、Karo は `multiagent-*` ではなく **Taisho の現在の session**
に生成されてしまい、既存の `shogun attach multi` という UX と両立しない。

したがって Phase 1 では **1 セッション構成**に変更する。

- `shogun start` は単一の tmux セッション（`shogun-<safe_name>-<hash>` のような命名）
  のみを作成し、Taisho を最初のペインとして起動する。
- Karo/Gunshi/Metsuke/Ashigaru はタスク発生時に、このセッション内へ
  `agmsg spawn` で window/pane として追加される。
- `shogun attach` は単一セッションへの attach のみになる。`shogun attach multi` は
  廃止し、`shogun attach` のエイリアスとして警告付きで残すか、完全に削除するかは
  実装計画時にユーザーと確認する。
- `shogun stop` は単一セッションを `tmux kill-session` するだけでよくなる。

## 6. 通信層（agmsg）

- 1 Shogun プロジェクト = 1 agmsg チーム。エージェント名 = 役職名
  （`taisho`, `karo`, `gunshi`, `metsuke`, `ashigaru1..N`）とし、
  agmsg の `actas` は原則使わない（役職固定のため不要）。
- 配信モードは `monitor`（リアルタイム push）をデフォルトにする。
  これは agmsg の SessionStart hook + Monitor ツールで実現され、
  現在の `inbox_watcher.sh` による fswatch wake-up の代替になる。
- `shogun task "..."` は agmsg の `send`（アダプタ経由）に置き換える
  （Taisho への直接メッセージ送信）。既存の `shogun_to_karo.yaml` は廃止。
- Karo→Gunshi/Metsuke/Ashigaru へのタスク割り当て・報告も全て agmsg の send/history で
  やり取りする。`.shogun/queue/tasks/*.yaml`・`reports/*.yaml`・`reviews/*.yaml` は廃止。
- **`dashboard.md`（進捗ボード）は Taisho が更新する**（既存の
  `templates/instructions/taisho.md` の運用を踏襲。Karo に移管しない）。
  Karo は agmsg 経由で Taisho に進捗を報告し、Taisho がそれを dashboard.md に反映する。
- `shogun init`/`shogun start` は、Taisho の agmsg team join、
  `delivery.sh set monitor claude-code <project>` によるモード設定、
  既存 `.claude/settings.json`（`inject_role`/`stop_hook` 等）と agmsg が生成する
  `.claude/settings.local.json` の共存を担当する。両者のフック定義が競合しないよう、
  `shogun init` のマージ処理（`_merge_claude_settings`）を agmsg 側の設定にも対応させる。
- `templates/CLAUDE.md` / `templates/instructions/karo.md` など、
  YAML キュー/MCP を前提にした既存のエージェント指示文書は、agmsg の
  send/inbox/history 前提の記述に書き換える（実装計画のタスクとして明記する）。

## 7. spawn/despawn 運用

- モデル選択は agmsg のネイティブ `--model` オプションで直接指定する
  （`agmsg spawn claude-code <role> --model "$worker_model"`）。
  agmsg の type manifest（`scripts/drivers/types/claude-code/type.conf` の
  `model_arg=--model`）がそのまま渡すため、独自ラッパーは不要。
  Taisho は `shogun start` 側で `taisho_model` を使って直接起動する。
- `spawn_options.yaml`（`~/.agmsg/config/spawn_options.yaml`）は agent **type** 単位
  （claude-code, codex 等）でしか分岐できないため、role 別設定はこのファイルに
  持たせない。role 固有の設定は Shogun 側の spawn 呼び出し（`--model` の値）が持つ。

### resume と `--fresh` の使い分け

agmsg は `spawn` 時、role の以前の Claude Code セッションを**デフォルトで resume**
する（`type.conf` の `resume_arg=--resume`、`role-session.sh` が保存する
`(team, agent) → session UUID` の best-effort レコードに基づく）。これは
「プロセスが落ちたら `shogun start` からやり直す」という前提と素直には両立しない。

`shogun start` ごとに新しい `run_id`（UUID）を発行し、以下のルールで使い分ける。

- **新しい `run_id` の最初の spawn**（`shogun start` 直後の初回起動）:
  明示的に `--fresh` を付与し、前回実行の古い会話文脈を持ち込まない。
- **同一 `run_id` 内の再 spawn**（無応答復旧、または一時的な despawn/再 spawn）:
  `--fresh` を付けず、agmsg のデフォルト resume を許可する
  （直前の会話文脈が継続する方が望ましいため）。
- どちらの場合も、古い会話文脈の内容を現在の `task_id` の正としない
  （§8 の task journal 相当の状態が正であり、会話 resume はあくまで
  エージェントの作業体験を助けるものと位置づける）。

## 8. 無応答ワーカーの復旧

3 段階エスカレーション（phase1_nudge/phase2_interrupt/phase3_clear）は廃止し、
以下のステートマシンに統一する。

1. 無応答検知（一定時間 inbox 未読が変化しない、または pane 出力が停滞）
2. **force 前に、agmsg の placement record から対象ロールの正確な
   `%pane_id`（または `@window_id`）を取得して保存する**
   （agmsg の force despawn は成功可否に関わらず placement record を削除するため、
   force 実行後では確認対象の ID が失われる）。
3. 保存した ID が、期待する Shogun プロジェクト・tmux セッションに属することを
   検証する（他プロジェクトの同名ロールを誤認しないため）。
4. `agmsg despawn <role> --force` を実行する
   （`despawn.sh` の `kill_recorded_placement` は `tmux kill-pane`/`kill-window` の
   失敗を `|| true` で握り潰し、常に `status=forced` を返すため、戻り値は信用しない）。
5. `tmux list-panes -a -F '#{pane_id} #{session_name}'`（または `list-windows`）で、
   手順 2 で保存した正確な ID が（対象セッション内に）存在しないことを確認する。
6. ID が確認できない、または対象が別セッションだった場合は respawn しない
   （dashboard に「孤児ペイン」として表示し、人間の介入を促す）。
7. 消失確認できた場合のみ、同一 `run_id` 内の再 spawn として
   `agmsg spawn claude-code <role> --model ...`（`--fresh` なし）を実行する。
8. 手順 1〜7 は Karo の単一直列処理に限定し、並行実行しない。

## 9. タスク完了プロトコル

agmsg は配送 ACK 付きキューではない（`send.sh` が保証するのは SQLite INSERT の
成功までで、`watch.sh` の `mark_read` は Monitor の stdout へ書き込んだ直後に
best-effort で更新されるだけであり、下流が実際に処理した保証にはならない）。
mcp-queue を廃止する代わりに、以下のプロトコルを Shogun 側に導入する。

**永続 task journal・retry/lease/fencing は Phase 1 のスコープ外**（Phase 2 で
herdr 統合とあわせて再検討する）。ただし**同一実行中（同一 `run_id`）の
retry・受領 ACK・重複排除は必須**とする（これがないとタスクが永久に停滞しうる）。

### メッセージ envelope

機械可読な JSON envelope をメッセージ本文に含める。

```json
{
  "protocol_version": 1,
  "run_id": "<shogun start ごとの UUID>",
  "task_id": "<UUID、run を跨いで再利用しない>",
  "type": "assign | accepted | result | ack | reject | failed",
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

- `assign` 送信後、Karo は一定時間内に `accepted`（受領 ACK）を受け取れなければ、
  同じ `task_id`・インクリメントした `attempt` で再送する（上限リトライ回数を設ける）。
- worker は同じ `task_id` の重複 `assign` を再実行せず、現在の状態または
  既存の `result` をそのまま返す。
- Karo は重複 `result`（同じ `task_id`）を一度だけ検証し、
  同じ完了 `ack` を再送してよい（副作用を再実行しない）。
- `reject`/`failed`/timeout の状態は dashboard に表示し、人間判断を仰ぐ。
- Karo は `task_id → status` を自分の実行中だけ追跡する（dashboard.md、または
  Karo 専用の簡易な状態ファイルに記録。単一ライターのため SQLite やロック機構は不要）。

### Taisho の readiness/priming

- `shogun start` は、Taisho の agmsg team join・`delivery.sh set monitor` の設定
  完了後、Taisho の exclusive Monitor watcher が実際に購読を開始したこと
  （readiness sentinel の存在）を確認してから成功を返す（タイムアウト付きポーリング）。
- readiness 確認前に `shogun task` を受け付けない
  （agmsg の fresh watcher は起動時点の `MAX(id)` を watermark とするため、
  起動前に送られたメッセージは live delivery では拾われない）。

## 10. 設定・CLI の変更点

- `.shogun/config.yaml`: `agents.ashigaru_count` / `agents.worker_model` /
  `agents.taisho_model` は維持。`escalation_policy`（3段階）は
  `unresponsive_timeout_sec` のような単一項目に置き換える。
- `shogun start` / `shogun stop` / `shogun attach` / `shogun task` / `shogun status` /
  `shogun view` の内部実装を agmsg 呼び出し（§3 のアダプタ経由）に置き換える。
  `shogun attach multi` は 1 セッション構成への変更に伴い廃止する（§5）。
- `shogun doctor` に agmsg の存在確認・対応バージョン（commit `1c7efbc`/`1.1.12`系）の
  確認を追加する。

## 11. 廃止対象ファイル

- `scripts/inbox_write.sh` / `scripts/inbox_watcher.sh` / `scripts/mcp_manager.sh`
- `scripts/mark_busy.sh` / `scripts/stop_hook.sh` / `scripts/flag_names.sh`
  （busy/idle フラグ管理は agmsg の配信モードに置き換わるため不要になる）
- `packages/mcp-queue/` パッケージ全体
- `.shogun/queue/` 配下（tasks/reports/reviews/inbox/*.yaml、shogun_to_karo.yaml）

`scripts/inject_role.sh` は**残す**（役職アイデンティティ注入は引き続き必要、
agmsg の actas とは別レイヤー）。

## 12. テスト方針

- `scripts/agmsg_adapter.sh` が呼び出す agmsg の個別スクリプト
  （`send.sh`/`spawn.sh`/`despawn.sh`/`inbox.sh`/`history.sh`/`join.sh`/`delivery.sh`）は
  `tests/unit/` で fake 実装に差し替えてモックする（単一 fake `agmsg` バイナリではない）。
- タスク完了プロトコル（envelope のパース、状態遷移、retry/重複排除ロジック）は
  `tests/unit/` で純粋関数としてテストする。
- 無応答復旧のステートマシン（pane/window ID 保存→force→消失確認→respawn）は
  fake tmux コマンドを使って `tests/unit/` でテストする。
- `shogun start`/`stop`/`task` の統合フロー（1 セッション構成、readiness 確認込み）は
  `tests/integration/` で、fake agmsg スクリプト群・fake `claude`/`tmux` を使って検証する。

## 13. スコープ外（Phase 2 として将来検討）

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
  journal DB と agmsg の DB は別ファイルのため、dual-write 問題
  （クラッシュ境界での配送欠落・重複）に outbox パターンで対処する。
- **force despawn の事前/事後記録**: herdr 環境でも同様に、削除前にペイン ID を
  保存し、削除後に herdr の pane inventory で消失を再確認してから状態を確定する
  仕組みが必要（本設計の §8 の考え方を herdr 環境へ拡張する）。
- **restart 種別の機械的な切り分け**: detach/reattach・Shogun CLI 再起動・
  herdr server cold restart・OS 再起動・live handoff をそれぞれ区別し、
  server epoch・pane inventory・watcher の生存確認などから機械的に判定する
  （呼び出し理由の申告を信用しない）。
- **Taisho readiness の検証強化**: agmsg の exclusive watcher + ready sentinel は
  常駐固定ロールにも技術的に転用できるが、stale sentinel の誤認、
  sentinel 所有者・watcher PID の生存確認、herdr 側での agent 入力可能状態の確認を
  追加する必要がある。
