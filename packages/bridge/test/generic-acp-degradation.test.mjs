import test from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createDefaultConfig } from '../dist/config/schema.js';
import { BaseAcpAdapter } from '../dist/adapter/base-acp-adapter.js';
import { WsServerTransport } from '../dist/transport/ws-server-transport.js';
import { NonlocalGateway } from '../dist/gateway/gateway.js';
import { StateStore } from '../dist/store/state-store.js';
import { SanitizedLogger } from '../dist/log/logger.js';
import { connectWs } from './helpers/ws-client.mjs';
import { createTestToken, makeTempDir, rmTempDir } from './helpers/test-utils.mjs';

const FAKE_SERVER = fileURLToPath(new URL('./helpers/fake-acp-server.mjs', import.meta.url));

test('AC-39: generic-acp graceful capability degradation (-32601/-32024, core ACP & remote FS work, missing-command fail-closed) (PP-39-degrade)', async () => {
  const root = makeTempDir('nonlocal-generic-ac39-');
  const token = createTestToken(64);
  const cfg = createDefaultConfig(process.env, root);
  cfg.state.dir = join(root, 'state');
  cfg.state.logFile = join(root, 'state', 'bridge.log');
  cfg.adapter.type = 'generic-acp';
  cfg.adapter.command = process.execPath;
  cfg.adapter.args = [FAKE_SERVER];
  cfg.adapter.fallbackCwd = root;

  const store = new StateStore({ stateDir: cfg.state.dir });
  const logger = new SanitizedLogger({ logFile: cfg.state.logFile, redactSecrets: [token] });
  const adapter = new BaseAcpAdapter({ adapterConfig: cfg.adapter, syncConfig: cfg.sync, logger });
  assert.deepEqual(adapter.capabilities, {
    usage: false,
    sessionInfo: false,
    deleteSession: false,
    diskPresence: false,
  });

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

  // Also verify missing command fails closed cleanly without crash
  const cfgNoCmd = createDefaultConfig(process.env, root);
  cfgNoCmd.state.dir = join(root, 'state-nocmd');
  cfgNoCmd.state.logFile = join(root, 'state-nocmd', 'bridge.log');
  cfgNoCmd.adapter.type = 'generic-acp';
  cfgNoCmd.adapter.command = '';
  const noCmdAdapter = new BaseAcpAdapter({
    adapterConfig: cfgNoCmd.adapter,
    syncConfig: cfgNoCmd.sync,
    logger: new SanitizedLogger({ logFile: cfgNoCmd.state.logFile }),
  });
  const gwNoCmd = new NonlocalGateway({
    config: cfgNoCmd,
    transport: new WsServerTransport({
      host: '127.0.0.1',
      port: 0,
      allowNonLoopback: false,
      expectedToken: token,
      maxFrameBytes: cfgNoCmd.server.maxFrameBytes,
      pingIntervalMs: 25000,
      pongTimeoutMs: 60000,
      rateLimit: cfgNoCmd.security.rateLimit,
      getHealthState: () => ({ childAlive: false, activeClient: true }),
    }),
    adapter: noCmdAdapter,
    store: new StateStore({ stateDir: cfgNoCmd.state.dir }),
    logger: new SanitizedLogger({ logFile: cfgNoCmd.state.logFile }),
  });

  try {
    const { port } = await gw.start();
    const c = await connectWs(`ws://127.0.0.1:${port}/acp`, token);

    // Core ACP works
    c.sendJson({ jsonrpc: '2.0', id: 1, method: 'session/new', params: { cwd: root, forcedId: 's-gen' } });
    const rNew = await c.waitFor((m) => m.id === 1);
    assert.equal(rNew.result.sessionId, 's-gen');
    c.sendJson({ jsonrpc: '2.0', id: 2, method: 'session/prompt', params: { sessionId: 's-gen', prompt: [{ type: 'text', text: 'hello' }] } });
    assert.equal((await c.waitFor((m) => m.id === 2)).result.stopReason, 'end_turn');

    // Remote FS (list & read_file) & rename work cleanly in generic-acp mode
    c.sendJson({ jsonrpc: '2.0', id: 3, method: 'nonlocal/fs_list', params: { cwd: root } });
    const fsRes = await c.waitFor((m) => m.id === 3);
    assert.ok(Array.isArray(fsRes.result.entries));

    const { writeFileSync } = await import('node:fs');
    const readmeSample = join(root, 'sample.txt');
    writeFileSync(readmeSample, 'hello generic-acp', 'utf8');
    c.sendJson({ jsonrpc: '2.0', id: 31, method: 'nonlocal/fs_read_file', params: { path: readmeSample } });
    assert.equal((await c.waitFor((m) => m.id === 31)).result.content, 'hello generic-acp');

    c.sendJson({ jsonrpc: '2.0', id: 32, method: 'nonlocal/rename_session', params: { sessionId: 's-gen', title: 'Generic Renamed' } });
    assert.equal((await c.waitFor((m) => m.id === 32)).result.title, 'Generic Renamed');

    // Antigravity-only RPCs degrade cleanly with JSON-RPC error (-32601 Method not found)
    c.sendJson({ jsonrpc: '2.0', id: 4, method: 'nonlocal/usage', params: {} });
    assert.equal((await c.waitFor((m) => m.id === 4)).error.code, -32601);

    c.sendJson({ jsonrpc: '2.0', id: 5, method: 'nonlocal/session_info', params: { sessionId: 's-gen' } });
    assert.equal((await c.waitFor((m) => m.id === 5)).error.code, -32601);

    c.sendJson({ jsonrpc: '2.0', id: 6, method: 'nonlocal/delete_session', params: { sessionId: 's-gen' } });
    assert.equal((await c.waitFor((m) => m.id === 6)).error.code, -32601);

    // Bridge stays connected
    c.sendJson({ jsonrpc: '2.0', id: 7, method: 'nonlocal/sync', params: {} });
    assert.ok((await c.waitFor((m) => m.id === 7)).result.instanceId);
    c.close();
    await c.waitForClose();

    const { port: p2 } = await gwNoCmd.start();
    const c2 = await connectWs(`ws://127.0.0.1:${p2}/acp`, token);
    c2.sendJson({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: 1 } });
    const failInit = await c2.waitFor((m) => m.id === 1);
    assert.equal(failInit.error.code, -32603);
    c2.close();
    await c2.waitForClose();
  } finally {
    await gw.stop();
    await gwNoCmd.stop();
    rmTempDir(root);
  }
});

