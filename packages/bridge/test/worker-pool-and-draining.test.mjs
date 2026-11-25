import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, readFileSync, realpathSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createDefaultConfig } from '../dist/config/schema.js';
import { BaseAcpAdapter, scheduleLongTimeout } from '../dist/adapter/base-acp-adapter.js';
import { WsServerTransport } from '../dist/transport/ws-server-transport.js';
import { NonlocalGateway } from '../dist/gateway/gateway.js';
import { StateStore } from '../dist/store/state-store.js';
import { SanitizedLogger } from '../dist/log/logger.js';
import { connectWs } from './helpers/ws-client.mjs';
import { createTestToken, makeTempDir, rmTempDir } from './helpers/test-utils.mjs';

const FAKE_SERVER = fileURLToPath(new URL('./helpers/fake-acp-server.mjs', import.meta.url));

test('AC-32: per-cwd worker pool isolation, symlink cwd canonicalization, missing cwd -32602, and cached initialize replay (PP-32-pool)', async () => {
  const root = makeTempDir('nonlocal-pool-ac32-');
  const dirA = makeTempDir('nonlocal-dirA-');
  const dirB = makeTempDir('nonlocal-dirB-');
  const symLinkB = join(root, 'link-to-B');
  const { symlinkSync } = await import('node:fs');
  symlinkSync(dirB, symLinkB);
  chmodSync(FAKE_SERVER, 0o755);

  const token = createTestToken(64);
  const cfg = createDefaultConfig(process.env, root);
  cfg.state.dir = join(root, 'state');
  cfg.state.logFile = join(root, 'state', 'bridge.log');
  cfg.adapter.type = 'generic-acp';
  cfg.adapter.command = process.execPath;
  cfg.adapter.args = [FAKE_SERVER];
  cfg.adapter.fallbackCwd = root;

  const acpLogFile = join(root, 'acp-events.jsonl');
  const prevLog = process.env.FAKE_ACP_LOG;
  const prevMode = process.env.FAKE_ACP_MODE;
  process.env.FAKE_ACP_LOG = acpLogFile;
  process.env.FAKE_ACP_MODE = 'already_init_on_replay';

  const store = new StateStore({ stateDir: cfg.state.dir });
  const logger = new SanitizedLogger({ logFile: cfg.state.logFile, redactSecrets: [token] });
  const adapter = new BaseAcpAdapter({ adapterConfig: cfg.adapter, syncConfig: cfg.sync, logger });
  const transport = new WsServerTransport({
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
  });
  const gateway = new NonlocalGateway({ config: cfg, transport, adapter, store, logger });

  try {
    const { port } = await gateway.start();
    // Cold start must have ZERO workers & dormant session/cancel returns {} without spawning
    assert.equal(adapter.isHealthy(), false);
    store.recordCreated({ sessionId: 's-dormant', cwd: dirA, title: 'Dormant' });
    const c = await connectWs(`ws://127.0.0.1:${port}/acp`, token);
    c.sendJson({ jsonrpc: '2.0', id: 90, method: 'session/cancel', params: { sessionId: 's-dormant' } });
    assert.deepEqual((await c.waitFor((m) => m.id === 90)).result, {});
    c.sendJson({ jsonrpc: '2.0', method: 'session/cancel', params: { sessionId: 's-dormant' } });
    assert.equal(adapter.isHealthy(), false, 'dormant session/cancel must NOT spawn worker');

    // 1. Initialize once on fallback worker
    c.sendJson({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: 1, clientInfo: { name: 'ios-app' } } });
    const initRes = await c.waitFor((m) => m.id === 1);
    assert.ok(initRes.result);

    // 2. Missing cwd -> -32602 without spawning worker
    c.sendJson({ jsonrpc: '2.0', id: 2, method: 'session/new', params: { cwd: join(root, 'does-not-exist') } });
    const errRes = await c.waitFor((m) => m.id === 2);
    assert.equal(errRes.error.code, -32602);

    // 3. session/new in dirA, dirB, and symlink-to-dirB -> only 2 cwd workers (dirB & symlink share worker!)
    c.sendJson({ jsonrpc: '2.0', id: 3, method: 'session/new', params: { cwd: dirA, forcedId: 'sA' } });
    await c.waitFor((m) => m.id === 3);
    c.sendJson({ jsonrpc: '2.0', id: 4, method: 'session/new', params: { cwd: dirB, forcedId: 'sB1' } });
    await c.waitFor((m) => m.id === 4);
    c.sendJson({ jsonrpc: '2.0', id: 5, method: 'session/new', params: { cwd: symLinkB, forcedId: 'sB2' } });
    const resB2 = await c.waitFor((m) => m.id === 5);
    assert.equal(resB2.result.cwd, realpathSync(dirB));

    // Verify sB1 and sB2 share same worker PID & initialize was replayed onto worker
    c.sendJson({ jsonrpc: '2.0', id: 6, method: 'session/prompt', params: { sessionId: 'sB1', prompt: [{ type: 'text', text: 'hi' }] } });
    const pB1 = await c.waitFor((m) => m.id === 6);
    c.sendJson({ jsonrpc: '2.0', id: 7, method: 'session/prompt', params: { sessionId: 'sB2', prompt: [{ type: 'text', text: 'hi' }] } });
    const pB2 = await c.waitFor((m) => m.id === 7);
    assert.equal(pB1.result.workerTag, pB2.result.workerTag);

    c.sendJson({ jsonrpc: '2.0', id: 8, method: 'session/prompt', params: { sessionId: 'sA', prompt: [{ type: 'text', text: 'hi' }] } });
    const pA = await c.waitFor((m) => m.id === 8);
    assert.notEqual(pA.result.workerTag, pB1.result.workerTag);

    const events = readFileSync(acpLogFile, 'utf8')
      .trim()
      .split('\n')
      .map((l) => JSON.parse(l));
    const initEvents = events.filter((e) => e.method === 'initialize');
    assert.ok(initEvents.length >= 3, 'initialize must replay to dirA and dirB workers');
    const uniqueCwds = new Set(events.filter((e) => e.method === 'session/new').map((e) => realpathSync(e.cwd)));
    assert.equal(uniqueCwds.size, 2);

    c.close();
    await c.waitForClose();
  } finally {
    if (prevLog === undefined) delete process.env.FAKE_ACP_LOG;
    else process.env.FAKE_ACP_LOG = prevLog;
    if (prevMode === undefined) delete process.env.FAKE_ACP_MODE;
    else process.env.FAKE_ACP_MODE = prevMode;
    await gateway.stop();
    rmTempDir(root);
    rmTempDir(dirA);
    rmTempDir(dirB);
  }
});

