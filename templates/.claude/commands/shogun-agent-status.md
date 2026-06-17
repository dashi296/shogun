---
description: "現在のエージェントの状態（inbox 未読・タスク状況・報告書）を表示する"
---

以下のコマンドを順に実行して現在の状態を確認し、結果をまとめて表示してください。

```bash
echo "=== SHOGUN_ROLE ===" && echo "${SHOGUN_ROLE:-（未設定）}"
echo "=== inbox 未読 ===" && {
  if [ -z "${SHOGUN_ROLE:-}" ] || [ -z "${SHOGUN_ROOT:-}" ] || [ -z "${SHOGUN_BIN_DIR:-}" ]; then
    echo "SHOGUN_ROLE / SHOGUN_ROOT / SHOGUN_BIN_DIR が未設定"
  else
    node "${SHOGUN_BIN_DIR}/packages/mcp-queue/cli.js" inbox_list \
      "--root=${SHOGUN_ROOT}" "--role=${SHOGUN_ROLE}" \
      ${SHOGUN_PROJECT_ID:+"--project-id=${SHOGUN_PROJECT_ID}"}
  fi
}
echo "=== タスク状況 ===" && node -e "
const yaml = require('js-yaml');
const fs = require('fs');
const role = process.env.SHOGUN_ROLE;
const root = process.env.SHOGUN_ROOT;
if (!role || !root) { process.exit(0); }
const file = \`\${root}/.shogun/queue/tasks/\${role}.yaml\`;
if (!fs.existsSync(file)) { console.log('(タスクなし)'); process.exit(0); }
const data = yaml.load(fs.readFileSync(file, 'utf8')) || {};
(data.tasks || []).forEach(t => console.log(\`  [\${t.status}] \${t.task_id}: \${t.title || t.description?.split('\n')[0] || ''}\`));
"
echo "=== 報告書 ===" && node -e "
const yaml = require('js-yaml');
const fs = require('fs');
const role = process.env.SHOGUN_ROLE;
const root = process.env.SHOGUN_ROOT;
if (!role || !root) { process.exit(0); }
const file = \`\${root}/.shogun/queue/reports/\${role}_report.yaml\`;
if (!fs.existsSync(file)) { console.log('(報告書なし)'); process.exit(0); }
const data = yaml.load(fs.readFileSync(file, 'utf8')) || {};
const reports = data.reports || [];
if (reports.length === 0) { console.log('(報告なし)'); } else {
  const last = reports[reports.length - 1];
  console.log(\`最新: [\${last.status || 'unknown'}] \${last.task_id || ''} \${last.summary || ''}\`);
}
"
```
