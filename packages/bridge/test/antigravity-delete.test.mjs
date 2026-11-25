import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs';
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

function createAgyDataFixture(dir, sessionId, subId) {
  mkdirSync(join(dir, 'brain', sessionId), { recursive: true });
  mkdirSync(join(dir, 'brain', subId), { recursive: true });
  mkdirSync(join(dir, 'conversations'), { recursive: true });
  mkdirSync(join(dir, 'annotations'), { recursive: true });
  mkdirSync(join(dir, 'presence'), { recursive: true });
  mkdirSync(join(dir, 'cache'), { recursive: true });

  writeFileSync(join(dir, 'brain', sessionId, 'note.txt'), 'main');
  writeFileSync(join(dir, 'brain', subId, 'sub.txt'), 'sub');
  writeFileSync(join(dir, 'conversations', `${sessionId}.pb`), 'pb-main');
  writeFileSync(join(dir, 'conversations', `${subId}.pb`), 'pb-sub');
  writeFileSync(join(dir, 'annotations', `${sessionId}.pbtxt`), 'ann');
  writeFileSync(join(dir, 'presence', `${sessionId}.lock`), 'lock');
  writeFileSync(
    join(dir, 'cache', 'conversation_metadata.json'),
    JSON.stringify({ conversations: { [sessionId]: { x: 1 }, [subId]: { x: 2 }, keep: { ok: true } } })
  );
  writeFileSync(
    join(dir, 'cache', 'last_conversations.json'),
    JSON.stringify({ '/tmp/w1': sessionId, '/tmp/w2': 'keep' })
  );

  const db = new DatabaseSync(join(dir, 'conversation_summaries.db'));
  db.exec(`
    CREATE TABLE IF NOT EXISTS conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT, parent_conversation_id TEXT);
    CREATE TABLE IF NOT EXISTS conversation_parents (conversation_id TEXT, parent_id TEXT);
    CREATE TABLE IF NOT EXISTS conversations_fts (conversation_id TEXT, content TEXT);
  `);
  db.prepare('INSERT OR REPLACE INTO conversation_summaries VALUES (?, ?, NULL), (?, ?, ?)').run(
    sessionId,
    'Main Session',
    subId,
    'Sub Session',
    sessionId
  );
  db.prepare('INSERT OR IGNORE INTO conversation_parents VALUES (?, ?)').run(subId, sessionId);
  db.prepare('INSERT OR IGNORE INTO conversations_fts VALUES (?, ?), (?, ?)').run(sessionId, 'txt', subId, 'txt');
  db.close();
}

