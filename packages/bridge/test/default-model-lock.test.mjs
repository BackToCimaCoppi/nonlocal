import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
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

test('AC-37 & AC-38: defaultModel/defaultThoughtLevel whole-pair lock on new/create, _meta strip, unavailable graceful no-op, and no override on load (PP-37-lock)', async () => {
  const root = makeTempDir('nonlocal-lock-ac37-');
  const token = createTestToken(64);
  const acpLog = join(root, 'acp.jsonl');
  const prevLog = process.env.FAKE_ACP_LOG;
  process.env.FAKE_ACP_LOG = acpLog;

  // Case 1: Matching pair available -> m1-low overridden as whole pair to m2-high & _meta stripped
  const cfg = createDefaultConfig(process.env, root);
  cfg.state.dir = join(root, 'state1');
  cfg.state.logFile = join(root, 'state1', 'bridge.log');
  cfg.adapter.type = 'generic-acp';
  cfg.adapter.command = process.execPath;
  cfg.adapter.args = [FAKE_SERVER];
  cfg.adapter.fallbackCwd = root;
  cfg.adapter.defaultModel = 'm2';
  cfg.adapter.defaultThoughtLevel = 'high';
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
  const gw = new NonlocalGateway({ config: cfg, transport, adapter, store, logger });

  // Case 2: Unavailable defaultModel -> graceful no-op
  const cfgBad = createDefaultConfig(process.env, root);
  cfgBad.state.dir = join(root, 'state2');
  cfgBad.state.logFile = join(root, 'state2', 'bridge.log');
  cfgBad.adapter = { ...cfg.adapter, defaultModel: 'non-existent-model', defaultThoughtLevel: 'high' };
  const gwBad = new NonlocalGateway({
    config: cfgBad,
    transport: new WsServerTransport({
      host: '127.0.0.1',
      port: 0,
      allowNonLoopback: false,
      expectedToken: token,
      maxFrameBytes: cfgBad.server.maxFrameBytes,
      pingIntervalMs: 25000,
      pongTimeoutMs: 60000,
      rateLimit: cfgBad.security.rateLimit,
      getHealthState: () => ({ childAlive: true, activeClient: true }),
      logger: new SanitizedLogger({ logFile: cfgBad.state.logFile, redactSecrets: [token] }),
    }),
    adapter: new BaseAcpAdapter({
      adapterConfig: cfgBad.adapter,
      syncConfig: cfgBad.sync,
      logger: new SanitizedLogger({ logFile: cfgBad.state.logFile, redactSecrets: [token] }),
    }),
    store: new StateStore({ stateDir: cfgBad.state.dir }),
    logger: new SanitizedLogger({ logFile: cfgBad.state.logFile, redactSecrets: [token] }),
  });

  try {
    const { port } = await gw.start();
    const c = await connectWs(`ws://127.0.0.1:${port}/acp`, token);

    c.sendJson({ jsonrpc: '2.0', id: 1, method: 'session/new', params: { cwd: root, forcedId: 's-lock' } });
    const rNew = await c.waitFor((m) => m.id === 1);
    assert.equal(rNew.result.models.currentModelId, 'm2-high');
    assert.equal(rNew.result.configOptions.find((o) => o.id === 'model').currentValue, 'm2');
    assert.equal(rNew.result.configOptions.find((o) => o.id === 'thought_level').currentValue, 'high');
    assert.equal('_meta' in rNew.result, false, '_meta must be stripped from session/new response');

    c.sendJson({ jsonrpc: '2.0', id: 2, method: 'session/create', params: { cwd: root, forcedId: 's-create' } });
    const rCreate = await c.waitFor((m) => m.id === 2);
    assert.equal(rCreate.result.models.currentModelId, 'm2-high');
    assert.equal('_meta' in rCreate.result, false);

    // Client _meta.nonlocalDefaultModel whole-pair overrides config defaultModel & strips _meta from upstream call
    c.sendJson({
      jsonrpc: '2.0',
      id: 21,
      method: 'session/new',
      params: {
        cwd: root,
        forcedId: 's-meta-override',
        _meta: { nonlocalDefaultModel: 'm1', nonlocalDefaultThoughtLevel: 'high', keepOtherMeta: 1 },
      },
    });
    const rMeta = await c.waitFor((m) => m.id === 21);
    assert.equal(rMeta.result.models.currentModelId, 'm1-high');
    const reqMetaLog = readFileSync(acpLog, 'utf8')
      .trim()
      .split('\n')
      .map((l) => JSON.parse(l))
      .find((e) => e.params?.forcedId === 's-meta-override');
    assert.equal(reqMetaLog.params._meta?.nonlocalDefaultModel, undefined);
    assert.equal(reqMetaLog.params._meta?.nonlocalDefaultThoughtLevel, undefined);
    assert.equal(reqMetaLog.params._meta?.keepOtherMeta, 1);

    // Empty nonlocalDefaultModel ignores orphan nonlocalDefaultThoughtLevel and keeps config pair m2-high
    c.sendJson({
      jsonrpc: '2.0',
      id: 22,
      method: 'session/new',
      params: {
        cwd: root,
        forcedId: 's-meta-orphan',
        _meta: { nonlocalDefaultModel: '', nonlocalDefaultThoughtLevel: 'low' },
      },
    });
    const rOrphan = await c.waitFor((m) => m.id === 22);
    assert.equal(rOrphan.result.models.currentModelId, 'm2-high');

    // Explicit change to m1-low followed by load must keep m1-low (lock NEVER overrides load)
    c.sendJson({ jsonrpc: '2.0', id: 3, method: 'session/set_model', params: { sessionId: 's-lock', modelId: 'm1-low' } });
    await c.waitFor((m) => m.id === 3);
    c.sendJson({ jsonrpc: '2.0', id: 4, method: 'session/set_config_option', params: { sessionId: 's-lock', configId: 'model', value: 'm1' } });
    await c.waitFor((m) => m.id === 4);
    c.sendJson({ jsonrpc: '2.0', id: 5, method: 'session/set_config_option', params: { sessionId: 's-lock', configId: 'thought_level', value: 'low' } });
    await c.waitFor((m) => m.id === 5);

    c.sendJson({ jsonrpc: '2.0', id: 6, method: 'session/load', params: { sessionId: 's-lock', cwd: root } });
    await c.waitFor((m) => m.id === 6);
    assert.equal(store.get('s-lock').models.currentModelId, 'm1-low');

    c.close();
    await c.waitForClose();

    // Unavailable model graceful no-op
    const { port: pBad } = await gwBad.start();
    const cBad = await connectWs(`ws://127.0.0.1:${pBad}/acp`, token);
    cBad.sendJson({ jsonrpc: '2.0', id: 1, method: 'session/new', params: { cwd: root, forcedId: 's-noop' } });
    const rNoop = await cBad.waitFor((m) => m.id === 1);
    assert.equal(rNoop.result.models.currentModelId, 'm1-low');
    assert.ok(readFileSync(acpLog, 'utf8').length > 0);
    cBad.close();
    await cBad.waitForClose();
  } finally {
    if (prevLog === undefined) delete process.env.FAKE_ACP_LOG;
    else process.env.FAKE_ACP_LOG = prevLog;
    await gw.stop();
    await gwBad.stop();
    rmTempDir(root);
  }
});
