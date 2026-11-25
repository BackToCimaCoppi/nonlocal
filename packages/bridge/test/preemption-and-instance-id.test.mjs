import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createDefaultConfig } from '../dist/config/schema.js';
import { WsServerTransport } from '../dist/transport/ws-server-transport.js';
import { NonlocalGateway } from '../dist/gateway/gateway.js';
import { StateStore } from '../dist/store/state-store.js';
import { SanitizedLogger } from '../dist/log/logger.js';
import { FakeTestAdapter } from './helpers/fake-adapter.mjs';
import { connectWs } from './helpers/ws-client.mjs';
import { createTestToken, makeTempDir, rmTempDir } from './helpers/test-utils.mjs';

test('AC-27: rapid 4001 preemption, same numeric id=7 late response drop (rpc_resp_dropped), no orphan replay, and turn_completed + sync (PP-27-preempt)', async () => {
  const root = makeTempDir('nonlocal-preempt-ac27-');
  const token = createTestToken(64);
  const cfg = createDefaultConfig(process.env, root);
  cfg.state.dir = join(root, 'state');
  cfg.state.logFile = join(root, 'state', 'bridge.log');

  const store = new StateStore({ stateDir: cfg.state.dir });
  const logger = new SanitizedLogger({ logFile: cfg.state.logFile, redactSecrets: [token] });

  let finishSlowPrompt = null;
  const adapter = new FakeTestAdapter({
    onDispatch: async (req, self) => {
      if (req.method === 'session/new') {
        self.loadedSessions.add('sess-p1');
        self.host.onAdapterMessage({
          kind: 'response',
          connId: req.connId,
          clientReqId: req.clientReqId,
          method: req.method,
          canonicalCwd: root,
          message: { jsonrpc: '2.0', id: req.clientReqId, result: { sessionId: 'sess-p1', cwd: root } },
        });
        return;
      }
      if (req.method === 'session/prompt') {
        self.host.onAdapterMessage({
          kind: 'notification',
          sessionId: req.sessionId,
          canonicalCwd: root,
          message: {
            jsonrpc: '2.0',
            method: 'session/update',
            params: {
              sessionId: req.sessionId,
              update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'streaming-' } },
            },
          },
        });
        finishSlowPrompt = () => {
          self.host.onAdapterMessage({
            kind: 'response',
            connId: req.connId,
            clientReqId: req.clientReqId,
            method: req.method,
            sessionId: req.sessionId,
            canonicalCwd: root,
            message: { jsonrpc: '2.0', id: req.clientReqId, result: { stopReason: 'end_turn' } },
          });
        };
        return;
      }
      if (req.method === 'session/list') {
        self.host.onAdapterMessage({
          kind: 'response',
          connId: req.connId,
          clientReqId: req.clientReqId,
          method: req.method,
          message: { jsonrpc: '2.0', id: req.clientReqId, result: { sessions: [] } },
        });
      }
    },
  });

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
    const url = `ws://127.0.0.1:${port}/acp`;

    const c1 = await connectWs(url, token);
    c1.sendJson({ jsonrpc: '2.0', id: 1, method: 'session/new', params: { cwd: root } });
    await c1.waitFor((m) => m.id === 1);

    // C1 starts slow session/prompt with numeric id=7
    c1.sendJson({
      jsonrpc: '2.0',
      id: 7,
      method: 'session/prompt',
      params: {
        sessionId: 'sess-p1',
        prompt: [{ type: 'text', text: 'hello' }],
        _meta: { nonlocalClientTurnId: 'ct-preempt-1' },
      },
    });
    await new Promise((r) => setTimeout(r, 30));

    // Rapid preemption: C2 -> C3 -> C4
    const c1CloseP = c1.waitForClose();
    const c2 = await connectWs(url, token);
    const c2CloseP = c2.waitForClose();
    const c3 = await connectWs(url, token);
    const c3CloseP = c3.waitForClose();

    // Unowned non-turn notification during gap must NOT replay to C4
    adapter.host.onAdapterMessage({
      kind: 'notification',
      message: { jsonrpc: '2.0', method: 'nonlocal/unowned_noise', params: { info: 'skip' } },
    });

    const c4 = await connectWs(url, token);
    const [r1, r2, r3] = await Promise.all([c1CloseP, c2CloseP, c3CloseP]);
    assert.equal(r1.code, 4001);
    assert.equal(r1.reason, 'preempted_by_new_connection');
    assert.equal(r2.code, 4001);
    assert.equal(r3.code, 4001);

    // C4 ALSO uses numeric id=7 for a fast request (session/list)
    c4.sendJson({ jsonrpc: '2.0', id: 7, method: 'session/list', params: {} });
    const c4Fast = await c4.waitFor((m) => m.id === 7);
    assert.ok(Array.isArray(c4Fast.result?.sessions), 'C4 id=7 must get its own fast session/list response');

    // Enable sync on C4 and release C1's slow prompt response
    c4.sendJson({ jsonrpc: '2.0', id: 8, method: 'nonlocal/sync', params: {} });
    const syncActive = await c4.waitFor((m) => m.id === 8);
    assert.equal(syncActive.result.sessions[0].latestTurn.status, 'active');
    assert.ok(syncActive.result.sessions[0].latestTurn.events.length >= 1);

    finishSlowPrompt();
    const turnDone = await c4.waitFor((m) => m.method === 'nonlocal/turn_completed');
    assert.equal(turnDone.params.sessionId, 'sess-p1');
    assert.equal(turnDone.params.status, 'completed');
    assert.equal(turnDone.params.clientTurnId, 'ct-preempt-1');
    assert.equal(turnDone.params.stopReason, 'end_turn');
    assert.ok(turnDone.params.instanceId);
    assert.ok(turnDone.params.turnId);

    // C4 must NOT receive C1's id=7 prompt response nor unowned_noise
    await new Promise((r) => setTimeout(r, 50));
    assert.equal(c4.messages.some((m) => m.id === 7), false);
    assert.equal(c4.messages.some((m) => m.method === 'nonlocal/unowned_noise'), false);

    // Final sync after turn completion
    c4.sendJson({ jsonrpc: '2.0', id: 9, method: 'nonlocal/sync', params: {} });
    const syncDone = await c4.waitFor((m) => m.id === 9);
    const evs = syncDone.result.sessions[0].latestTurn.events;
    assert.ok(evs.length >= 1);
    for (const ev of evs) {
      assert.deepEqual(Object.keys(ev).sort(), ['method', 'params', 'seq']);
      assert.equal(ev.method, 'session/update');
    }

    const logText = readFileSync(cfg.state.logFile, 'utf8');
    assert.equal(logText.includes('rpc_resp_dropped'), true);
    c4.close();
    await c4.waitForClose();
  } finally {
    await gateway.stop();
    rmTempDir(root);
  }
});

