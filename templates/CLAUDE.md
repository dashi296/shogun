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
- タスク: `.shogun/queue/tasks/{自分の役職}.yaml` を読む
- 報告: `.shogun/queue/reports/{自分の役職}_report.yaml` に書き込む
