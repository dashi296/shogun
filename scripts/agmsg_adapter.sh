#!/usr/bin/env bash
# agmsg（外部 OSS のエージェント間メッセージングツール）への薄いアダプタ層。
#
# agmsg は単一の CLI コマンドではなく、~/.agents/skills/<cmd_name>/scripts/*.sh に
# 配置される個別スクリプト群として動作する。このファイルは各スクリプトへの
# 薄いラッパー関数を提供する（対応 commit: 1c7efbc005c50a7eb3cbd4bac9b1f6ab17825827）。
#
# このファイルは source して使う（実行しない）。
set -euo pipefail

# agmsg のインストール先ディレクトリを返す。
# AGMSG_HOME_OVERRIDE が設定されていればそれを優先する（テスト用フック）。
_agmsg_home() {
  local cmd_name="${1:?cmd_name required}"
  if [[ -n "${AGMSG_HOME_OVERRIDE:-}" ]]; then
    printf '%s' "${AGMSG_HOME_OVERRIDE}"
  else
    printf '%s/.agents/skills/%s' "${HOME}" "$cmd_name"
  fi
}

# インストール済み agmsg のバージョン（VERSION ファイルの内容）を返す。
agmsg_version() {
  local cmd_name="${1:?cmd_name required}"
  local version_file
  version_file="$(_agmsg_home "$cmd_name")/VERSION"
  if [[ -f "$version_file" ]]; then
    cat "$version_file"
  else
    echo "unknown"
  fi
}

# 対応バージョン（v1.1.12 系）であれば exit 0、それ以外は exit 1。
agmsg_version_ok() {
  local cmd_name="${1:?cmd_name required}"
  local version
  version="$(agmsg_version "$cmd_name")"
  [[ "$version" == v1.1.12* ]]
}
