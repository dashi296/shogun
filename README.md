# Shogun

> 一人開発会社を実現するローカルAIオーケストレーションフレームワーク

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform: macOS/Linux](https://img.shields.io/badge/platform-macOS%20%2F%20Linux-blue)

## インストール

```bash
curl -fsSL https://raw.githubusercontent.com/dashi296/shogun/main/install.sh | bash
source ~/.zshrc  # または ~/.bashrc
```

## Quick Start

```bash
cd ~/projects/my-app   # 既存プロジェクトのディレクトリへ
shogun init            # .shogun/ を作成
shogun start           # tmux セッション起動・エージェント出陣
shogun task "認証機能を実装してください"
```

## 概要

Shogun は Claude Code などのAIエージェントを**武家社会の階層構造**で統率する
ローカルオーケストレーションフレームワークです。

- 複数プロジェクトを同時に管理（`.shogun/` はプロジェクト毎に独立）
- `shogun init` したプロジェクトならどこでも `shogun task` が使える
- エージェントがポーリングなしでメッセージを受信（fswatch/inotifywait）

## アーキテクチャ

```
あなた（Shogun）
  │  shogun task "..."
  ▼
Taisho（大将）── 組織全体の責任者
  │
  ▼
Karo（家老）── PM、タスク分解・割り当て
  ├── Gunshi（軍師）── CTO、設計・リスク分析
  ├── Metsuke（目付）── QA、コードレビュー
  └── Ashigaru × N（足軽）── Worker、実装・テスト
```

通信はすべて `.shogun/queue/` 配下の **YAMLファイル** で行われます。
`fswatch`（macOS）/ `inotifywait`（Linux）がファイル変更を検知して
エージェントを wake-up するため、ポーリングは不要です。

## 複数プロジェクトの並列運用

```bash
cd ~/projects/project-a
shogun start   # tmux: shogun-project-a, multiagent-project-a

cd ~/projects/project-b
shogun start   # tmux: shogun-project-b, multiagent-project-b（同時稼働可）
```

## CLI リファレンス

```bash
shogun init                   # 現在のディレクトリを初期化（.shogun/ 作成）
shogun task "説明"            # タスク投入
shogun task "説明" --priority high
shogun start                  # エージェント起動
shogun start --clean          # キューをリセットして起動
shogun start --count 5        # Ashigaru を5人で起動
shogun status                 # 現在の戦況確認
shogun logs --agent karo      # 特定エージェントのログ
shogun doctor                 # 環境診断
shogun upgrade                # フレームワーク本体をアップデート
```

## プロジェクト設定

`shogun init` で作成される `.shogun/config.yaml` を編集:

```yaml
agents:
  ashigaru_count: 3    # 足軽の人数 (1-7)
  taisho_model: opus   # 大将のモデル
  worker_model: sonnet # 足軽・軍師・目付のモデル
startup:
  skip_permissions: false  # true にすると --dangerously-skip-permissions が付与される
```

## エージェントのカスタマイズ

`.shogun/instructions/` 配下の Markdown を編集することで
各エージェントの振る舞いをプロジェクト毎にカスタマイズできます。

## 前提条件

| ツール | macOS | Linux |
|--------|-------|-------|
| tmux | `brew install tmux` | `sudo apt install tmux` |
| Node.js 18+ | [nodejs.org](https://nodejs.org/) | 同左 |
| Claude Code | [claude.ai/download](https://claude.ai/download) | 同左 |
| fswatch | `brew install fswatch` | — |
| inotify-tools | — | `sudo apt install inotify-tools` |
| flock | `brew install flock` | プリインストール |

## アップデート

```bash
shogun upgrade
```

## 将来拡張

- GitHub 連携（PR自動作成・Issue管理）
- Dashboard UI
- Mobile 通知（ntfy）
- 多CLI対応（Codex、Gemini CLI）

## ライセンス

MIT