test('AC-33 & AC-34: draining transparent 1x retry + scheduleLongTimeout >32-bit chunking & cancel (PP-33-drain, PP-34-timer)', async () => {
  // 1. PP-34-timer: scheduleLongTimeout with 1e12 ms (> 2^31-1 = 2,147,483,647) chains cleanly without 1ms clamp
  const recordedDelays = [];
  const fakeHandles = new Map();
  let nextTid = 1;
  const fakeSetTimeout = (fn, delay) => {
    recordedDelays.push(delay);
    const tid = nextTid++;
    fakeHandles.set(tid, fn);
    return { _tid: tid, unref() {} };
  };
  const fakeClearTimeout = (h) => {
    if (h?._tid) fakeHandles.delete(h._tid);
  };

  let fired = 0;
  const longDelay = 5_000_000_000; // > 2^31-1
  const h = scheduleLongTimeout(() => { fired += 1; }, longDelay, fakeSetTimeout, fakeClearTimeout);
  assert.equal(recordedDelays[0], 2_147_483_647, 'first timer slice must clamp at MAX_SETTIME_CHUNK_MS, not fire in 1ms');
  assert.equal(fired, 0);
  // Advance first slice
  const firstFn = fakeHandles.get(1);
  fakeHandles.delete(1);
  firstFn();
  assert.equal(fired, 0);
  assert.equal(recordedDelays[1], 2_147_483_647);
  // Cancel before remaining slices fire
  h.cancel();
  assert.equal(fakeHandles.size, 0);

  // Also test completion after full chain
  let completed = 0;
  const recorded2 = [];
  const handles2 = [];
  scheduleLongTimeout(
    () => { completed += 1; },
    2_147_483_647 + 500,
    (fn, d) => {
      recorded2.push(d);
      handles2.push(fn);
      return { fn, unref() {} };
    },
    () => {}
  );
  assert.deepEqual(recorded2, [2_147_483_647]);
  handles2[0]();
  assert.deepEqual(recorded2, [2_147_483_647, 500]);
  handles2[1]();
  assert.equal(completed, 1);

  // 2. AC-33 / PP-33-drain: draining worker causes transparent 1x retry onto newly spawned worker
  const root = makeTempDir('nonlocal-drain-ac33-');
  const token = createTestToken(64);
  const cfg = createDefaultConfig(process.env, root);
  cfg.state.dir = join(root, 'state');
  cfg.state.logFile = join(root, 'state', 'bridge.log');
  cfg.adapter.type = 'generic-acp';
  cfg.adapter.command = process.execPath;
  cfg.adapter.args = [FAKE_SERVER];
  cfg.adapter.fallbackCwd = root;
  cfg.adapter.childIdleTimeoutMs = 150;
  cfg.sync.loadSettleQuietMs = 10;
  cfg.sync.loadSettleMaxWaitMs = 50;

  const store = new StateStore({ stateDir: cfg.state.dir });
  const logger = new SanitizedLogger({ logFile: cfg.state.logFile, redactSecrets: [token] });
  const adapter = new BaseAcpAdapter({ adapterConfig: cfg.adapter, syncConfig: cfg.sync, logger });
  const transport = new WsServerTransport({
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
  });
  const gateway = new NonlocalGateway({ config: cfg, transport, adapter, store, logger });

  const prevMode = process.env.FAKE_ACP_MODE;
  const prevDelay = process.env.FAKE_ACP_DELAY_MS;
  try {
    const { port } = await gateway.start();
    const c = await connectWs(`ws://127.0.0.1:${port}/acp`, token);
    process.env.FAKE_ACP_MODE = 'slow_prompt';
    process.env.FAKE_ACP_DELAY_MS = '120';
    c.sendJson({ jsonrpc: '2.0', id: 1, method: 'session/new', params: { cwd: root, forcedId: 's-drain' } });
    const newRes = await c.waitFor((m) => m.id === 1);
    assert.equal(newRes.result.sessionId, 's-drain');

    const firstWorker = adapter['workers'].values().next().value;
    const oldPid = firstWorker.child.pid;

    // Start in-flight prompt, then trigger worker drain during execution -> retries 1x on fresh worker
    const promptPromise = c.waitFor((m) => m.id === 2);
    c.sendJson({
      jsonrpc: '2.0',
      id: 2,
      method: 'session/prompt',
      params: { sessionId: 's-drain', prompt: [{ type: 'text', text: 'during-drain' }] },
    });
    await new Promise((r) => setTimeout(r, 30));
    void adapter['terminateWorker'](firstWorker, 'test_drain');

    const retryRes = await promptPromise;
    assert.equal(retryRes.result.stopReason, 'end_turn');
    assert.notEqual(retryRes.result.workerTag, `pid-${oldPid}-cwd-${realpathSync(root)}`);
    assert.equal(readFileSync(cfg.state.logFile, 'utf8').includes('worker_draining_retry'), true);

    c.close();
    await c.waitForClose();
  } finally {
    if (prevMode === undefined) delete process.env.FAKE_ACP_MODE;
    else process.env.FAKE_ACP_MODE = prevMode;
    if (prevDelay === undefined) delete process.env.FAKE_ACP_DELAY_MS;
    else process.env.FAKE_ACP_DELAY_MS = prevDelay;
    await gateway.stop();
    rmTempDir(root);
  }
});
