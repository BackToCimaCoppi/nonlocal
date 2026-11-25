import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { createDefaultConfig } from '../dist/config/schema.js';
import { AntigravityAdapter } from '../dist/adapter/antigravity-adapter.js';
import { WsServerTransport } from '../dist/transport/ws-server-transport.js';
import { NonlocalGateway } from '../dist/gateway/gateway.js';
import { StateStore } from '../dist/store/state-store.js';
import { SanitizedLogger } from '../dist/log/logger.js';
import { connectWs } from './helpers/ws-client.mjs';
import { createTestToken, makeTempDir, rmTempDir } from './helpers/test-utils.mjs';

const FAKE_SERVER = fileURLToPath(new URL('./helpers/fake-acp-server.mjs', import.meta.url));

test('AC-45: read-only conversation_summaries.db (zero -wal/-shm sidecars on clean DB, active WAL visibility, bounded BFS cycle/depth8/cap100, and disk-missing wake eviction) (PP-45-ro)', async () => {
  const root = makeTempDir('nonlocal-ro-ac45-');
  const agyDir = join(root, 'agy-data');
  const agyWalDir = join(root, 'agy-wal-data');
  mkdirSync(join(agyDir, 'conversations'), { recursive: true });
  mkdirSync(agyWalDir, { recursive: true });

  // 1. Clean DB without active WAL: opening with immutable=1 creates zero -wal/-shm sidecars
  const cleanDbPath = join(agyDir, 'conversation_summaries.db');
  const cleanDb = new DatabaseSync(cleanDbPath);
  cleanDb.exec(`
    CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT, parent_conversation_id TEXT);
    CREATE TABLE conversation_parents (conversation_id TEXT, parent_id TEXT);
  `);
  // Chain of depth 10 + cycle to test max depth 8 & cycle safety
  for (let i = 0; i <= 10; i++) {
    const id = i === 0 ? 's-parent' : `sub-${i}`;
    const parent = i === 0 ? null : i === 1 ? 's-parent' : `sub-${i - 1}`;
    cleanDb
      .prepare('INSERT INTO conversation_summaries (conversation_id, title, parent_conversation_id) VALUES (?, ?, ?)')
      .run(id, `Title ${id}`, parent);
  }
  cleanDb.prepare('INSERT INTO conversation_parents (conversation_id, parent_id) VALUES (?, ?)').run('s-parent', 'sub-2'); // cycle back!
  // 120 direct children on s-cap to test max 100 cap
  cleanDb.prepare('INSERT INTO conversation_summaries (conversation_id, title, parent_conversation_id) VALUES (?, ?, NULL)').run('s-cap', 'Cap Root');
  for (let i = 0; i < 120; i++) {
    cleanDb
      .prepare('INSERT INTO conversation_summaries (conversation_id, title, parent_conversation_id) VALUES (?, ?, ?)')
      .run(`cap-c-${String(i).padStart(3, '0')}`, `Cap ${i}`, 's-cap');
  }
  cleanDb.close();
  assert.equal(existsSync(`${cleanDbPath}-wal`), false);
  assert.equal(existsSync(`${cleanDbPath}-shm`), false);

  // 2. Active uncheckpointed WAL DB: read-only open still sees uncommitted WAL row!
  const walDbPath = join(agyWalDir, 'conversation_summaries.db');
  const walWriter = new DatabaseSync(walDbPath);
  walWriter.exec('PRAGMA journal_mode = WAL;');
  walWriter.exec('PRAGMA wal_autocheckpoint = 0;');
  walWriter.exec('CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT, parent_conversation_id TEXT);');
  walWriter.prepare("INSERT INTO conversation_summaries VALUES ('s-wal', 'Initial WAL', NULL)").run();
  walWriter.exec("INSERT INTO conversation_summaries VALUES ('sub-wal', 'Live WAL Child', 's-wal')");
  assert.equal(existsSync(`${walDbPath}-wal`), true);

  const token = createTestToken(64);
  const cfg = createDefaultConfig(process.env, root);
  cfg.state.dir = join(root, 'state');
  cfg.state.logFile = join(root, 'state', 'bridge.log');
  cfg.adapter.type = 'antigravity';
  cfg.adapter.command = process.execPath;
  cfg.adapter.args = [FAKE_SERVER];
  cfg.adapter.fallbackCwd = root;
  cfg.adapter.antigravity.dataDirs = [agyDir, agyWalDir];

  const store = new StateStore({ stateDir: cfg.state.dir });
  store.recordCreated({ sessionId: 's-parent', cwd: root });
  store.recordCreated({ sessionId: 's-cap', cwd: root });
  store.recordCreated({ sessionId: 's-wal', cwd: root });
  store.recordCreated({ sessionId: 's-gone-disk', cwd: root, title: 'Missing On Disk' });

  const logger = new SanitizedLogger({ logFile: cfg.state.logFile, redactSecrets: [token] });
  const adapter = new AntigravityAdapter({ adapterConfig: cfg.adapter, syncConfig: cfg.sync, logger });
  const gw = new NonlocalGateway({
    config: cfg,
    transport: new WsServerTransport({
      host: '127.0.0.1',
      port: 0,
      allowNonLoopback: false,
      expectedToken: token,
      maxFrameBytes: cfg.server.maxFrameBytes,
      pingIntervalMs: 25000,
      pongTimeoutMs: 60000,
      rateLimit: cfg.security.rateLimit,
      getHealthState: () => ({ childAlive: adapter.isHealthy(), activeClient: true }),
      logger,
    }),
    adapter,
    store,
    logger,
  });

  const prevMode = process.env.FAKE_ACP_MODE;
  try {
    const { port } = await gw.start();
    const c = await connectWs(`ws://127.0.0.1:${port}/acp`, token);

    // Depth 8 & cycle-safe BFS
    c.sendJson({ jsonrpc: '2.0', id: 1, method: 'nonlocal/session_info', params: { sessionId: 's-parent' } });
    const info1 = await c.waitFor((m) => m.id === 1);
    assert.equal(info1.result.upstreamTitle, 'Title s-parent');
    assert.equal(info1.result.subagents.length, 8);
    assert.equal(info1.result.subagents[7].depth, 8);
    assert.equal(existsSync(`${cleanDbPath}-wal`), false, 'immutable read must create ZERO -wal sidecar');
    assert.equal(existsSync(`${cleanDbPath}-shm`), false, 'immutable read must create ZERO -shm sidecar');

    // Max 100 subagents cap
    c.sendJson({ jsonrpc: '2.0', id: 2, method: 'nonlocal/session_info', params: { sessionId: 's-cap' } });
    const infoCap = await c.waitFor((m) => m.id === 2);
    assert.equal(infoCap.result.subagents.length, 100);

    // Uncheckpointed WAL frame visible via nonlocal/session_info
    c.sendJson({ jsonrpc: '2.0', id: 3, method: 'nonlocal/session_info', params: { sessionId: 's-wal' } });
    const infoWal = await c.waitFor((m) => m.id === 3);
    assert.equal(infoWal.result.upstreamTitle, 'Initial WAL');
    assert.equal(infoWal.result.subagents[0].sessionId, 'sub-wal');

    // Wake failure when session is missing on disk evicts session and pushes nonlocal/session_deleted
    c.sendJson({ jsonrpc: '2.0', id: 4, method: 'nonlocal/sync', params: {} });
    await c.waitFor((m) => m.id === 4);
    process.env.FAKE_ACP_MODE = 'missing_on_load';
    c.sendJson({ jsonrpc: '2.0', id: 5, method: 'session/prompt', params: { sessionId: 's-gone-disk', prompt: [{ type: 'text', text: 'hi' }] } });
    const failWake = await c.waitFor((m) => m.id === 5);
    assert.equal(failWake.error.code, -32602);
    const delNotif = await c.waitFor((m) => m.method === 'nonlocal/session_deleted' && m.params?.sessionId === 's-gone-disk');
    assert.equal(delNotif.params.sessionId, 's-gone-disk');
    assert.equal(store.has('s-gone-disk'), false);

    // Also verify diskPresence returns true when only .pb exists
    writeFileSync(join(agyDir, 'conversations', 'pb-only.pb'), 'pb');
    assert.equal(adapter.checkSessionDiskPresence('pb-only'), true);

    c.close();
    await c.waitForClose();
  } finally {
    if (prevMode === undefined) delete process.env.FAKE_ACP_MODE;
    else process.env.FAKE_ACP_MODE = prevMode;
    try {
      walWriter.close();
    } catch {
      // ignore
    }
    await gw.stop();
    rmTempDir(root);
  }
});
