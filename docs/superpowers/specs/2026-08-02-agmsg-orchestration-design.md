# agmsg 通信基盤への移行設計 — オンデマンド spawn/despawn オーケストレーション

- 日付: 2026-08-02
- ステータス: 設計承認済み（実装計画は未作成）
- 対象: Shogun フレームワークのエージェント間通信・起動管理の再設計
- **関係**: [`2026-07-17-ichiryo-ichinin-architecture-design.md`](2026-07-17-ichiryo-ichinin-architecture-design.md) を置き換える。
  同ドキュメントは本設計の採用に伴い**廃止（superseded）**とする。

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

Phase 1（本設計）では **tmux は現状のまま維持**し、agmsg の標準経路（tmux スポーン）
を使うことで、この複雑性を切り離す。

## 2. 設計方針

1. **通信は全面 agmsg 化**: `.shogun/queue/*.yaml`・`scripts/inbox_watcher.sh`・
   `packages/mcp-queue` を廃止し、agmsg の send/inbox/history/spawn/despawn に置換する。
2. **階層構造は維持しつつオンデマンド spawn で実現**: 固定役職名
   （karo/gunshi/metsuke/ashigaru1..N）の思想は残すが、常駐させるのは **Taisho のみ**
   （人間の窓口）。Karo 以下はタスクがある時だけ `agmsg spawn` で起動し、
   完了したら `agmsg despawn` で畳む。
3. **tmux は変更しない**: セッション永続化（herdr 統合）は Phase 2 に切り出す。
4. **Agent Self-Watch の 3 段階エスカレーションは廃止**し、単純な
   despawn（force）→ペイン消失確認→respawn に統一する。
5. **タスク完了は task_id ベースの軽量プロトコル**で扱う。ただし
   **再起動をまたぐ永続性は今回のスコープ外**とする（現状の `shogun stop`/`reset` 同様、
   プロセスが落ちたら `shogun start` からやり直す前提を変えない）。

## 3. 全体アーキテクチャ

