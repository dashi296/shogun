'use strict';
const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const { openDb, initSchema, closeDb } = require('../src/db.js');
const {
  handleInboxCheck, handleInboxSend, handleInboxMarkRead,
  handleReportSubmit, handleReportPoll
} = require('../src/tools.js');

let db;
let tmpDir;

before(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'shogun-tools-test-'));
  db = openDb(path.join(tmpDir, 'test.db'));
  initSchema(db);
});

after(() => {
  closeDb(db);
  fs.rmSync(tmpDir, { recursive: true });
});

describe('handleInboxSend / handleInboxCheck', () => {
  test('送信したメッセージが inbox_check で取得できる', () => {
    const { id } = handleInboxSend(db, 'karo', { to: 'taisho', subject: 'tool-hello', body: 'world', project_id: '' });
    assert.ok(id > 0);
    const { messages } = handleInboxCheck(db, 'taisho', { project_id: '' });
    assert.ok(messages.some(m => m.subject === 'tool-hello'));
  });

  test('from_role はサーバの role から取る（引数渡し不可）', () => {
    handleInboxSend(db, 'ashigaru1', { to: 'karo', subject: 'from-test', body: '', project_id: '' });
    const { messages } = handleInboxCheck(db, 'karo', { project_id: '' });
    const m = messages.find(m => m.subject === 'from-test');
    assert.equal(m.from_role, 'ashigaru1');
  });
});

describe('handleInboxMarkRead', () => {
  test('既読にしたメッセージは inbox_check に出なくなる', () => {
    const { id } = handleInboxSend(db, 'karo', { to: 'taisho', subject: 'mark-read-test', body: '', project_id: '' });
    handleInboxMarkRead(db, { message_ids: [id] });
    const { messages } = handleInboxCheck(db, 'taisho', { project_id: '' });
    assert.ok(messages.every(m => m.subject !== 'mark-read-test'));
  });
});

describe('handleReportSubmit / handleReportPoll', () => {
  test('submit した報告が allowlist 内の role から poll できる', () => {
    handleReportSubmit(db, 'karo', { payload: JSON.stringify({ summary: 'done' }), project_id: '' });
    // taisho の allowed_sources = ['karo']
    const { reports } = handleReportPoll(db, 'taisho', ['karo'], { project_id: '' });
    assert.ok(reports.length >= 1);
    assert.ok(reports.some(r => r.src_role === 'karo'));
  });

  test('一度 poll した報告は次の poll で出ない（自動消費）', () => {
    const { reports } = handleReportPoll(db, 'taisho', ['karo'], { project_id: '' });
    assert.equal(reports.length, 0);
  });

  test('allowedSources 外の sources 引数は無視される（詐称防止）', () => {
    handleReportSubmit(db, 'taisho', { payload: '{"x":1}', project_id: '' });
    // karo の allowedSources = ['ashigaru1'] → sources に taisho を指定しても取れない
    const { reports } = handleReportPoll(db, 'karo', ['ashigaru1'], { sources: ['taisho', 'ashigaru1'], project_id: '' });
    assert.ok(reports.every(r => r.src_role !== 'taisho'));
  });

  test('sources が空のとき allowedSources 全体を対象にする', () => {
    handleReportSubmit(db, 'ashigaru1', { payload: '{"ok":true}', project_id: '' });
    // sources 未指定 → karo の allowedSources=['ashigaru1'] 全体が対象
    const { reports } = handleReportPoll(db, 'karo', ['ashigaru1'], { project_id: '' });
    assert.ok(reports.length >= 1);
  });

  test('allowedSources が空なら結果は空（Ashigaru は poll 不可）', () => {
    const { reports } = handleReportPoll(db, 'ashigaru1', [], { project_id: '' });
    assert.equal(reports.length, 0);
  });
});
