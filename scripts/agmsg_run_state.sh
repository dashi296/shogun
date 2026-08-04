#!/usr/bin/env bash
# shogun start の実行（run）ごとの状態管理。
#
# Taisho/Karo が agmsg spawn 時に --fresh を付けるべきか判定するために使う
# （docs/superpowers/specs/2026-08-02-agmsg-orchestration-design.md §8「resume と
# --fresh の使い分け」参照）。run_id は shogun start のたびに発行し直し、
# 役職ごとの「この run で fresh spawn が成立済みか」フラグをマーカーファイルで
# 管理する。
#
# このファイルは source して使う（実行しない）。

_agmsg_run_state_dir() {
  printf '%s/.shogun/state' "${SHOGUN_ROOT:?SHOGUN_ROOT required}"
}

# 新しい run を開始する: run_id を新規発行し、前回の run の fresh_done マーカーを
# 全消去する。標準出力に新しい run_id を返す。
agmsg_run_state_new_run() {
  local dir
  dir="$(_agmsg_run_state_dir)"
  mkdir -p "${dir}/fresh_done"
  rm -f "${dir}"/fresh_done/*
  local run_id
  run_id="$(node -e 'process.stdout.write(require("crypto").randomUUID())')"
  printf '%s' "$run_id" > "${dir}/run_id"
  printf '%s' "$run_id"
}

# 現在の run_id を返す（未発行なら空文字）。
agmsg_run_state_current() {
  local file
  file="$(_agmsg_run_state_dir)/run_id"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    printf ''
  fi
}

# role の fresh spawn が今回の run でまだ成立していなければ exit 0（--fresh が
# 必要）、成立済みなら exit 1。role が不正なら exit 2。
agmsg_run_state_fresh_needed() {
  local role="${1:?role required}"
  [[ "$role" =~ ^[A-Za-z0-9_-]+$ ]] || return 2
  local marker
  marker="$(_agmsg_run_state_dir)/fresh_done/${role}"
  [[ ! -f "$marker" ]]
}

# role の fresh spawn が成立したことを記録する。role が不正なら exit 2。
agmsg_run_state_mark_fresh_done() {
  local role="${1:?role required}"
  [[ "$role" =~ ^[A-Za-z0-9_-]+$ ]] || return 2
  local dir
  dir="$(_agmsg_run_state_dir)"
  mkdir -p "${dir}/fresh_done"
  : > "${dir}/fresh_done/${role}"
}