```
あなた
  │ shogun start
  ▼
tmux セッション起動（現状どおり）
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
- ペインの実体は現状どおり tmux 上に生成される（agmsg のデフォルト tmux 経路）。

## 4. 通信層（agmsg）

- 1 Shogun プロジェクト = 1 agmsg チーム。エージェント名 = 役職名
  （`taisho`, `karo`, `gunshi`, `metsuke`, `ashigaru1..N`）とし、
  agmsg の `actas` は原則使わない（役職固定のため不要）。
- 配信モードは `monitor`（リアルタイム push）をデフォルトにする。
  これは agmsg の SessionStart hook + Monitor ツールで実現され、
  現在の `inbox_watcher.sh` による fswatch wake-up の代替になる。
- `shogun task "..."` は agmsg の `send` に置き換える（Taisho への直接メッセージ送信）。
  既存の `shogun_to_karo.yaml` コマンドキューは廃止。
- Karo→Gunshi/Metsuke/Ashigaru へのタスク割り当て・報告も全て agmsg の send/history で
  やり取りする。`.shogun/queue/tasks/*.yaml`・`reports/*.yaml`・`reviews/*.yaml` は廃止。
- `dashboard.md`（進捗ボード）は残し、Karo が agmsg メッセージの内容を元に更新する
  運用にする（人間が一目で見る用の集約ビューとして）。

## 5. spawn/despawn 運用

- モデル選択は agmsg のネイティブ `--model` オプションで直接指定する
  （`agmsg spawn claude-code <role> --model "$worker_model"`）。
  agmsg の type manifest（`scripts/drivers/types/claude-code/type.conf` の
  `model_arg=--model`）がそのまま渡すため、独自ラッパーは不要。
  Taisho は `shogun start` 側で `taisho_model` を使って直接起動する。
- `spawn_options.yaml`（`~/.agmsg/config/spawn_options.yaml`）は agent **type** 単位
  （claude-code, codex 等）でしか分岐できないため、role 別設定はこのファイルに
  持たせない。role 固有の設定は Shogun 側の spawn 呼び出し（`--model` の値）が持つ。

## 6. 無応答ワーカーの復旧（簡素化）

3 段階エスカレーション（phase1_nudge/phase2_interrupt/phase3_clear）は廃止し、
以下のシンプルなステートマシンに統一する。

1. 無応答検知（一定時間 inbox 未読が変化しない、または pane 出力が停滞）
2. `agmsg despawn <role> --force`
3. `tmux list-panes` 等でペインの物理的消失を確認する
   （`despawn --force` は tmux/herdr の削除失敗を `|| true` で握り潰すため、
   戻り値だけを信用しない）
4. 消失確認できた場合のみ `agmsg spawn claude-code <role> --model ...` で再 spawn
   （agmsg の role-session レコードにより、直前の会話文脈は自動的に継続を試みる。
   ただしこれは advisory/best-effort であり、保証ではない点を運用上許容する）
5. タイムアウトしても消失確認できない場合は respawn せず、dashboard に
   「孤児ペイン」として表示し、人間の介入を促す

## 7. タスク完了プロトコル（軽量版）

agmsg は配送 ACK 付きキューではない（`mark_read` は best effort であり、
下流 Monitor が実際に処理した保証にはならない）。mcp-queue を廃止する代わりに、
以下の軽量プロトコルを Shogun 側に導入する。

- 各タスクに安定した `task_id` を付与する。
- メッセージ種別を `assign` / `result` / `ack` の 3 種に限定する。
- Karo は `task_id → status` を自分の実行中だけ追跡する
  （dashboard.md、または Karo 専用の簡易な状態ファイルに記録。
  複数プロセスからの同時書き込みがないため、SQLite やロック機構は不要）。
- Ashigaru からの `result` メッセージを Karo が検証し `ack` を返した時点で
  初めて完了・despawn 対象とする。herdr の `agent.wait(done)` のような
  セマンティック状態や、agmsg の既読化だけでは完了とみなさない。
- **再起動をまたぐ永続性・冪等性・retry/lease は今回のスコープ外**とする
  （Phase 2 で herdr 統合とあわせて再検討する）。

## 8. 設定・CLI の変更点

- `.shogun/config.yaml`: `agents.ashigaru_count` / `agents.worker_model` /
  `agents.taisho_model` は維持。`escalation_policy`（3段階）は
  `unresponsive_timeout_sec` のような単一項目に置き換える。
- `shogun start` / `shogun stop` / `shogun attach` / `shogun task` / `shogun status` /
  `shogun view` の内部実装を agmsg 呼び出しに置き換える
  （コマンド体系・UX は維持。tmux セッション管理自体は変更しない）。
- `shogun doctor` に `agmsg` の存在確認を追加する
  （現状の `fswatch`/`inotifywait` チェックに追加する形）。

## 9. 廃止対象ファイル

- `scripts/inbox_write.sh` / `scripts/inbox_watcher.sh` / `scripts/mcp_manager.sh`
- `scripts/mark_busy.sh` / `scripts/stop_hook.sh` / `scripts/flag_names.sh`
  （busy/idle フラグ管理は agmsg の配信モードに置き換わるため不要になる）
- `packages/mcp-queue/` パッケージ全体
- `.shogun/queue/` 配下（tasks/reports/reviews/inbox/*.yaml、shogun_to_karo.yaml）

`scripts/inject_role.sh` は**残す**（役職アイデンティティ注入は引き続き必要、
agmsg の actas とは別レイヤー）。

## 10. テスト方針

- `agmsg spawn`/`despawn` 呼び出しは `tests/unit/` でモック（fake `agmsg` バイナリを
  PATH に差し替える、既存の `test_helper.bash` の手法を踏襲）。
- タスク完了プロトコル（task_id → assign/result/ack の状態遷移）は
  `tests/unit/` で純粋関数としてテストする。
- `shogun start`/`stop`/`task` の統合フローは `tests/integration/` で、
  fake `agmsg`/`claude` バイナリを使って検証する。

## 11. スコープ外（Phase 2 として将来検討）

herdr 統合によるセッション永続化は本設計のスコープ外とする。Phase 2 着手時は
以下を仕様に含める必要がある（Codex による 3 ラウンドのレビューで判明した論点）。

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
- **force despawn の事前/事後記録**: `despawn --force` は herdr/tmux の削除失敗を
  握り潰すため、Shogun 側で `spawning|active|terminating|orphaned|despawned` の
  状態遷移を独立して持ち、削除前にペイン ID を保存し、削除後に herdr の
  pane inventory で消失を再確認してから状態を確定する。
- **restart 種別の機械的な切り分け**: detach/reattach・Shogun CLI 再起動・
  herdr server cold restart・OS 再起動・live handoff をそれぞれ区別し、
  server epoch・pane inventory・watcher の生存確認などから機械的に判定する
  （呼び出し理由の申告を信用しない）。
- **Taisho readiness の検証強化**: agmsg の exclusive watcher + ready sentinel は
  常駐固定ロールにも技術的に転用できるが、stale sentinel の誤認、
  sentinel 所有者・watcher PID の生存確認、herdr 側での agent 入力可能状態の確認を
  追加する必要がある。
