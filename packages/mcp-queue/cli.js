#!/usr/bin/env node
'use strict';
// Usage:
//   node cli.js inbox_send --root=<root> --from=<role> --to=<role> \
//                          --subject=<s> [--body=<b>] [--project-id=<id>]
//   node cli.js inbox_unread_count --root=<root> --role=<role> [--project-id=<id>]

const path = require('node:path');
const { openDb, initSchema, insertMessage, queryUnread } = require('./src/db.js');

const [,, command, ...rawArgs] = process.argv;

function getArg(name) {
  const e = rawArgs.find(a => a.startsWith(`--${name}=`));
  return e ? e.slice(`--${name}=`.length) : '';
}

const root = getArg('root');
if (!root) { process.stderr.write('--root is required\n'); process.exit(1); }

const projectId = getArg('project-id');
if (projectId && !/^[A-Za-z0-9_-]+$/.test(projectId)) {
  process.stderr.write(`ERROR: invalid project-id: ${projectId}\n`);
  process.exit(1);
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
  const db = getDb();
  const rows = queryUnread(db, role, projectId);
  db.close();
  process.stdout.write(`${rows.length}\n`);

} else {
  process.stderr.write(`Unknown command: ${command}\nSupported: inbox_send, inbox_unread_count\n`);
  process.exit(1);
}
