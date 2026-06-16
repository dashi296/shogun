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

  test('to に不正文字を含む場合は Error を投げる（パストラバーサル防止）', () => {
    assert.throws(
      () => handleInboxSend(db, 'karo', { to: '../evil', subject: 'x', project_id: '' }),
      /invalid to/
    );
  });

  test('to にスペースを含む場合は Error を投げる', () => {
    assert.throws(
      () => handleInboxSend(db, 'karo', { to: 'bad role', subject: 'x', project_id: '' }),
      /invalid to/
    );
  });

  test('to が空文字の場合は Error を投げる', () => {
    assert.throws(
      () => handleInboxSend(db, 'karo', { to: '', subject: 'x', project_id: '' }),
      /invalid to/
    );
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

// ── server.js ディスパッチの project_id 伝播 ──────────────────────────────
// server.js は「DB パスの選択」と「ハンドラへの引数」の両方に同じ project_id を
// 使う必要がある。以前の実装は DB パスだけ補完し、ハンドラには空文字を渡していたため
// project_id='' でレコードが保存され、watcher が --project-id=<id> で検索しても
// 見つからないという不具合があった。
describe('server dispatch: SHOGUN_PROJECT_ID → project_id 伝播', () => {
  test('args に project_id がない場合、SHOGUN_PROJECT_ID で補完されハンドラにも伝わる', () => {
    const savedEnv = process.env.SHOGUN_PROJECT_ID;
    process.env.SHOGUN_PROJECT_ID = 'proj-dispatch';
    try {
      // server.js のディスパッチロジックを模倣
      const a = { to: 'taisho', subject: 'dispatch-test' }; // project_id 省略
      const effectiveProjectId = a.project_id || process.env.SHOGUN_PROJECT_ID || '';
      const args = { ...a, project_id: effectiveProjectId }; // 修正後: args にも反映

      const { id } = handleInboxSend(db, 'karo', args);
      assert.ok(id > 0);

      // effectiveProjectId で検索 → 見つかる
      const { messages } = handleInboxCheck(db, 'taisho', { project_id: 'proj-dispatch' });
      assert.ok(
        messages.some(m => m.subject === 'dispatch-test'),
        'project_id が補完されハンドラへ伝わることで検索可能になる'
      );

      // 空の project_id で検索 → 見つからない（project 用レコードは混在しない）
      const { messages: noproj } = handleInboxCheck(db, 'taisho', { project_id: '' });
      assert.ok(
        !noproj.some(m => m.subject === 'dispatch-test'),
        '空 project_id では project 付きのメッセージは見えない'
      );
    } finally {
      if (savedEnv === undefined) delete process.env.SHOGUN_PROJECT_ID;
      else process.env.SHOGUN_PROJECT_ID = savedEnv;
    }
  });
});
