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
    handleInboxMarkRead(db, 'taisho', { message_ids: [id], project_id: '' });
    const { messages } = handleInboxCheck(db, 'taisho', { project_id: '' });
    assert.ok(messages.every(m => m.subject !== 'mark-read-test'));
  });

  test('他役職のメッセージ ID を指定しても既読化されない（スコープ防止）', () => {
    // taisho 宛のメッセージを送信
    const { id } = handleInboxSend(db, 'karo', { to: 'taisho', subject: 'scope-guard-test', body: '', project_id: '' });
    // karo として mark_read を呼んでも taisho 宛は変化しない
    handleInboxMarkRead(db, 'karo', { message_ids: [id], project_id: '' });
    const { messages } = handleInboxCheck(db, 'taisho', { project_id: '' });
    assert.ok(messages.some(m => m.subject === 'scope-guard-test'), 'taisho の未読が消えてはいけない');
  });

  test('project_id 付きメッセージを同一 project_id で既読化できる', () => {
    const { id } = handleInboxSend(db, 'karo', { to: 'taisho', subject: 'proj-mark-ok', body: '', project_id: 'proj-c' });
    handleInboxMarkRead(db, 'taisho', { message_ids: [id], project_id: 'proj-c' });
    const { messages } = handleInboxCheck(db, 'taisho', { project_id: 'proj-c' });
    assert.ok(messages.every(m => m.subject !== 'proj-mark-ok'), 'project_id 付き既読化が機能する必要がある');
  });

  test('project_id が異なるメッセージは既読化されない', () => {
    const { id } = handleInboxSend(db, 'karo', { to: 'taisho', subject: 'proj-scope-test', body: '', project_id: 'proj-a' });
    // 同じ role だが project_id が違う
    handleInboxMarkRead(db, 'taisho', { message_ids: [id], project_id: 'proj-b' });
    const { messages } = handleInboxCheck(db, 'taisho', { project_id: 'proj-a' });
    assert.ok(messages.some(m => m.subject === 'proj-scope-test'), 'project_id 違いで既読化されてはいけない');
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
