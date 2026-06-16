'use strict';
const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const {
  openDb, initSchema, closeDb,
  insertMessage, queryUnread, markRead,
  insertReport, pollReports, consumeReports
} = require('../src/db.js');

let db;
let tmpDir;

before(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'shogun-db-test-'));
  db = openDb(path.join(tmpDir, 'test.db'));
  initSchema(db);
});

after(() => {
  closeDb(db);
  fs.rmSync(tmpDir, { recursive: true });
});

describe('messages', () => {
  test('insertMessage returns positive id', () => {
    const id = insertMessage(db, {
      project_id: '', from_role: 'karo', to_role: 'taisho',
      subject: 'hello', body: 'world', created_at: '2026-01-01T00:00:00Z'
    });
    assert.ok(id > 0);
  });

  test('queryUnread returns unread messages for role', () => {
    insertMessage(db, {
      project_id: '', from_role: 'karo', to_role: 'taisho',
      subject: 'unread-test', body: '', created_at: '2026-01-01T00:00:01Z'
    });
    const rows = queryUnread(db, 'taisho', '');
    assert.ok(rows.length >= 1);
    assert.ok(rows.some(r => r.subject === 'unread-test'));
  });

  test('queryUnread does not return other roles messages', () => {
    const rows = queryUnread(db, 'karo', '');
    assert.ok(rows.every(r => r.subject !== 'hello'));
  });

  test('markRead removes from unread', () => {
    const id = insertMessage(db, {
      project_id: '', from_role: 'karo', to_role: 'taisho',
      subject: 'mark-me', body: '', created_at: '2026-01-01T00:00:02Z'
    });
    markRead(db, [id], '2026-01-01T00:00:03Z');
    const rows = queryUnread(db, 'taisho', '');
    assert.ok(rows.every(r => r.subject !== 'mark-me'));
  });

  test('project_id scoping: message in project A not visible in project empty', () => {
    insertMessage(db, {
      project_id: 'projA', from_role: 'karo', to_role: 'taisho',
      subject: 'proj-msg', body: '', created_at: '2026-01-01T00:01:00Z'
    });
    const rows = queryUnread(db, 'taisho', '');
    assert.ok(rows.every(r => r.subject !== 'proj-msg'));
    const rows2 = queryUnread(db, 'taisho', 'projA');
    assert.ok(rows2.some(r => r.subject === 'proj-msg'));
  });
});

describe('reports', () => {
  test('insertReport returns positive id', () => {
    const id = insertReport(db, {
      project_id: '', src_role: 'karo', payload: '{"summary":"ok"}',
      created_at: '2026-01-01T00:00:00Z'
    });
    assert.ok(id > 0);
  });

  test('pollReports returns unconsumed reports in allowed sources', () => {
    const rows = pollReports(db, 'taisho', ['karo'], '');
    assert.ok(rows.length >= 1);
    assert.ok(rows.some(r => r.src_role === 'karo'));
  });

  test('pollReports excludes sources not in allowlist', () => {
    insertReport(db, {
      project_id: '', src_role: 'ashigaru1', payload: '{}',
      created_at: '2026-01-01T00:00:01Z'
    });
    // taisho only allowed to see karo
    const rows = pollReports(db, 'taisho', ['karo'], '');
    assert.ok(rows.every(r => r.src_role !== 'ashigaru1'));
  });

  test('consumeReports marks as consumed for role', () => {
    const rows = pollReports(db, 'taisho', ['karo'], '');
    const ids = rows.map(r => r.id);
    consumeReports(db, 'taisho', ids, '2026-01-01T00:00:05Z');
    const rows2 = pollReports(db, 'taisho', ['karo'], '');
    assert.equal(rows2.length, 0);
  });

  test('consumed by one role still visible to another', () => {
    // karo は ashigaru1 の report を poll できる
    const rows = pollReports(db, 'karo', ['ashigaru1'], '');
    assert.ok(rows.length >= 1);
    consumeReports(db, 'karo', rows.map(r => r.id), '2026-01-01T00:00:06Z');
    // metsuke も ashigaru1 の report を独立して poll できる
    insertReport(db, {
      project_id: '', src_role: 'ashigaru1', payload: '{"x":1}',
      created_at: '2026-01-01T00:00:07Z'
    });
    const rowsMetsuke = pollReports(db, 'metsuke', ['ashigaru1'], '');
    assert.ok(rowsMetsuke.length >= 1);
  });
});
