#!/usr/bin/env bats
# 最終ブランチ全体レビュー（agmsg tmux comm wiring）で見つかった Critical #1/#2 の
# 回帰ガード。
#
#   Critical #1: cmd_start の Taisho join が agmsg_join に <team> を渡していなかった
#                (team/agent/type/project が team=taisho, agent=claude-code,
#                type=$SHOGUN_ROOT, project=MISSING にずれる)。
#   Critical #2: cmd_spawn が agmsg_spawn に --team/--project を渡していなかった。
#
# spawn.bats/task.bats は agmsg_adapter.sh の各関数（agmsg_join/agmsg_spawn/...）
# 自体を fake 関数に差し替えて緩い部分一致（grep）でしか検証しないため、上記2件の
# ような「引数の個数・順序がずれる」バグを検出できなかった。本テストは
# init.bats の既存テスト（"joins the agmsg team..."）と同じ手法で、
# AGMSG_HOME_OVERRIDE を使い agmsg の *スクリプト境界*（join.sh/spawn.sh/send.sh/
# delivery.sh）を fake 化し、各呼び出しの完全な argv をログして比較する。
# これにより「関数はそれっぽい引数を受け取ったように見えるが、実スクリプトへの
# ディスパッチは引数がずれている」バグを検出できる。

load '../test_helper'

setup() {
  # init_test_project は setup 内で即座に `shogun init` を実行してしまうため
  # ここでは使わない（AGMSG_HOME_OVERRIDE を init 実行前に設定する必要がある）。
  # プレーンな `mktemp -d` を使う（"${TMPDIR:-/tmp}/shogun-test-XXXXXXXX" の
  # ように連結すると、末尾に "/" を含む TMPDIR 環境下で二重スラッシュ入りパスに
  # なり、$(pwd) で正規化された cmd_init 側のパスと文字列比較が食い違う）。
  TEST_PROJECT="$(mktemp -d)"
  export TEST_PROJECT
  cd "${TEST_PROJECT}"

  local agmsg_home="${TEST_PROJECT}/fake-agmsg-home"
  mkdir -p "${agmsg_home}/scripts"
  export AGMSG_HOME_OVERRIDE="${agmsg_home}"

  JOIN_LOG="${TEST_PROJECT}/join.log"
  SPAWN_LOG="${TEST_PROJECT}/spawn.log"
  SEND_LOG="${TEST_PROJECT}/send.log"
  DELIVERY_LOG="${TEST_PROJECT}/delivery.log"
  : > "$JOIN_LOG"
  : > "$SPAWN_LOG"
  : > "$SEND_LOG"
  : > "$DELIVERY_LOG"
  export JOIN_LOG SPAWN_LOG SEND_LOG DELIVERY_LOG

  # 各 fake スクリプトは自分の完全な argv を1行としてログに追記して成功を返す。
  # cmd_spawn の placement lookup（agmsg_get_placement）用の record file は
  # あえて書かない: 見つからなければ cmd_spawn 側で握りつぶされて優雅に失敗する
  # 設計になっており、本テストの主眼（team名の一貫性 / --team,--project の伝播）
  # には不要なため（簡略化）。
  cat > "${agmsg_home}/scripts/join.sh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$JOIN_LOG"
exit 0
FAKE
  cat > "${agmsg_home}/scripts/spawn.sh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$SPAWN_LOG"
exit 0
FAKE
  cat > "${agmsg_home}/scripts/send.sh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$SEND_LOG"
exit 0
FAKE
  cat > "${agmsg_home}/scripts/delivery.sh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$DELIVERY_LOG"
exit 0
FAKE
  chmod +x "${agmsg_home}/scripts/"*.sh

  _stub_tmux
}

teardown() {
  teardown_test_project
}

# tmux を no-op スタブに差し替える（実 tmux セッションを起動しない）。
_stub_tmux() {
  local stub_bin="${TEST_PROJECT}/stub-bin"
  mkdir -p "$stub_bin"
  cat > "${stub_bin}/tmux" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "${stub_bin}/tmux"
  export PATH="${stub_bin}:${PATH}"
}

@test "e2e: init -> start -> spawn -> task use the identical agmsg team name across all 4 commands" {
  run shogun init
  [ "$status" -eq 0 ]

  run shogun start --setup
  [ "$status" -eq 0 ]
  [[ "$output" != *"agmsg: taisho の登録に失敗しました"* ]]

  run shogun spawn karo
  [ "$status" -eq 0 ]

  run shogun task "regression check task"
  [ "$status" -eq 0 ]

  # join.sh は cmd_init（shogun system identity 登録）と cmd_start（Taisho join）の
  # 2回呼ばれているはず。
  local join_lines
  join_lines="$(wc -l < "$JOIN_LOG" | tr -d ' ')"
  [ "$join_lines" = "2" ]

  local init_join taisho_join
  init_join="$(sed -n '1p' "$JOIN_LOG")"
  taisho_join="$(sed -n '2p' "$JOIN_LOG")"

  # 独立に期待 team 名を計算する（init.bats の既存テストと同じ手法）。
  local project_name expected_team
  project_name="$(basename "$TEST_PROJECT")"
  expected_team="$(bash -c "source '${SHOGUN_REPO}/bin/shogun' 2>/dev/null; project_agmsg_team_name '${project_name}' '${TEST_PROJECT}'")"

  # cmd_init: join.sh <team> shogun agmsg-app <project_dir>
  [ "$init_join" = "${expected_team} shogun agmsg-app ${TEST_PROJECT}" ]

  # cmd_start（Critical #1 の修正対象）: join.sh <team> taisho claude-code <SHOGUN_ROOT>
  # 4引数がこの順序で渡っていることを厳密に確認する
  # （旧コードは <team> が欠けており team=taisho, agent=claude-code,
  #   type=$SHOGUN_ROOT, project=MISSING にずれていた）。
  [ "$taisho_join" = "${expected_team} taisho claude-code ${TEST_PROJECT}" ]

  # cmd_spawn（Critical #2 の修正対象）: spawn.sh の argv に --team と --project が
  # 正しい値で含まれていること。
  run grep -F -- "--team ${expected_team}" "$SPAWN_LOG"
  [ "$status" -eq 0 ]
  run grep -F -- "--project ${TEST_PROJECT}" "$SPAWN_LOG"
  [ "$status" -eq 0 ]

  # cmd_task: send.sh <team> shogun taisho <message>
  run grep -F -- "${expected_team} shogun taisho regression check task" "$SEND_LOG"
  [ "$status" -eq 0 ]

  # 4箇所すべてから抽出した team 名が「文字列として完全に同一」であることを
  # 明示的に突き合わせる（これが Critical #1/#2 が破っていた不変条件そのもの）。
  local team_from_init team_from_start team_from_spawn team_from_send
  team_from_init="$(awk '{print $1}' <<< "$init_join")"
  team_from_start="$(awk '{print $1}' <<< "$taisho_join")"
  team_from_spawn="$(grep -o -- '--team [^ ]*' "$SPAWN_LOG" | head -n1 | awk '{print $2}')"
  team_from_send="$(awk '{print $1}' "$SEND_LOG")"

  [ "$team_from_init" = "$expected_team" ]
  [ "$team_from_start" = "$expected_team" ]
  [ "$team_from_spawn" = "$expected_team" ]
  [ "$team_from_send" = "$expected_team" ]
}