test('AC-28: instanceId remains strictly equal across single worker exit/eviction and only changes on full bridge restart (PP-28-instid)', async () => {
  const root = makeTempDir('nonlocal-inst-ac28-');
  const token = createTestToken(64);

  const startOne = async (port = 0) => {
    const cfg = createDefaultConfig(process.env, root);
    cfg.state.dir = join(root, 'state');
    cfg.state.logFile = join(root, 'state', 'bridge.log');
    const store = new StateStore({ stateDir: cfg.state.dir });
    const logger = new SanitizedLogger({ logFile: cfg.state.logFile, redactSecrets: [token] });
    const adapter = new FakeTestAdapter();
    const transport = new WsServerTransport({
      host: '127.0.0.1',
      port,
      allowNonLoopback: false,
      expectedToken: token,
      maxFrameBytes: cfg.server.maxFrameBytes,
      pingIntervalMs: 25000,
      pongTimeoutMs: 60000,
      rateLimit: cfg.security.rateLimit,
      getHealthState: () => ({ childAlive: adapter.isHealthy(), activeClient: false }),
      logger,
    });
    const gw = new NonlocalGateway({ config: cfg, transport, adapter, store, logger });
    const info = await gw.start();
    return { gw, adapter, port: info.port };
  };

  const b1 = await startOne(0);
  let inst1 = '';
  try {
    const c = await connectWs(`ws://127.0.0.1:${b1.port}/acp`, token);
    c.sendJson({ jsonrpc: '2.0', id: 1, method: 'nonlocal/sync', params: {} });
    inst1 = (await c.waitFor((m) => m.id === 1)).result.instanceId;
    assert.ok(inst1);

    // Simulate single worker idle eviction / crash exit
    b1.adapter.host.onWorkerExited(['s-worker-a']);
    b1.adapter.host.onWorkerExited(['s-worker-b']);

    c.close();
    await c.waitForClose();

    const c2 = await connectWs(`ws://127.0.0.1:${b1.port}/acp`, token);
    c2.sendJson({ jsonrpc: '2.0', id: 2, method: 'nonlocal/sync', params: {} });
    const instAfterWorkerExit = (await c2.waitFor((m) => m.id === 2)).result.instanceId;
    assert.equal(instAfterWorkerExit, inst1);
    c2.close();
    await c2.waitForClose();
  } finally {
    await b1.gw.stop();
  }

  // Full bridge restart generates a new non-empty instanceId
  const b2 = await startOne(0);
  try {
    const c3 = await connectWs(`ws://127.0.0.1:${b2.port}/acp`, token);
    c3.sendJson({ jsonrpc: '2.0', id: 3, method: 'nonlocal/sync', params: {} });
    const inst2 = (await c3.waitFor((m) => m.id === 3)).result.instanceId;
    assert.ok(inst2);
    assert.notEqual(inst2, inst1);
    c3.close();
    await c3.waitForClose();
  } finally {
    await b2.gw.stop();
    rmTempDir(root);
  }
});
