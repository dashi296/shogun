#!/usr/bin/env bash
# agmsg（外部 OSS のエージェント間メッセージングツール）への薄いアダプタ層。
#
# agmsg は単一の CLI コマンドではなく、~/.agents/skills/<cmd_name>/scripts/*.sh に
# 配置される個別スクリプト群として動作する。このファイルは各スクリプトへの
# 薄いラッパー関数を提供する（対応 commit: 1c7efbc005c50a7eb3cbd4bac9b1f6ab17825827）。
#
# このファイルは source して使う（実行しない）。

# cmd_name が agmsg の命名規約（英数字・_・- のみ）に沿っているか判定する。
# この文字集合は agmsg 内部の percent-encoding の対象にならないため、
# 検証を通った cmd_name は他の関数（_agmsg_home 等）で直接パスに組み込んでよい。
agmsg_cmd_name_valid() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_-]+$ ]]
}

# agmsg のインストール先ディレクトリを返す。
# AGMSG_HOME_OVERRIDE が設定されていればそれを優先する（テスト用フック）。
_agmsg_home() {
  local cmd_name="${1:?cmd_name required}"
  agmsg_cmd_name_valid "$cmd_name" || return 2
  if [[ -n "${AGMSG_HOME_OVERRIDE:-}" ]]; then
    printf '%s' "${AGMSG_HOME_OVERRIDE}"
  else
    printf '%s/.agents/skills/%s' "${HOME}" "$cmd_name"
  fi
}

# インストール済み agmsg のバージョン（VERSION ファイルの最初の行を trim したもの）を返す。
agmsg_version() {
  local cmd_name="${1:?cmd_name required}"
  local home
  home="$(_agmsg_home "$cmd_name")" || return $?
  local version_file="${home}/VERSION"
  if [[ -f "$version_file" ]]; then
    head -n 1 "$version_file" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
  else
    echo "unknown"
  fi
}

# バージョン文字列が対応バージョン（v1.1.12 系の git-describe 形式）か判定する
# 純粋関数（I/O なし）。既に agmsg_version 等でバージョン文字列を取得済みの
# 呼び出し元は、再度 agmsg_version_ok を呼んで VERSION ファイルを読み直すのではなく
# こちらへ直接渡すことで、ファイル読み取り・_agmsg_home の再評価を避けられる。
_agmsg_version_string_ok() {
  [[ "$1" =~ ^v1\.1\.12(-[0-9]+-g[0-9a-f]+)?(-dirty)?$ ]]
}

# 対応バージョン（v1.1.12 系）であれば exit 0、それ以外は exit 1。
agmsg_version_ok() {
  local cmd_name="${1:?cmd_name required}"
  local version
  version="$(agmsg_version "$cmd_name")" || return $?
  _agmsg_version_string_ok "$version"
}

# 委譲先スクリプトのパスを返す。
_agmsg_script() {
  local cmd_name="$1" script="$2"
  local home
  home="$(_agmsg_home "$cmd_name")" || return $?
  printf '%s/scripts/%s' "$home" "$script"
}

# cmd_name を検証し、agmsg の <script_name> へ委譲する共通処理。
# 7つの agmsg_* パススルー関数は、委譲先スクリプト名だけが異なる薄いラッパー。
_agmsg_dispatch() {
  local cmd_name="$1" script_name="$2"; shift 2
  local script
  script="$(_agmsg_script "$cmd_name" "$script_name")" || return $?
  bash "$script" "$@"
}

# 各関数の "${@:2}" は $1（cmd_name）を除いた残り引数（agmsgスクリプトへ渡す）。
agmsg_send() { _agmsg_dispatch "$1" send.sh "${@:2}"; }
agmsg_join() { _agmsg_dispatch "$1" join.sh "${@:2}"; }
agmsg_set_delivery() { _agmsg_dispatch "$1" delivery.sh "${@:2}"; }
agmsg_spawn() { _agmsg_dispatch "$1" spawn.sh "${@:2}"; }
agmsg_despawn() { _agmsg_dispatch "$1" despawn.sh "${@:2}"; }
agmsg_inbox() { _agmsg_dispatch "$1" inbox.sh "${@:2}"; }
agmsg_history() { _agmsg_dispatch "$1" history.sh "${@:2}"; }

# agmsg の spawn が記録する placement record（team/agent の tmux 配置先）を読む。
# team/agent の文字集合検証は agmsg_cmd_name_valid と共通（agmsg 内部の
# percent-encoding の対象にならない文字集合なので、直接パスを組み立てられる）。
agmsg_get_placement() {
  local cmd_name="$1" team="$2" agent="$3"
  agmsg_cmd_name_valid "$team" || return 2
  agmsg_cmd_name_valid "$agent" || return 2

  local home
  home="$(_agmsg_home "$cmd_name")" || return $?
  local record_file="${home}/run/spawn.${team}__${agent}"
  [[ -f "$record_file" ]] || return 1
  cat "$record_file"
}
