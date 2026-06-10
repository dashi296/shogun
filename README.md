# Shogun
AIオーケストレーションフレームワーク

Version: 0.3

## 概要

Shogun は Claude Code、Codex、Gemini CLI などのAIエージェントを統率し、
一人開発会社を実現するためのローカルオーケストレーションフレームワークである。

## 組織構造

Shogun (User)
→ Taisho
→ Karo
  ├ Gunshi
  ├ Metsuke
  └ Ashigaru x N

## 役職

### Shogun
- 要求を出す
- 最終判断を行う

### Taisho
- 組織全体の責任者
- Shogunとの対話
- Karoへの指示

### Karo
- PM
- タスク分解
- Agent割り当て
- 進捗管理

### Gunshi
- CTO / Architect
- 技術選定
- 設計レビュー
- リスク分析

### Metsuke
- Reviewer / QA
- コードレビュー
- 品質保証

### Ashigaru
- Worker
- 実装
- テスト
- 調査

## ディレクトリ構成

.shogun/
├── config.yaml
├── state.db
├── memory.db
├── prompts/
├── artifacts/
└── logs/

## CLI

shogun init
shogun task "..."
shogun start
shogun status
shogun logs
shogun doctor

## Database

### state.db
- tasks
- messages
- agents
- runs

### memory.db
- lessons
- decisions
- knowledge

## Message Bus

SQLiteを利用する。

Agentは1秒程度のポーリングで未処理メッセージを取得する。

## MVP

- init
- task
- start
- status
- doctor
- SQLite Message Bus
- Memory
- Logging

## 将来拡張

- recruit
- council
- inspect
- nightly
- GitHub連携
- Dashboard

## ゴール

shogun task で投入されたタスクを
Karo が分解し、
Gunshi が設計支援し、
Ashigaru が実装し、
Metsuke がレビューし、
Shogun が Daimyo に報告する。