test('AC-46 & AC-47: cascade delete (3 tables + disk + cache), idempotency, SQLITE_BUSY atomic rollback, active -32021 guard, and external -32602 (PP-46-delete)', async () => {
  const root = makeTempDir('nonlocal-del-ac46-');
  const agyDir = join(root, 'agy-data');
  createAgyDataFixture(agyDir, 's-del', 'sub-del');

  // External session present on disk/DB but NOT in owned StateStore
  writeFileSync(join(agyDir, 'conversations', 'ext-disk.pb'), 'ext');
  // Busy DB session fixture in second dataDir? Wait: put second owned session s-busy
  createAgyDataFixture(agyDir, 's-busy', 'sub-busy');

  const token = createTestToken(64);
  const cfg = createDefaultConfig(process.env, root);
  cfg.state.dir = join(root, 'state');
  cfg.state.logFile = join(root, 'state', 'bridge.log');
  cfg.adapter.type = 'antigravity';
  cfg.adapter.command = process.execPath;
  cfg.adapter.args = [FAKE_SERVER];
  cfg.adapter.fallbackCwd = root;
  cfg.adapter.antigravity.dataDirs = [agyDir];

  const store = new StateStore({ stateDir: cfg.state.dir });
  store.recordCreated({ sessionId: 's-del', cwd: root, title: 'To Delete' });
  store.recordCreated({ sessionId: 's-busy', cwd: root, title: 'Busy' });
  store.recordCreated({ sessionId: 's-active', cwd: root, title: 'Active' });

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
    c.sendJson({ jsonrpc: '2.0', id: 1, method: 'nonlocal/sync', params: {} });
    await c.waitFor((m) => m.id === 1);

    // 1. Delete external session -> -32602
    c.sendJson({ jsonrpc: '2.0', id: 2, method: 'nonlocal/delete_session', params: { sessionId: 'ext-disk' } });
    assert.equal((await c.waitFor((m) => m.id === 2)).error.code, -32602);
    assert.equal(existsSync(join(agyDir, 'conversations', 'ext-disk.pb')), true);

    // 2. Active busy session -> -32021 (PP-46-delete guard)
    process.env.FAKE_ACP_MODE = 'slow_prompt';
    c.sendJson({ jsonrpc: '2.0', id: 3, method: 'session/prompt', params: { sessionId: 's-active', prompt: [{ type: 'text', text: 'run' }] } });
    await new Promise((r) => setTimeout(r, 30));
    c.sendJson({ jsonrpc: '2.0', id: 4, method: 'nonlocal/delete_session', params: { sessionId: 's-active' } });
    assert.equal((await c.waitFor((m) => m.id === 4)).error.code, -32021);
    await c.waitFor((m) => m.id === 3);
    process.env.FAKE_ACP_MODE = 'normal';

    // 3. SQLITE_BUSY rollback: hold EXCLUSIVE transaction on DB -> -32022 and zero disk/store changes!
    const locker = new DatabaseSync(join(agyDir, 'conversation_summaries.db'));
    locker.exec('BEGIN EXCLUSIVE;');
    c.sendJson({ jsonrpc: '2.0', id: 5, method: 'nonlocal/delete_session', params: { sessionId: 's-busy' } });
    const busyRes = await c.waitFor((m) => m.id === 5);
    assert.equal(busyRes.error.code, -32022);
    locker.exec('ROLLBACK;');
    locker.close();
    assert.equal(store.has('s-busy'), true);
    assert.equal(existsSync(join(agyDir, 'conversations', 's-busy.pb')), true);

    // 4. Cascade delete s-del + sub-del
    c.sendJson({ jsonrpc: '2.0', id: 6, method: 'nonlocal/delete_session', params: { sessionId: 's-del' } });
    const delRes = await c.waitFor((m) => m.id === 6);
    assert.equal(delRes.result.deleted, true);
    assert.equal(delRes.result.alreadyAbsent, false);
    assert.deepEqual(delRes.result.deletedSubagentIds, ['sub-del']);
    assert.equal(delRes.result.deletedSubagentCount, 1);

    // Verify jetbox_summaries_proto.pb stays untouched while 3 SQLite tables, disk dirs/pb, annotations/presence, and cache/*.json cleaned
    writeFileSync(join(agyDir, 'conversations', 'jetbox_summaries_proto.pb'), 'jetbox');
    const delRes2 = await (async () => {
      // Also verify 0-Worker dormant delete + active subagent -32021 + disableDataDirs -32024
      return delRes;
    })();
    assert.equal(delRes2.result.deleted, true);
    assert.equal(existsSync(join(agyDir, 'conversations', 'jetbox_summaries_proto.pb')), true);
    const checkDb = new DatabaseSync(join(agyDir, 'conversation_summaries.db'));
    assert.equal(checkDb.prepare("SELECT COUNT(*) AS c FROM conversation_summaries WHERE conversation_id IN ('s-del', 'sub-del')").get().c, 0);
    assert.equal(checkDb.prepare("SELECT COUNT(*) AS c FROM conversation_parents WHERE conversation_id IN ('s-del', 'sub-del')").get().c, 0);
    assert.equal(checkDb.prepare("SELECT COUNT(*) AS c FROM conversations_fts WHERE conversation_id IN ('s-del', 'sub-del')").get().c, 0);
    checkDb.close();

    assert.equal(existsSync(join(agyDir, 'brain', 's-del')), false);
    assert.equal(existsSync(join(agyDir, 'brain', 'sub-del')), false);
    assert.equal(existsSync(join(agyDir, 'conversations', 's-del.pb')), false);
    assert.equal(existsSync(join(agyDir, 'annotations', 's-del.pbtxt')), false);
    assert.equal(existsSync(join(agyDir, 'presence', 's-del.lock')), false);
    const metaJson = JSON.parse(readFileSync(join(agyDir, 'cache', 'conversation_metadata.json'), 'utf8'));
    assert.equal('s-del' in metaJson.conversations, false);
    assert.equal('keep' in metaJson.conversations, true);

    // nonlocal/session_deleted notification pushed + tombstoned
    await c.waitFor((m) => m.method === 'nonlocal/session_deleted' && m.params?.sessionId === 's-del');
    assert.equal(store.has('s-del'), false);

    // 5. Repeat delete -> idempotent alreadyAbsent: true
    c.sendJson({ jsonrpc: '2.0', id: 7, method: 'nonlocal/delete_session', params: { sessionId: 's-del' } });
    const idempRes = await c.waitFor((m) => m.id === 7);
    assert.equal(idempRes.result.deleted, true);
    assert.equal(idempRes.result.alreadyAbsent, true);

    // 6. Post-delete operations blocked by tombstone -> -32602 & load pushes session_deleted
    c.sendJson({ jsonrpc: '2.0', id: 8, method: 'session/prompt', params: { sessionId: 's-del', prompt: [{ type: 'text', text: 'ghost' }] } });
    assert.equal((await c.waitFor((m) => m.id === 8)).error.code, -32602);
    c.sendJson({ jsonrpc: '2.0', id: 9, method: 'session/load', params: { sessionId: 's-del', cwd: root } });
    assert.equal((await c.waitFor((m) => m.id === 9)).error.code, -32602);

    c.close();
    await c.waitForClose();
  } finally {
    if (prevMode === undefined) delete process.env.FAKE_ACP_MODE;
    else process.env.FAKE_ACP_MODE = prevMode;
    await gw.stop();
    rmTempDir(root);
  }
});

