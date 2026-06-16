'use strict';
const {
  insertMessage, queryUnread, markRead,
  insertReport, pollReports, consumeReports
} = require('./db.js');

function now() {
  return new Date().toISOString();
}

function handleInboxCheck(db, role, { project_id = '' } = {}) {
  return { messages: queryUnread(db, role, project_id) };
}

function handleInboxSend(db, fromRole, { to, subject, body = '', project_id = '' } = {}) {
  const id = insertMessage(db, {
    project_id, from_role: fromRole, to_role: to,
    subject, body, created_at: now()
  });
  return { id };
}

function handleInboxMarkRead(db, { message_ids = [] } = {}) {
  markRead(db, message_ids, now());
  return { marked: message_ids.length };
}

function handleReportSubmit(db, srcRole, { payload, project_id = '' } = {}) {
  const id = insertReport(db, { project_id, src_role: srcRole, payload, created_at: now() });
  return { id };
}

// allowedSources はサーバ起動時の --allowed-sources から固定（詐称防止）。
// args.sources で絞り込み追加指定可能だが allowedSources との積集合のみ有効。
function handleReportPoll(db, role, allowedSources, { sources = [], project_id = '' } = {}) {
  const effective = sources.length > 0
    ? sources.filter(s => allowedSources.includes(s))
    : [...allowedSources];
  if (effective.length === 0) return { reports: [] };
  const reports = pollReports(db, role, effective, project_id);
  if (reports.length > 0) {
    consumeReports(db, role, reports.map(r => r.id), now());
  }
  return { reports };
}

module.exports = {
  handleInboxCheck, handleInboxSend, handleInboxMarkRead,
  handleReportSubmit, handleReportPoll
};
