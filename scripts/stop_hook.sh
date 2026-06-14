#!/usr/bin/env bash
# Stop フックスクリプト: ターン完了時に idle フラグを立て、inbox 未読があれば
# 自己 wake-up メッセージを stdout に出力する（Claude Code が次ターンで受信する）。
#
# 環境変数:
#   SHOGUN_ROLE        役職名（ashigaru は番号付き。例: taisho / ashigaru1）
#   SHOGUN_ROOT        .shogun/ の親ディレクトリ（未設定なら inbox 確認のみスキップ）
#   SHOGUN_PROJECT_ID  設定時はプロジェクト別のフラグ名・inbox パスを使う
# 出力:
#   inbox に未読があるときのみ通知メッセージを stdout に出力する。
#   役職が未設定・不正なときはセッションを壊さないよう何も出力せず正常終了する。
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NODE_PATH="${_SCRIPT_DIR}/../node_modules${NODE_PATH:+:$NODE_PATH}"

# フラグ命名は scripts/flag_names.sh に集約（mark_busy.sh / inject_role.sh /
# inbox_watcher.sh と共通。SHOGUN_ROOT 由来キーで別リポジトリ間の衝突を防ぐ）。
source "${_SCRIPT_DIR}/flag_names.sh"

# stdin から Stop フック JSON を読み取り stop_hook_active フィールドを確認する。
# stop_hook_active=true はフックが既に block 中の再帰呼び出しを示すため、
# decision:block は出力しないが、idle 遷移・reports 安全網は通常通り実行する。
HOOK_INPUT=""
if [[ ! -t 0 ]]; then
  HOOK_INPUT="$(cat)"
