#!/usr/bin/env node
'use strict';
// Usage:
//   node cli.js inbox_send --root=<root> --from=<role> --to=<role> \
//                          --subject=<s> [--body=<b>] [--project-id=<id>]
//   node cli.js inbox_unread_count --root=<root> --role=<role> [--project-id=<id>]
//   node cli.js inbox_max_unread_id --root=<root> --role=<role> [--project-id=<id>]
//   node cli.js inbox_list --root=<root> --role=<role> [--project-id=<id>]
//   node cli.js migrate_yaml_inbox --root=<root>

const path = require('node:path');
const { openDb, initSchema, insertMessage, queryUnread } = require('./src/db.js');

const [,, command, ...rawArgs] = process.argv;

function getArg(name) {
  const e = rawArgs.find(a => a.startsWith(`--${name}=`));
  return e ? e.slice(`--${name}=`.length) : '';
}

const root = getArg('root');
if (!root) { process.stderr.write('--root is required\n'); process.exit(1); }

const ROLE_RE = /^[A-Za-z0-9_-]+$/;

const projectId = getArg('project-id');
if (projectId && !ROLE_RE.test(projectId)) {
  process.stderr.write(`ERROR: invalid project-id: ${projectId}\n`);
  process.exit(1);
}

function validateRole(value, flag) {
  if (!value || !ROLE_RE.test(value)) {
    process.stderr.write(`ERROR: invalid ${flag}: ${value}\n`);
    process.exit(1);
  }
}

function getDb() {
  const dbPath = projectId
    ? path.join(root, '.shogun', 'queue', 'projects', projectId, 'queue.db')
    : path.join(root, '.shogun', 'queue', 'queue.db');
  const db = openDb(dbPath);
  initSchema(db);
  return db;
}

if (command === 'inbox_send') {
  const fromRole = getArg('from');
  const toRole   = getArg('to');
  const subject  = getArg('subject');
  const body     = getArg('body');
  if (!fromRole || !toRole || !subject) {
    process.stderr.write('inbox_send requires --from --to --subject\n');
    process.exit(1);
  }
  validateRole(fromRole, '--from');
  validateRole(toRole,   '--to');
  const db = getDb();
  const id = insertMessage(db, {
    project_id: projectId, from_role: fromRole, to_role: toRole,
    subject, body, created_at: new Date().toISOString()
  });
  db.close();
  process.stdout.write(`${id}\n`);

} else if (command === 'inbox_unread_count') {
  const role = getArg('role');
  if (!role) { process.stderr.write('inbox_unread_count requires --role\n'); process.exit(1); }
  validateRole(role, '--role');
  const db = getDb();
  const rows = queryUnread(db, role, projectId);
  db.close();
  process.stdout.write(`${rows.length}\n`);

} else if (command === 'inbox_max_unread_id') {
  const role = getArg('role');
  if (!role) { process.stderr.write('inbox_max_unread_id requires --role\n'); process.exit(1); }
  validateRole(role, '--role');
  const db = getDb();
  const rows = queryUnread(db, role, projectId);
  db.close();
  const maxId = rows.length > 0 ? Math.max(...rows.map(r => r.id)) : 0;
  process.stdout.write(`${maxId}\n`);

} else if (command === 'inbox_list') {
  const role = getArg('role');
  if (!role) { process.stderr.write('inbox_list requires --role\n'); process.exit(1); }
  validateRole(role, '--role');
  const db = getDb();
  const rows = queryUnread(db, role, projectId);
  db.close();
  process.stdout.write(`未読: ${rows.length} 件\n`);
  for (const r of rows) {
    process.stdout.write(`  - [${r.id}] (from: ${r.from_role}) ${r.subject}\n`);
  }

} else if (command === 'migrate_yaml_inbox') {
  // YAML 形式の inbox ファイルに残っている未読メッセージを SQLite へ移行する。
  // upgrade 時に自動呼び出しされる。移行済み YAML は messages: [] にリセットする。
  const yaml = require('js-yaml');
  const fs = require('node:fs');

  function migrateDir(inboxDir, projId) {
    if (!fs.existsSync(inboxDir)) return 0;
    let count = 0;
    for (const f of fs.readdirSync(inboxDir)) {
      if (!f.endsWith('.yaml')) continue;
      const yamlPath = path.join(inboxDir, f);
      const toRole = path.basename(f, '.yaml');
      if (!ROLE_RE.test(toRole)) continue;
      let data;
      try { data = yaml.load(fs.readFileSync(yamlPath, 'utf8')) || {}; }
      catch { continue; }
      const messages = data.messages || [];
      const unread = messages.filter(m => m.status === 'unread');
      if (unread.length === 0) continue;
      const dbPath = projId
        ? path.join(root, '.shogun', 'queue', 'projects', projId, 'queue.db')
        : path.join(root, '.shogun', 'queue', 'queue.db');
      const { openDb: openDb2, initSchema: initSchema2, insertMessage: insertMessage2 } = require('./src/db.js');
      const db2 = openDb2(dbPath);
      initSchema2(db2);
      for (const m of unread) {
        const fromRole = ROLE_RE.test(m.from || '') ? m.from : 'unknown';
        insertMessage2(db2, {
          project_id: projId || '',
          from_role: fromRole,
          to_role: toRole,
          subject: m.subject || '(no subject)',
          body: m.body || '',
          created_at: m.timestamp || new Date().toISOString()
        });
      }
      db2.close();
      fs.writeFileSync(yamlPath, 'messages: []\n');
      count += unread.length;
    }
    return count;
  }

  let total = 0;
  total += migrateDir(path.join(root, '.shogun', 'queue', 'inbox'), '');
  const projectsDir = path.join(root, '.shogun', 'queue', 'projects');
  if (fs.existsSync(projectsDir)) {
    for (const proj of fs.readdirSync(projectsDir)) {
      if (!ROLE_RE.test(proj)) continue;
      total += migrateDir(path.join(projectsDir, proj, 'inbox'), proj);
    }
  }
  process.stdout.write(`${total}\n`);

} else {
  process.stderr.write(`Unknown command: ${command}\nSupported: inbox_send, inbox_unread_count, inbox_max_unread_id, inbox_list, migrate_yaml_inbox\n`);
  process.exit(1);
}
