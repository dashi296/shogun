#!/usr/bin/env node
'use strict';

const { Server } = require('@modelcontextprotocol/sdk/server/index.js');
const { StdioServerTransport } = require('@modelcontextprotocol/sdk/server/stdio.js');
const { CallToolRequestSchema, ListToolsRequestSchema } = require('@modelcontextprotocol/sdk/types.js');
const path = require('node:path');
const { openDb, initSchema } = require('./db.js');
const {
  handleInboxCheck, handleInboxSend, handleInboxMarkRead,
  handleReportSubmit, handleReportPoll
} = require('./tools.js');

// ─── 引数パース ───────────────────────────────────────────────
const rawArgs = process.argv.slice(2);
function getArg(name) {
  const e = rawArgs.find(a => a.startsWith(`--${name}=`));
  return e ? e.slice(`--${name}=`.length) : null;
}

const role = getArg('role');
const root = getArg('root');
const allowedSourcesRaw = getArg('allowed-sources') || '';
const allowedSources = allowedSourcesRaw ? allowedSourcesRaw.split(',').filter(Boolean) : [];

if (!role || !root) {
  process.stderr.write('Usage: shogun-mcp-queue --role=<role> --root=<shogun_root> [--allowed-sources=role1,role2]\n');
  process.exit(1);
}
if (!/^[A-Za-z0-9_-]+$/.test(role)) {
  process.stderr.write(`ERROR: invalid --role: ${role}\n`);
  process.exit(1);
}

// ─── DB 接続キャッシュ（project_id ごとに1接続）──────────────
const dbCache = new Map();

function getDb(projectId = '') {
  if (projectId && !/^[A-Za-z0-9_-]+$/.test(projectId)) {
    throw new Error(`invalid project_id: ${projectId}`);
  }
  const dbPath = projectId
    ? path.join(root, '.shogun', 'queue', 'projects', projectId, 'queue.db')
    : path.join(root, '.shogun', 'queue', 'queue.db');
  if (!dbCache.has(dbPath)) {
    const db = openDb(dbPath);
    initSchema(db);
    dbCache.set(dbPath, db);
  }
  return dbCache.get(dbPath);
}

// ─── MCP サーバ ───────────────────────────────────────────────
const TOOLS = [
  {
    name: 'inbox_check',
    description: '自分の inbox の未読メッセージ一覧を返す',
    inputSchema: {
      type: 'object',
      properties: { project_id: { type: 'string' } }
    }
  },
  {
    name: 'inbox_send',
    description: '他の役職へメッセージを送る（送信元はサーバの --role から自動設定）',
    inputSchema: {
      type: 'object',
      required: ['to', 'subject'],
      properties: {
        to:         { type: 'string' },
        subject:    { type: 'string' },
        body:       { type: 'string' },
        project_id: { type: 'string' }
      }
    }
  },
  {
    name: 'inbox_mark_read',
    description: '指定メッセージ ID を既読にする',
    inputSchema: {
      type: 'object',
      required: ['message_ids'],
      properties: {
        message_ids: { type: 'array', items: { type: 'number' } },
        project_id:  { type: 'string' }
      }
    }
  },
  {
    name: 'report_submit',
    description: '上位役職への報告を提出する（提出元はサーバの --role から自動設定）',
    inputSchema: {
      type: 'object',
      required: ['payload'],
      properties: {
        payload:    { type: 'string' },
        project_id: { type: 'string' }
      }
    }
  },
  {
    name: 'report_poll',
    description: '下位エージェントの未消費報告一覧を返す。allowlist 外の sources は無視される',
    inputSchema: {
      type: 'object',
      properties: {
        sources:    { type: 'array', items: { type: 'string' } },
        project_id: { type: 'string' }
      }
    }
  }
];

const server = new Server(
  { name: 'shogun-mcp-queue', version: '0.0.1' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: a = {} } = req.params;
  const db = getDb(a.project_id || '');

  let result;
  switch (name) {
    case 'inbox_check':      result = handleInboxCheck(db, role, a);                      break;
    case 'inbox_send':       result = handleInboxSend(db, role, a);                       break;
    case 'inbox_mark_read':  result = handleInboxMarkRead(db, role, a);                   break;
    case 'report_submit':    result = handleReportSubmit(db, role, a);                    break;
    case 'report_poll':      result = handleReportPoll(db, role, allowedSources, a);      break;
    default:                 throw new Error(`Unknown tool: ${name}`);
  }

  return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] };
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  process.stderr.write(`[shogun-mcp-queue] role=${role} ready\n`);
}

main().catch(err => {
  process.stderr.write(`[shogun-mcp-queue] fatal: ${err.message}\n`);
  process.exit(1);
});
