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

# ターン開始時に idle フラグを削除して busy 状態へ遷移する。
# Stop フック（scripts/stop_hook.sh）がターン完了時に立てた idle フラグを消すことで、
# escalation watcher が「作業中（busy）」と判定し誤って中断しないようにする。
# フラグ名は stop_hook.sh / inbox_watcher.sh の is_agent_idle と一致させる。
# project_id の検証も stop_hook.sh と揃える（不正値ならフラグ操作をスキップ＝
# stop_hook.sh もフラグを作らないため、消すべき対象が存在しない）。
_PROJECT_ID="${SHOGUN_PROJECT_ID:-}"
if [[ -z "$_PROJECT_ID" ]]; then
  rm -f "/tmp/shogun_idle_${ROLE}"
elif [[ "$_PROJECT_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  rm -f "/tmp/shogun_idle_${_PROJECT_ID}_${ROLE}"
fi

# instructions ファイル名は末尾の数字を除去する（ashigaru1 → ashigaru）。
# inbox / tasks / reports は番号付きのまま使うため、ここでは表示用 ROLE は変えない。
BASE_ROLE="$ROLE"
while [[ "$BASE_ROLE" =~ [0-9]$ ]]; do
  BASE_ROLE="${BASE_ROLE%[0-9]}"
done

INSTRUCTIONS="${ROOT}/.shogun/instructions/${BASE_ROLE}.md"
COMMON="${ROOT}/.shogun/CLAUDE.md"
CONFIG="${ROOT}/.shogun/config.yaml"

HEADER="# あなたの役職: ${ROLE}

あなたは Shogun マルチエージェントシステムの「${ROLE}」です（SHOGUN_ROLE=${ROLE}）。
以下の役割定義（instructions/${BASE_ROLE}.md）と共通設定（CLAUDE.md）に従って行動してください。"

# 値は process.argv 経由で渡し、JSON.stringify で安全にエスケープする
node -e '
const fs = require("fs");
const [role, configPath, header, ...files] = process.argv.slice(1);

let sengoku = false;
try {
  const yaml = require("js-yaml");
  const cfg = yaml.load(fs.readFileSync(configPath, "utf8"));
  sengoku = cfg?.persona?.sengoku === true;
} catch (e) {
  // 欠損・不正 YAML -> false にフォールバック（exit 0 で継続）
}
const sengokuStr = String(sengoku);

const sengokuLine = sengoku
  ? "戦国風口調【有効】: ターミナルへの出力は戦国風口調を使うこと。"
  : "通常口調【無効】: ターミナルへの出力は通常口調を使うこと。";

const baseRole = role.replace(/\d+$/, "");
const isCoordinator = baseRole === "taisho" || baseRole === "karo";
const delegationNote = isCoordinator ? [
  "## 委任原則（coordinator 共通）",
  "- タスクは自身で実行せず、担当役職へ委任すること（self_execute_task 禁止）",
  "- ポーリングループの実行禁止（while true; do sleep; done 等）",
  "- 担当外ファイルへの書き込み禁止",
].join("\n") : "";

const fullHeader = isCoordinator
  ? header + "\n\n## 口調設定\n" + sengokuLine + "\n\n" + delegationNote
  : header + "\n\n## 口調設定\n" + sengokuLine;

let ctx = fullHeader + "\n";
for (const f of files) {
  try {
    let content = fs.readFileSync(f, "utf8");
    content = content.replace(/\{\{\s*persona\.sengoku\s*\}\}/g, sengokuStr);
    ctx += "\n\n---\n\n" + content;
  } catch (e) { /* 無いファイルは無視 */ }
}
process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: ctx }
}));
' -- "$ROLE" "$CONFIG" "$HEADER" "$INSTRUCTIONS" "$COMMON"
