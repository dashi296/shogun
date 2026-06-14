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

# SessionStart hook の入力(JSON)から source を取得する。stdin が端末のとき
# （手動実行・ローカルテスト）は読まずに従来どおり idle 化する（cat のハング防止）。
HOOK_SOURCE=""
if [[ ! -t 0 ]]; then
  _HOOK_INPUT="$(cat)"
  HOOK_SOURCE="$(printf '%s' "$_HOOK_INPUT" | node -e '
let s = "";
process.stdin.on("data", d => s += d);
process.stdin.on("end", () => {
  try { process.stdout.write(String(JSON.parse(s).source || "")); }
  catch (e) { process.stdout.write(""); }
});
' 2>/dev/null || true)"
fi

# SessionStart 時点（起動 / resume / clear）はプロンプト待ち = idle なので idle フラグを立てる。
# これがないと、起動直後でまだ一度も Stop していないエージェントは「フラグ無し = busy」と
# 誤判定され、最初のタスク通知が wake ゲート（inbox_watcher の is_agent_idle）で skip される。
# busy 化はターン開始時の mark_busy.sh（UserPromptSubmit フック）が担う。
# フラグ名は stop_hook.sh / mark_busy.sh / inbox_watcher.sh の is_agent_idle と一致させる。
# project_id の検証も stop_hook.sh と揃える（不正値ならフラグ操作をスキップ）。
#
# 例外: source=compact の継続ターンでは UserPromptSubmit(mark_busy) が走らないため、
# ここで idle フラグを立てると作業中(busy)のまま idle と誤判定され、busy ペインへの
# send-keys 注入（出力破損）が再発する。compact ではフラグを一切操作せず、直前の
# busy/idle 状態をそのまま維持する（busy 側に倒して破損を防ぐ）。
if [[ "$HOOK_SOURCE" != "compact" ]]; then
  _PROJECT_ID="${SHOGUN_PROJECT_ID:-}"
  if [[ -z "$_PROJECT_ID" ]]; then
    touch "/tmp/shogun_idle_${ROLE}"
  elif [[ "$_PROJECT_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    touch "/tmp/shogun_idle_${_PROJECT_ID}_${ROLE}"
  fi
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