test('AC-39 (diskless external deletion): seen_in_upstream_list/seen_on_disk 2-miss eviction while sparing unseen, paginated, watch, and other-cwd sessions', async () => {
  const { FakeTestAdapter } = await import('./helpers/fake-adapter.mjs');
  const root = makeTempDir('nonlocal-nodisk-ac39-');
  const dirA = makeTempDir('nonlocal-nodisk-dirA-');
  const dirB = makeTempDir('nonlocal-nodisk-dirB-');
  const token = createTestToken(64);
  const cfg = createDefaultConfig(process.env, root);
  cfg.state.dir = join(root, 'state');
  cfg.state.logFile = join(root, 'state', 'bridge.log');

  const store = new StateStore({ stateDir: cfg.state.dir });
  const logger = new SanitizedLogger({ logFile: cfg.state.logFile, redactSecrets: [token] });
  const adapter = new FakeTestAdapter({
    type: 'generic-acp',
    capabilities: { usage: false, sessionInfo: false, deleteSession: false, diskPresence: false },
    onDispatch: async (req, self) => {
      if (req.method === 'session/list') {
        self.host.onAdapterMessage({
          kind: 'response',
          connId: req.connId,
          clientReqId: req.clientReqId,
          method: req.method,
          canonicalCwd: req.rawMessage.params.cwd || null,
          message: { jsonrpc: '2.0', id: req.clientReqId, result: { sessions: [] } },
        });
      }
    },
  });

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
      getHealthState: () => ({ childAlive: true, activeClient: true }),
      logger,
    }),
    adapter,
    store,
    logger,
  });

  try {
    store.recordCreated({ sessionId: 'S1', cwd: dirA, title: 'Seen Upstream' });
    store.markSeenInUpstreamList('S1');
    store.recordCreated({ sessionId: 'S2', cwd: dirA, title: 'Seen On Disk' });
    store.markSeenOnDisk('S2');
    store.recordCreated({ sessionId: 'S3', cwd: dirA, title: 'Never Seen (spared)' });

    const { port } = await gw.start();
    const c = await connectWs(`ws://127.0.0.1:${port}/acp`, token);
    c.sendJson({ jsonrpc: '2.0', id: 1, method: 'nonlocal/sync', params: {} });
    await c.waitFor((m) => m.id === 1);

    // 1. Background watch event must NOT increment miss counter
    adapter.host.onBackgroundSessionList({ sessions: [], requestedCwd: dirA, isWatch: true, hasCursor: false, hasNextCursor: false });
    // 2. Paginated (cursor) list must NOT increment miss counter
    c.sendJson({ jsonrpc: '2.0', id: 2, method: 'session/list', params: { cwd: dirA, cursor: 'page-2' } });
    await c.waitFor((m) => m.id === 2);
    // 3. Different cwd list must NOT increment miss counter for dirA
    c.sendJson({ jsonrpc: '2.0', id: 3, method: 'session/list', params: { cwd: dirB } });
    await c.waitFor((m) => m.id === 3);
    assert.equal(store.has('S1'), true);
    assert.equal(store.has('S2'), true);

    // 4. First matching same-cwd non-paginated empty list (miss #1) -> still kept!
    c.sendJson({ jsonrpc: '2.0', id: 4, method: 'session/list', params: { cwd: dirA } });
    await c.waitFor((m) => m.id === 4);
    assert.equal(store.has('S1'), true);
    assert.equal(store.has('S2'), true);

    // 5. Second matching same-cwd non-paginated empty list (miss #2) -> S1 & S2 evicted + nonlocal/session_deleted; S3 spared!
    c.sendJson({ jsonrpc: '2.0', id: 5, method: 'session/list', params: { cwd: dirA } });
    await c.waitFor((m) => m.id === 5);
    await c.waitFor((m) => m.method === 'nonlocal/session_deleted' && m.params?.sessionId === 'S1');
    await c.waitFor((m) => m.method === 'nonlocal/session_deleted' && m.params?.sessionId === 'S2');
    assert.equal(store.has('S1'), false);
    assert.equal(store.has('S2'), false);
    assert.equal(store.has('S3'), true);

    c.close();
    await c.waitForClose();
  } finally {
    await gw.stop();
    rmTempDir(root);
    rmTempDir(dirA);
    rmTempDir(dirB);
  }
});
