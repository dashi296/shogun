# Shogun システム共通設定

## セッション開始時に必ず行うこと

1. `.shogun/instructions/{あなたの役職}.md` を読む
2. `.shogun/memory/MEMORY.md` を読む（存在する場合）
3. `.shogun/config.yaml` で現在の設定を確認

## 全エージェント共通の禁止事項

- ポーリングループ（`while true; do sleep 1; done` 等）の実行
- User への直接報告（必ず階層を通す）
- 担当外のファイルへの書き込み

## 通信プロトコル

- 受信: `.shogun/queue/inbox/{自分の役職}.yaml` を読む
- 送信: `bash $SHOGUN_BIN_DIR/scripts/inbox_write.sh {相手} "{subject}" "{body}"` を実行
  （`$SHOGUN_BIN_DIR` は `shogun start` によって自動設定される。通常 `~/.local/share/shogun`）
- タスク: `.shogun/queue/tasks/{自分の役職}.yaml` を読む
- 報告: `.shogun/queue/reports/{自分の役職}_report.yaml` に書き込む

## コンテキスト管理（/clear）

YAML キューファイル（inbox / tasks / reports）が状態の正（authoritative source of truth）である。
`/clear` で会話履歴を消してもこれらはファイルシステムに残るため、読み直せば現在地を復元できる。
MEMORY.md は長期記憶（ユーザーの好み・過去の決定）専用とし、セッション状態は書かない。

### /clear するタイミング
ひとつの要求・タスクグループへの対応が完了し、次の wake-up を待つ状態になったとき。

### /clear 後の復元手順
1. CLAUDE.md が自動再読み込みされる
2. `.shogun/instructions/{自分の役職}.md` を読む
3. `.shogun/memory/MEMORY.md` を読む（存在する場合）
4. YAML ファイルで現在の状態を確認し、中断した作業があれば再開する
   （具体的な確認手順は各役職の instructions を参照）