fi
stop_hook_active="false"
if [[ -n "$HOOK_INPUT" ]]; then
  stop_hook_active=$(node -e '
    try {
      const d = JSON.parse(process.argv[1]);
      process.stdout.write(d.stop_hook_active === true ? "true" : "false");
    } catch(e) { process.stdout.write("false"); }
  ' -- "$HOOK_INPUT" 2>/dev/null || echo "false")
fi

AGENT="${SHOGUN_ROLE:-}"

# 役職が未設定なら何もしない（フックは全セッションで発火するため安全側に倒す）
[[ -n "$AGENT" ]] || exit 0
# パストラバーサル防止: 役職名は英数字・アンダースコア・ハイフンのみ許可
[[ "$AGENT" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0

# SHOGUN_PROJECT_ID もフラグ名・inbox パスに展開するため同様に検証する
# （inbox_write.sh / inbox_watcher.sh / inject_role.sh と同じ規約）。
# フックはセッションを壊さないよう、不正値なら何もせず正常終了する。
if [[ -n "${SHOGUN_PROJECT_ID:-}" ]]; then
  [[ "${SHOGUN_PROJECT_ID}" =~ ^[A-Za-z0-9_-]+$ ]] || exit 0
fi

# idle フラグの命名は flag_names.sh に集約（SHOGUN_PROJECT_ID / SHOGUN_ROOT で名前空間を分離）。
FLAG="$(shogun_idle_flag "$AGENT" "${SHOGUN_PROJECT_ID:-}")"

# idle 状態へ遷移（busy → idle）
touch "$FLAG"

# reports 安全網: inbox_watcher が busy 中にスキップした report 通知を idle 復帰時に再提示する。
# inbox と違い reports には Stop 以外の救済経路がなく、busy 中に握りつぶすと次の更新が
# 来ない限り永久に気づけないため、ここで pending マーカーを消費して再通知する。
# マーカー名は inbox_watcher.sh の reports_pending_flag と一致させること（flag_names.sh に集約）。
#
# 注: ここでは直接 echo せず REPORTS_MSG に保持する。後段で block JSON を出力する場合、
# plain text を先に出すと stdout が「通常文 + JSON」の混在になり、Claude Code が
# decision:block を単一 JSON として解釈できなくなる（issue #55 の block 契約が壊れる）。
# block する経路では reason に畳み込み、しない経路でのみ plain text として出力する。
REPORTS_PENDING="$(shogun_reports_pending_flag "$AGENT" "${SHOGUN_PROJECT_ID:-}")"
REPORTS_MSG=""
if [[ -f "$REPORTS_PENDING" ]]; then
  rm -f "$REPORTS_PENDING"
  REPORTS_MSG=".shogun/queue/reports/ に下位エージェントの報告が更新されています。集約して上位へ報告してください。"
fi

# block しない経路では reports 再通知を plain text で出力する（従来どおり）。
# 早期 exit する経路（ROOT 未設定・inbox 不在）では block があり得ないため、ここで消費する。
emit_reports_plain() {
  [[ -n "$REPORTS_MSG" ]] && printf '%s\n' "$REPORTS_MSG"
  return 0
}

# inbox 未読確認（未読があればメッセージを stdout に出力 → Claude Code が次ターンで受信）
ROOT="${SHOGUN_ROOT:-}"
if [[ -z "$ROOT" ]]; then
  emit_reports_plain
  exit 0
fi

# レポート未記入チェック: 完了済み（status=done）タスクに対応するレポートが無い場合にブロック。
# stop_hook_active=true のときはスキップ（無限ループ防止）。
REPORT_MISSING_MSG=""
if [[ "$stop_hook_active" != "true" ]]; then
  TASK_FILE="${ROOT}/.shogun/queue/tasks/${AGENT}.yaml"
  if [[ -n "${SHOGUN_PROJECT_ID:-}" ]]; then
    REPORT_FILE="${ROOT}/.shogun/queue/projects/${SHOGUN_PROJECT_ID}/reports/${AGENT}_report.yaml"
  else
    REPORT_FILE="${ROOT}/.shogun/queue/reports/${AGENT}_report.yaml"
  fi
  if [[ -f "$TASK_FILE" ]]; then
    # タスクとレポートを突き合わせ、未報告の完了タスクがあれば "yes"（要ブロック）を返す。
    # - タスクファイルは 2 スキーマを取りうる: shogun init / start --clean が作り status 表示も
    #   読む tasks 配列形式（tasks: [{ status, task_id }]）と、割り当てで使う task 単一オブジェクト形式。
    # - レポートは reports 配列（要素ごとに task_id）。複数タスクが同じファイルに蓄積されるため、
    #   reports の有無だけでなく done タスクの task_id に対応する report があるかを照合する。
    # - ただしテンプレートの報告手順は report への task_id 記入を必須にしていないため、task_id を
    #   持たない（=どのタスク向けか不明だが記入済みの）report エントリがあれば報告済みとみなす。
    #   これにより task_id 厳密照合による誤ブロックを防ぎつつ、task_id 付き report しか無い場合
    #   （古いタスクの報告だけが残るケース）は引き続き未報告として検出する。
    report_missing=$(node -e '
      try {
        const fs = require("fs");
        const yaml = require("js-yaml");
        const [taskFile, reportFile] = process.argv.slice(1);
        const load = (f) => { try { return yaml.load(fs.readFileSync(f, "utf8")) || {}; } catch(e) { return {}; } };
        const td = load(taskFile);
        let doneTasks = [];
        if (Array.isArray(td.tasks)) {
          doneTasks = td.tasks.filter(t => t && t.status === "done");
        } else {
          const t = td.task || td;
          if (t && t.status === "done") doneTasks = [t];
        }
        if (doneTasks.length === 0) { process.stdout.write("no"); process.exit(0); }
        const rd = fs.existsSync(reportFile) ? load(reportFile) : {};
        const reports = Array.isArray(rd.reports) ? rd.reports : [];
        const reportedIds = new Set(reports.map(r => r && r.task_id).filter(Boolean));
        if (rd.task_id) reportedIds.add(rd.task_id); // 旧形式トップレベル
        const reportFilled = reports.length > 0 || rd.status || rd.task_id || rd.summary;
        // task_id を持たないが内容のある report（task_id 必須でないテンプレート向けのフォールバック）。
        const hasUntaggedReport =
          reports.some(r => r && !r.task_id) ||
          (reports.length === 0 && (rd.status || rd.summary));
        for (const t of doneTasks) {
          if (t.task_id) {
            if (!reportedIds.has(t.task_id) && !hasUntaggedReport) { process.stdout.write("yes"); process.exit(0); }
          } else if (!reportFilled) {
            process.stdout.write("yes"); process.exit(0);
          }
        }
        process.stdout.write("no");
      } catch(e) { process.stdout.write("no"); }
    ' -- "$TASK_FILE" "$REPORT_FILE" 2>/dev/null || echo "no")
    if [[ "$report_missing" == "yes" ]]; then
      REPORT_MISSING_MSG="タスクが完了済みですがレポートが未記入です。${AGENT}_report.yaml を記入してから終了してください。"
    fi
  fi
fi

if [[ -n "${SHOGUN_PROJECT_ID:-}" ]]; then
  INBOX="${ROOT}/.shogun/queue/projects/${SHOGUN_PROJECT_ID}/inbox/${AGENT}.yaml"
else
  INBOX="${ROOT}/.shogun/queue/inbox/${AGENT}.yaml"
fi

unread=0
if [[ -f "$INBOX" ]]; then
  unread=$(node -e '
const yaml = require("js-yaml");
const data = yaml.load(require("fs").readFileSync(process.argv[1], "utf8")) || {};
const msgs = (data.messages || []).filter(m => m.status === "unread");
process.stdout.write(String(msgs.length));
' -- "$INBOX" 2>/dev/null || echo "0")
fi

# ブロック判定: 未読メッセージまたはレポート未記入がある場合、stop_hook_active=false のときのみブロック
if [[ "$stop_hook_active" != "true" ]] && { [[ "$unread" -gt 0 ]] || [[ -n "$REPORT_MISSING_MSG" ]]; }; then
  # block 経路: stdout を単一 JSON に保つため、reports 再通知があれば reason に畳み込む。
  # reason は node の JSON.stringify でエンコードし、特殊文字が混じっても壊れないようにする。
  if [[ "$unread" -gt 0 ]]; then
    REASON="未読メッセージを処理してから終了せよ"
    [[ -n "$REPORT_MISSING_MSG" ]] && REASON="${REASON}。${REPORT_MISSING_MSG}"
  else
    REASON="$REPORT_MISSING_MSG"
  fi
  [[ -n "$REPORTS_MSG" ]] && REASON="${REPORTS_MSG} ${REASON}"
  node -e 'process.stdout.write(JSON.stringify({decision:"block",reason:process.argv[1]})+"\n")' -- "$REASON"
else
  # block しない経路（未読なし・stop_hook_active=true・タスク正常完了）では reports を plain text で出す。
  emit_reports_plain
fi
