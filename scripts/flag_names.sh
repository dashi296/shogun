#!/usr/bin/env bash
# busy/idle・reports pending フラグ名の生成を一箇所へ集約する共有ヘルパー。
#
# このファイルは source して使う（実行しない）。利用側:
#   scripts/mark_busy.sh / stop_hook.sh / inject_role.sh / inbox_watcher.sh
# テストからも source して期待パスを生成し、命名規則の単一情報源とする。
#
# なぜ SHOGUN_ROOT 由来のキーを含めるか:
#   これらのフラグは /tmp 上のグローバルなパスのため、SHOGUN_ROOT が異なる別リポジトリで
#   project_id を付けず（デフォルト運用で）起動すると、役職名だけのフラグ
#   （旧 /tmp/shogun_idle_taisho 等）が衝突する。#99 系の出力破損対策で wake_up_inbox が
#   idle ゲートを通るようになったため、片方の mark_busy がもう片方の idle フラグを消すと、
#   待機中の別プロジェクトに来た inbox 更新が busy 判定で skip され、inbox には pending
#   マーカーも無いため次の Stop まで取りこぼす。これを防ぐため SHOGUN_ROOT 由来のキーを
#   全フラグ名へ含め、リポジトリ単位で名前空間を分離する。
#
# 注: キーは「同一セッション内の 4 スクリプトが同じ SHOGUN_ROOT 文字列を共有する」ことだけに
# 依存する（bin/shogun が単一の SHOGUN_ROOT を export する）。symlink 解決はしない——
# 同じ文字列なら同じキーになり、別リポジトリ間の分離という目的には十分なため。

# SHOGUN_ROOT を filesystem-safe な短いキーへ変換する。
# cksum は macOS / Linux 双方で利用でき、出力は数値のみ（パストラバーサル無害化も兼ねる）。
_shogun_flag_root_key() {
  printf '%s' "${SHOGUN_ROOT:-}" | cksum | cut -d' ' -f1
}

# idle フラグのパスを返す。引数: <agent> <project_id_or_empty>
shogun_idle_flag() {
  local agent="$1" project_id="${2:-}" key
  key="$(_shogun_flag_root_key)"
  if [[ -n "$project_id" ]]; then
    printf '/tmp/shogun_idle_%s_%s_%s' "$key" "$project_id" "$agent"
  else
    printf '/tmp/shogun_idle_%s_%s' "$key" "$agent"
  fi
}

# reports pending マーカーのパスを返す（busy 中にスキップした report 通知の記録用）。
# 引数: <agent> <project_id_or_empty>
shogun_reports_pending_flag() {
  local agent="$1" project_id="${2:-}" key
  key="$(_shogun_flag_root_key)"
  if [[ -n "$project_id" ]]; then
    printf '/tmp/shogun_reports_pending_%s_%s_%s' "$key" "$project_id" "$agent"
  else
    printf '/tmp/shogun_reports_pending_%s_%s' "$key" "$agent"
  fi
}
