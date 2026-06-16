'use strict';
const Database = require('better-sqlite3');
const path = require('node:path');
const fs = require('node:fs');

function openDb(dbPath) {
  fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  const db = new Database(dbPath);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  return db;
}

function initSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS messages (
      id         INTEGER PRIMARY KEY,
      project_id TEXT NOT NULL DEFAULT '',
      from_role  TEXT NOT NULL,
      to_role    TEXT NOT NULL,
      subject    TEXT NOT NULL,
      body       TEXT NOT NULL DEFAULT '',
      status     TEXT NOT NULL DEFAULT 'unread',
      created_at TEXT NOT NULL,
      read_at    TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_msg_to ON messages(to_role, status, project_id);

    CREATE TABLE IF NOT EXISTS reports (
      id         INTEGER PRIMARY KEY,
      project_id TEXT NOT NULL DEFAULT '',
      src_role   TEXT NOT NULL,
      payload    TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_rep_src ON reports(src_role, project_id);

    CREATE TABLE IF NOT EXISTS report_reads (
      report_id   INTEGER NOT NULL REFERENCES reports(id),
      role        TEXT NOT NULL,
      consumed_at TEXT NOT NULL,
      PRIMARY KEY (report_id, role)
    );
  `);
}

function closeDb(db) {
  db.close();
}

function insertMessage(db, { project_id, from_role, to_role, subject, body, created_at }) {
  const r = db.prepare(`
    INSERT INTO messages (project_id, from_role, to_role, subject, body, created_at)
    VALUES (?, ?, ?, ?, ?, ?)
  `).run(project_id, from_role, to_role, subject, body, created_at);
  return r.lastInsertRowid;
}

function queryUnread(db, toRole, projectId) {
  return db.prepare(`
    SELECT id, from_role, subject, body, created_at
    FROM messages
    WHERE to_role = ? AND status = 'unread' AND project_id = ?
    ORDER BY id ASC
  `).all(toRole, projectId);
}

function markRead(db, ids, readAt, toRole, projectId) {
  const stmt = db.prepare(
    `UPDATE messages SET status = 'read', read_at = ?
     WHERE id = ? AND to_role = ? AND project_id = ?`
  );
  db.transaction(() => { for (const id of ids) stmt.run(readAt, id, toRole, projectId); })();
}

function insertReport(db, { project_id, src_role, payload, created_at }) {
  const r = db.prepare(`
    INSERT INTO reports (project_id, src_role, payload, created_at)
    VALUES (?, ?, ?, ?)
  `).run(project_id, src_role, payload, created_at);
  return r.lastInsertRowid;
}

function pollReports(db, role, sources, projectId) {
  if (!sources || sources.length === 0) return [];
  const ph = sources.map(() => '?').join(',');
  return db.prepare(`
    SELECT r.id, r.src_role, r.payload, r.created_at
    FROM reports r
    WHERE r.project_id = ?
      AND r.src_role IN (${ph})
      AND NOT EXISTS (
        SELECT 1 FROM report_reads rr WHERE rr.report_id = r.id AND rr.role = ?
      )
    ORDER BY r.id ASC
  `).all(projectId, ...sources, role);
}

function consumeReports(db, role, ids, consumedAt) {
  const stmt = db.prepare(`
    INSERT OR IGNORE INTO report_reads (report_id, role, consumed_at) VALUES (?, ?, ?)
  `);
  db.transaction(() => { for (const id of ids) stmt.run(id, role, consumedAt); })();
}

module.exports = {
  openDb, initSchema, closeDb,
  insertMessage, queryUnread, markRead,
  insertReport, pollReports, consumeReports
};
