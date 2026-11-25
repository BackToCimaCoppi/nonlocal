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

test('AC-35 & AC-36: transparent wake & explicit load quiet settle, 3-step restore order (set_model->set_config_option->set_mode), noise suppression, and availableCommands (PP-35-order)', async () => {
  const root = makeTempDir('nonlocal-wake-ac35-');
  const token = createTestToken(64);
  const stateDir = join(root, 'state');
  const logFile = join(stateDir, 'bridge.log');
  const acpLogFile = join(root, 'acp-log.jsonl');

  const prevLog = process.env.FAKE_ACP_LOG;
  process.env.FAKE_ACP_LOG = acpLogFile;

  const buildCfg = () => {
    const cfg = createDefaultConfig(process.env, root);
    cfg.state.dir = stateDir;
    cfg.state.logFile = logFile;
    cfg.adapter.type = 'generic-acp';
    cfg.adapter.command = process.execPath;
    cfg.adapter.args = [FAKE_SERVER];
    cfg.adapter.fallbackCwd = root;
    cfg.adapter.defaultModel = 'm1-low'; // Must NEVER override wake/load!
    cfg.sync.loadSettleQuietMs = 60;
    cfg.sync.loadSettleMaxWaitMs = 200;
    return cfg;
  };

  // Boot 1: create session, switch to m2-high / thought_level=high / mode=code, then close bridge completely
  const cfg1 = buildCfg();
  const store1 = new StateStore({ stateDir });
  const logger1 = new SanitizedLogger({ logFile, redactSecrets: [token] });
  const adapter1 = new BaseAcpAdapter({ adapterConfig: cfg1.adapter, syncConfig: cfg1.sync, logger: logger1 });
  const transport1 = new WsServerTransport({
    host: '127.0.0.1',
    port: 0,
    allowNonLoopback: false,
    expectedToken: token,
    maxFrameBytes: cfg1.server.maxFrameBytes,
    pingIntervalMs: 25000,
    pongTimeoutMs: 60000,
    rateLimit: cfg1.security.rateLimit,
    getHealthState: () => ({ childAlive: adapter1.isHealthy(), activeClient: true }),
    logger: logger1,
  });
  const gw1 = new NonlocalGateway({ config: cfg1, transport: transport1, adapter: adapter1, store: store1, logger: logger1 });

  let gw2 = null;
  try {
    const { port: port1 } = await gw1.start();
    const c1 = await connectWs(`ws://127.0.0.1:${port1}/acp`, token);
    c1.sendJson({ jsonrpc: '2.0', id: 1, method: 'session/new', params: { cwd: root, forcedId: 's-restore' } });
    await c1.waitFor((m) => m.id === 1);

    c1.sendJson({ jsonrpc: '2.0', id: 2, method: 'session/set_model', params: { sessionId: 's-restore', modelId: 'm2-high' } });
    await c1.waitFor((m) => m.id === 2);
    c1.sendJson({ jsonrpc: '2.0', id: 3, method: 'session/set_config_option', params: { sessionId: 's-restore', configId: 'model', value: 'm2' } });
    await c1.waitFor((m) => m.id === 3);
    c1.sendJson({ jsonrpc: '2.0', id: 4, method: 'session/set_config_option', params: { sessionId: 's-restore', configId: 'thought_level', value: 'high' } });
    await c1.waitFor((m) => m.id === 4);
    c1.sendJson({ jsonrpc: '2.0', id: 5, method: 'session/set_mode', params: { sessionId: 's-restore', modeId: 'code' } });
    await c1.waitFor((m) => m.id === 5);

    c1.close();
    await c1.waitForClose();
    await gw1.stop();

    // Clear log before Boot 2 so we isolate exact wake/load command sequence
    const { writeFileSync } = await import('node:fs');
    writeFileSync(acpLogFile, '', 'utf8');

    // Boot 2: dormant session in SQLite; send session/prompt directly -> triggers AC-35 transparent wake!
    const cfg2 = buildCfg();
    const store2 = new StateStore({ stateDir });
    const logger2 = new SanitizedLogger({ logFile, redactSecrets: [token] });
    const adapter2 = new BaseAcpAdapter({ adapterConfig: cfg2.adapter, syncConfig: cfg2.sync, logger: logger2 });
    const transport2 = new WsServerTransport({
      host: '127.0.0.1',
      port: 0,
      allowNonLoopback: false,
      expectedToken: token,
      maxFrameBytes: cfg2.server.maxFrameBytes,
      pingIntervalMs: 25000,
      pongTimeoutMs: 60000,
      rateLimit: cfg2.security.rateLimit,
      getHealthState: () => ({ childAlive: adapter2.isHealthy(), activeClient: true }),
      logger: logger2,
    });
    gw2 = new NonlocalGateway({ config: cfg2, transport: transport2, adapter: adapter2, store: store2, logger: logger2 });
    const { port: port2 } = await gw2.start();
    const c2 = await connectWs(`ws://127.0.0.1:${port2}/acp`, token);

    c2.sendJson({
      jsonrpc: '2.0',
      id: 10,
      method: 'session/prompt',
      params: { sessionId: 's-restore', prompt: [{ type: 'text', text: 'wake prompt' }] },
    });
    const wakePromptRes = await c2.waitFor((m) => m.id === 10);
    assert.equal(wakePromptRes.result.stopReason, 'end_turn');

    // Verify exact ACP call order recorded on fake server:
    // session/load -> (quiet settle) -> set_model(m2-high) -> set_config_option(model=m2) -> set_config_option(thought_level=high) -> set_mode(code) -> session/prompt
    const wakeCalls = readFileSync(acpLogFile, 'utf8')
      .trim()
      .split('\n')
      .map((l) => JSON.parse(l));
    const idxLoad = wakeCalls.findIndex((e) => e.method === 'session/load');
    const idxModel = wakeCalls.findIndex((e) => e.method === 'session/set_model');
    const idxCfgModel = wakeCalls.findIndex((e) => e.method === 'session/set_config_option' && e.params?.configId === 'model');
    const idxCfgThought = wakeCalls.findIndex((e) => e.method === 'session/set_config_option' && e.params?.configId === 'thought_level');
    const idxMode = wakeCalls.findIndex((e) => e.method === 'session/set_mode');
    const idxPrompt = wakeCalls.findIndex((e) => e.method === 'session/prompt');

    assert.ok(idxLoad >= 0 && idxModel > idxLoad);
    assert.ok(idxCfgModel > idxModel && idxCfgThought > idxCfgModel);
    assert.ok(idxMode > idxCfgThought);
    assert.ok(idxPrompt > idxMode);
    assert.equal(wakeCalls[idxModel].params.modelId, 'm2-high');
    assert.equal(wakeCalls[idxMode].params.modeId, 'code');

    // Saved config in SQLite MUST NOT be corrupted by replay noise ('stale-replay' / 'late-noise')
    const savedRec = store2.get('s-restore');
    assert.equal(savedRec.models.currentModelId, 'm2-high');
    assert.equal(savedRec.modes.currentModeId, 'code');
    assert.ok(Array.isArray(savedRec.availableCommands) && savedRec.availableCommands.length === 1);

    // AC-36: explicit session/load suppresses replay config_option_update & sync snapshot stays accurate
    c2.sendJson({ jsonrpc: '2.0', id: 11, method: 'session/load', params: { sessionId: 's-restore', cwd: root } });
    const expLoad = await c2.waitFor((m) => m.id === 11);
    assert.equal(expLoad.result.sessionId, 's-restore');

    await new Promise((r) => setTimeout(r, 40));
    const leakedNoise = c2.messages.some(
      (m) => m.params?.update?.configOptions?.some?.((o) => o.currentValue === 'late-noise' || o.currentValue === 'stale-replay')
    );
    assert.equal(leakedNoise, false);

    c2.sendJson({ jsonrpc: '2.0', id: 12, method: 'nonlocal/sync', params: {} });
    const syncRes = await c2.waitFor((m) => m.id === 12);
    const snap = syncRes.result.sessions.find((s) => s.sessionId === 's-restore');
    assert.equal(snap.modes.currentModeId, 'code');
    assert.equal(snap.configOptions.find((o) => o.id === 'model').currentValue, 'm2');
    assert.equal(snap.availableCommands[0].name, 'help');

    c2.close();
    await c2.waitForClose();
  } finally {
    if (prevLog === undefined) delete process.env.FAKE_ACP_LOG;
    else process.env.FAKE_ACP_LOG = prevLog;
    if (gw2) await gw2.stop();
    rmTempDir(root);
  }
});
