#!/usr/bin/env bash
# SessionStart フックスクリプト: 起動 / resume / clear / compact のたびに、
# 自分の役職アイデンティティと役割定義を additionalContext として注入する。
#
# 環境変数:
#   SHOGUN_ROLE  役職名（ashigaru は番号付き。例: taisho / ashigaru1）
#   SHOGUN_ROOT  .shogun/ の親ディレクトリ（未設定なら CLAUDE_PROJECT_DIR / PWD を使う）
# 出力:
#   役職が有効なときのみ SessionStart フック用 JSON を stdout に出力する。
#   役職が不明・不正なときはセッションを壊さないよう何も出力せず正常終了する。
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NODE_PATH="${_SCRIPT_DIR}/../node_modules${NODE_PATH:+:$NODE_PATH}"

ROLE="${SHOGUN_ROLE:-}"
ROOT="${SHOGUN_ROOT:-${CLAUDE_PROJECT_DIR:-$PWD}}"

# 役職が未設定なら何もしない（フックは全セッションで発火するため安全側に倒す）
[[ -n "$ROLE" ]] || exit 0
# パストラバーサル防止: 役職名は英数字・アンダースコア・ハイフンのみ許可
[[ "$ROLE" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0

# instructions ファイル名は末尾の数字を除去する（ashigaru1 → ashigaru）。
# inbox / tasks / reports は番号付きのまま使うため、ここでは表示用 ROLE は変えない。
BASE_ROLE="$ROLE"
while [[ "$BASE_ROLE" =~ [0-9]$ ]]; do
  BASE_ROLE="${BASE_ROLE%[0-9]}"
done

INSTRUCTIONS="${ROOT}/.shogun/instructions/${BASE_ROLE}.md"
COMMON="${ROOT}/.shogun/CLAUDE.md"

HEADER="# あなたの役職: ${ROLE}

あなたは Shogun マルチエージェントシステムの「${ROLE}」です（SHOGUN_ROLE=${ROLE}）。
以下の役割定義（instructions/${BASE_ROLE}.md）と共通設定（CLAUDE.md）に従って行動してください。"

# 値は process.argv 経由で渡し、JSON.stringify で安全にエスケープする
node -e '
const fs = require("fs");
const [role, header, ...files] = process.argv.slice(1);
let ctx = header + "\n";
for (const f of files) {
  try { ctx += "\n\n---\n\n" + fs.readFileSync(f, "utf8"); } catch (e) { /* 無いファイルは無視 */ }
}
process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: ctx }
}));
' -- "$ROLE" "$HEADER" "$INSTRUCTIONS" "$COMMON"