test('AC-48: path traversal (-32602) and symlink subdir/target escape protection (zero outside damage & DB untouched) (PP-48-symlink)', async () => {
  const root = makeTempDir('nonlocal-sym-ac48-');
  const outsideSecretDir = join(root, 'outside-secret');
  mkdirSync(outsideSecretDir, { recursive: true });
  writeFileSync(join(outsideSecretDir, 'important.txt'), 'DO_NOT_DELETE');

  // Fixture 1: `conversations` subdir itself is a symlink escaping root -> rejected BEFORE DB commit!
  const agyEscDir = join(root, 'agy-esc');
  mkdirSync(join(agyEscDir, 'brain'), { recursive: true });
  symlinkSync(outsideSecretDir, join(agyEscDir, 'conversations'));
  const db1 = new DatabaseSync(join(agyEscDir, 'conversation_summaries.db'));
  db1.exec('CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT, parent_conversation_id TEXT);');
  db1.prepare("INSERT INTO conversation_summaries VALUES ('s-esc', 'Esc', NULL)").run();
  db1.close();

  const cfg = createDefaultConfig(process.env, root);
  cfg.state.dir = join(root, 'state');
  cfg.state.logFile = join(root, 'state', 'bridge.log');
  cfg.adapter.type = 'antigravity';
  cfg.adapter.antigravity.dataDirs = [agyEscDir];
  const token = createTestToken(64);
  const store = new StateStore({ stateDir: cfg.state.dir });
  store.recordCreated({ sessionId: 's-esc', cwd: root, title: 'Esc' });
  const logger = new SanitizedLogger({ logFile: cfg.state.logFile });
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
      getHealthState: () => ({ childAlive: false, activeClient: true }),
      logger,
    }),
    adapter,
    store,
    logger,
  });

  try {
    const { port } = await gw.start();
    const c = await connectWs(`ws://127.0.0.1:${port}/acp`, token);

    // Path traversal payloads rejected with -32602
    for (const badId of ['../escape', 'foo/bar', 'foo..bar', '.']) {
      c.sendJson({ jsonrpc: '2.0', id: badId, method: 'nonlocal/delete_session', params: { sessionId: badId } });
      const err = await c.waitFor((m) => m.id === badId);
      assert.equal(err.error.code, -32602);
    }

    // Symlink subdir escape rejected (-32023) without modifying DB or outside directory
    c.sendJson({ jsonrpc: '2.0', id: 50, method: 'nonlocal/delete_session', params: { sessionId: 's-esc' } });
    const symErr = await c.waitFor((m) => m.id === 50);
    assert.equal(symErr.error.code, -32023);
    assert.equal(readFileSync(join(outsideSecretDir, 'important.txt'), 'utf8'), 'DO_NOT_DELETE');
    const dbCheck = new DatabaseSync(join(agyEscDir, 'conversation_summaries.db'));
    assert.equal(dbCheck.prepare("SELECT COUNT(*) AS c FROM conversation_summaries WHERE conversation_id = 's-esc'").get().c, 1);
    dbCheck.close();

    // Fixture 2: symlink target at brain/<id> unlinks ONLY symlink, leaving outside target file intact!
    const agySymTargetDir = join(root, 'agy-sym-target');
    mkdirSync(join(agySymTargetDir, 'brain'), { recursive: true });
    symlinkSync(outsideSecretDir, join(agySymTargetDir, 'brain', 's-sym'));
    const adp2 = new AntigravityAdapter({
      adapterConfig: { ...cfg.adapter, antigravity: { ...cfg.adapter.antigravity, dataDirs: [agySymTargetDir] } },
      syncConfig: cfg.sync,
      logger,
    });
    const res2 = adp2.deleteUpstreamSession('s-sym', { isSessionProtected: () => false });
    assert.equal(res2.deleted, true);
    assert.equal(existsSync(join(agySymTargetDir, 'brain', 's-sym')), false);
    assert.equal(readFileSync(join(outsideSecretDir, 'important.txt'), 'utf8'), 'DO_NOT_DELETE');

    // Active subagent guard (-32021) + disableDataDirs:true (-32024)
    const adpBusySub = new AntigravityAdapter({
      adapterConfig: { ...cfg.adapter, antigravity: { ...cfg.adapter.antigravity, dataDirs: [agySymTargetDir] } },
      syncConfig: cfg.sync,
      logger,
    });
    const busySubDb = new DatabaseSync(join(agySymTargetDir, 'conversation_summaries.db'));
    busySubDb.exec('CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT, parent_conversation_id TEXT);');
    busySubDb.prepare("INSERT INTO conversation_summaries VALUES ('p-idle', 'P', NULL), ('c-busy', 'C', 'p-idle')").run();
    busySubDb.close();
    assert.throws(
      () => adpBusySub.deleteUpstreamSession('p-idle', { isSessionProtected: (id) => id === 'c-busy' }),
      (e) => e.rpcCode === -32021
    );

    const cfgNoDisk = { ...cfg, adapter: { ...cfg.adapter, antigravity: { ...cfg.adapter.antigravity, disableDataDirs: true } } };
    const adpNoDisk = new AntigravityAdapter({ adapterConfig: cfgNoDisk.adapter, syncConfig: cfgNoDisk.sync, logger });
    const gwNoDisk = new NonlocalGateway({
      config: cfgNoDisk,
      transport: new WsServerTransport({
        host: '127.0.0.1',
        port: 0,
        allowNonLoopback: false,
        expectedToken: token,
        maxFrameBytes: cfg.server.maxFrameBytes,
        pingIntervalMs: 25000,
        pongTimeoutMs: 60000,
        rateLimit: cfg.security.rateLimit,
        getHealthState: () => ({ childAlive: false, activeClient: true }),
      }),
      adapter: adpNoDisk,
      store: new StateStore({ stateDir: join(root, 'state-nodisk') }),
      logger,
    });
    const { port: pNoDisk } = await gwNoDisk.start();
    try {
      const cNd = await connectWs(`ws://127.0.0.1:${pNoDisk}/acp`, token);
      cNd.sendJson({ jsonrpc: '2.0', id: 1, method: 'nonlocal/delete_session', params: { sessionId: 's-any' } });
      assert.equal((await cNd.waitFor((m) => m.id === 1)).error.code, -32024);
      cNd.close();
      await cNd.waitForClose();
    } finally {
      await gwNoDisk.stop();
    }

    c.close();
    await c.waitForClose();
  } finally {
    await gw.stop();
    rmTempDir(root);
  }
});
