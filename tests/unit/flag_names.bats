#!/usr/bin/env bats
# Unit tests for scripts/flag_names.sh
#
# busy/idle・reports pending フラグ名を生成する共有ヘルパー。
# 4 スクリプト（mark_busy / stop_hook / inject_role / inbox_watcher）が同じ命名規則を
# 使うための単一情報源。最重要は「SHOGUN_ROOT が異なる別リポジトリでは、project_id を
# 付けないデフォルト運用でもフラグが衝突しない」こと（#99 系の出力破損対策で wake_up_inbox が
# idle ゲートを通るようになったため、無印フラグ衝突が inbox 通知の取りこぼしに直結する）。

load '../test_helper'

setup() {
  source "${SHOGUN_REPO}/scripts/flag_names.sh"
}

@test "flag_names: idle flag is under /tmp and contains the agent name" {
  SHOGUN_ROOT="/some/repo" run shogun_idle_flag "taisho" ""
  [ "$status" -eq 0 ]
  [[ "$output" == /tmp/shogun_idle_* ]]
  [[ "$output" == *"taisho"* ]]
}

@test "flag_names: project_id is included in the idle flag name" {
  SHOGUN_ROOT="/some/repo" run shogun_idle_flag "taisho" "projx"
  [[ "$output" == *"projx"* ]]
  [[ "$output" == *"taisho"* ]]
}

# 中核の回帰テスト: 同じ役職・project_id 無しでも、SHOGUN_ROOT が異なれば別フラグになる。
@test "flag_names: different SHOGUN_ROOT yields different idle flags (no-project)" {
  local a b
  a="$(SHOGUN_ROOT="/repo/aaa" shogun_idle_flag "taisho" "")"
  b="$(SHOGUN_ROOT="/repo/bbb" shogun_idle_flag "taisho" "")"
  [ "$a" != "$b" ]
}

@test "flag_names: same SHOGUN_ROOT yields a stable idle flag" {
  local a b
  a="$(SHOGUN_ROOT="/repo/aaa" shogun_idle_flag "taisho" "")"
  b="$(SHOGUN_ROOT="/repo/aaa" shogun_idle_flag "taisho" "")"
  [ "$a" == "$b" ]
}

@test "flag_names: reports pending flag is distinct per SHOGUN_ROOT (no-project)" {
  local a b
  a="$(SHOGUN_ROOT="/repo/aaa" shogun_reports_pending_flag "karo" "")"
  b="$(SHOGUN_ROOT="/repo/bbb" shogun_reports_pending_flag "karo" "")"
  [[ "$a" == /tmp/shogun_reports_pending_* ]]
  [ "$a" != "$b" ]
}

# idle フラグと reports pending フラグは別物として分離されていること。
@test "flag_names: idle and reports pending flags do not collide" {
  local idle pending
  idle="$(SHOGUN_ROOT="/repo/aaa" shogun_idle_flag "taisho" "")"
  pending="$(SHOGUN_ROOT="/repo/aaa" shogun_reports_pending_flag "taisho" "")"
  [ "$idle" != "$pending" ]
}
