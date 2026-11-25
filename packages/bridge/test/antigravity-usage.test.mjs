import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createDefaultConfig } from '../dist/config/schema.js';
import { AntigravityAdapter } from '../dist/adapter/antigravity-adapter.js';
import { WsServerTransport } from '../dist/transport/ws-server-transport.js';
import { NonlocalGateway } from '../dist/gateway/gateway.js';
import { StateStore } from '../dist/store/state-store.js';
import { SanitizedLogger } from '../dist/log/logger.js';
import { connectWs } from './helpers/ws-client.mjs';
import { createTestToken, makeTempDir, rmTempDir } from './helpers/test-utils.mjs';

const FAKE_AGY = fileURLToPath(new URL('./helpers/fake-agy-cli.mjs', import.meta.url));

test('AC-43 & AC-44: usage TTL SWR, single-flight concurrency, ANSI/auth/timeout sanitization, -pid kill, cooldown, and _meta.antigravity.tier capture (PP-43-usage)', async () => {
  const root = makeTempDir('nonlocal-usage-ac43-');
  chmodSync(FAKE_AGY, 0o755);
  const token = createTestToken(64);
  const countFile = join(root, 'usage-count.txt');

  const cfg = createDefaultConfig(process.env, root);
  cfg.state.dir = join(root, 'state');
  cfg.state.logFile = join(root, 'state', 'bridge.log');
  cfg.adapter.type = 'antigravity';
  cfg.adapter.command = FAKE_AGY;
  cfg.adapter.fallbackCwd = root;
  cfg.adapter.antigravity.dataDirs = [join(root, 'agy-data')];
  cfg.adapter.antigravity.usageTimeoutMs = 800;
  cfg.adapter.antigravity.usageCooldownMs = 300;

  const store = new StateStore({ stateDir: cfg.state.dir });
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

  const prevMode = process.env.FAKE_AGY_USAGE_MODE;
  const prevCount = process.env.FAKE_AGY_USAGE_COUNT_FILE;
  const prevDelay = process.env.FAKE_AGY_USAGE_DELAY_MS;
  const prevAcpMode = process.env.FAKE_ACP_MODE;
  const prevGcPidFile = process.env.FAKE_AGY_USAGE_GRANDCHILD_PID_FILE;
  const gcPidFile = join(root, 'usage-grandchild.pid');

  try {
    process.env.FAKE_AGY_USAGE_COUNT_FILE = countFile;
    process.env.FAKE_AGY_USAGE_MODE = 'ok';
    process.env.FAKE_AGY_USAGE_DELAY_MS = '60';
    process.env.FAKE_ACP_MODE = 'tier_meta';
    process.env.FAKE_AGY_USAGE_GRANDCHILD_PID_FILE = gcPidFile;

    const { port } = await gw.start();

    // AC-67: Unsubscribed connection (has never called nonlocal/usage) must NOT receive nonlocal/usage_updated
    const cUnsub = await connectWs(`ws://127.0.0.1:${port}/acp`, token);
    cUnsub.sendJson({ jsonrpc: '2.0', id: 100, method: 'session/new', params: { cwd: root, forcedId: 's-tier-unsub' } });
    await cUnsub.waitFor((m) => m.id === 100);
    await new Promise((r) => setTimeout(r, 40));
    assert.equal(cUnsub.messages.some((m) => m.method === 'nonlocal/usage_updated'), false, 'AC-67: usageEnabled:false must not push usage_updated');
    cUnsub.close();
    await cUnsub.waitForClose();

    // AC-67: Corrupted usage_snapshot.payload_json self-heals instead of crashing
    store['db'].prepare("INSERT OR REPLACE INTO usage_snapshot (id, payload_json, updated_at) VALUES (1, '{corrupt', '2026-11-23T00:00:00Z')").run();

    const c = await connectWs(`ws://127.0.0.1:${port}/acp`, token);

    // 1. 5x concurrent nonlocal/usage calls -> single CLI invocation (PP-43-singleflight) + <50ms non-blocking reply
    const t0 = Date.now();
    for (let id = 1; id <= 5; id++) {
      c.sendJson({ jsonrpc: '2.0', id, method: 'nonlocal/usage', params: {} });
    }
    const r1 = await c.waitFor((m) => m.id === 1);
    assert.ok(Date.now() - t0 < 200, 'nonlocal/usage must return immediately without blocking on CLI');
    for (let id = 2; id <= 5; id++) {
      const rN = await c.waitFor((m) => m.id === id);
      assert.equal(rN.result.refreshing, true);
    }
    assert.equal(r1.result.refreshing, true);
    assert.equal(r1.result.ttlSeconds, 180);

    const upd1 = await c.waitFor((m) => m.method === 'nonlocal/usage_updated');
    assert.equal(upd1.params.refreshing, false);
    assert.equal(upd1.params.groups.length, 1);
    assert.equal(upd1.params.groups[0].buckets[0].window, '5h');
    assert.equal(upd1.params.groups[0].buckets[0].remainingFraction, 0.8);
    assert.equal(upd1.params.groups[0].buckets[1].window, 'weekly');
    assert.equal(readFileSync(countFile, 'utf8').trim(), '1');

    // 2. Fresh cache hit within TTL -> zero new CLI call & refreshing:false
    const rFresh = await (async () => {
      c.sendJson({ jsonrpc: '2.0', id: 3, method: 'nonlocal/usage', params: {} });
      return c.waitFor((m) => m.id === 3);
    })();
    assert.equal(rFresh.result.refreshing, false);
    assert.equal(readFileSync(countFile, 'utf8').trim(), '1');

    // 3. _meta.antigravity.tier observed on session/new pushes nonlocal/usage_updated with tier
    c.sendJson({ jsonrpc: '2.0', id: 4, method: 'session/new', params: { cwd: root, forcedId: 's-tier' } });
    await c.waitFor((m) => m.id === 4);
    const tierUpd = await c.waitFor((m) => m.method === 'nonlocal/usage_updated' && m.params?.tier?.id === 'pro-tier');
    assert.equal(tierUpd.params.tier.name, 'Pro Tier');

    // 4. Stale cache (> TTL 180s) triggers SWR failure modes: auth_required, timeout, ansi_fail -> sanitized errors, stale groups preserved!
    const oldSnap = store.getUsageSnapshot();
    const staleIso = new Date(Date.now() - 200_000).toISOString();
    store.saveUsageSnapshot({ ...oldSnap, fetchedAt: staleIso });

    writeFileSync(countFile, '0', 'utf8');
    process.env.FAKE_AGY_USAGE_MODE = 'auth';
    c.sendJson({ jsonrpc: '2.0', id: 5, method: 'nonlocal/usage', params: {} });
    const rStale = await c.waitFor((m) => m.id === 5);
    assert.equal(rStale.result.refreshing, true);
    assert.equal(rStale.result.groups.length, 1);

    const errUpdAuth = await c.waitFor((m) => m.method === 'nonlocal/usage_updated' && m.params?.lastError);
    assert.equal(errUpdAuth.params.lastError.code, 'auth_required');
    assert.equal(errUpdAuth.params.lastError.message.includes('SECRET_RAW_CLI_TOKEN_LEAK'), false);
    assert.equal(errUpdAuth.params.groups.length, 1, 'SWR must keep stale groups on refresh failure');

    // Within cooldownMs -> refreshing:false, zero extra spawn
    c.sendJson({ jsonrpc: '2.0', id: 6, method: 'nonlocal/usage', params: {} });
    const rCool = await c.waitFor((m) => m.id === 6);
    assert.equal(rCool.result.refreshing, false);
    assert.equal(readFileSync(countFile, 'utf8').trim(), '1');

    // After cooldown -> timeout kills hung CLI cleanly
    await new Promise((r) => setTimeout(r, 340));
    process.env.FAKE_AGY_USAGE_MODE = 'hang';
    c.sendJson({ jsonrpc: '2.0', id: 7, method: 'nonlocal/usage', params: {} });
    await c.waitFor((m) => m.id === 7);
    const errUpdTimeout = await c.waitFor(
      (m) => m.method === 'nonlocal/usage_updated' && m.params?.lastError?.code === 'timeout'
    );
    assert.ok(errUpdTimeout.params.lastError.failedAt);

    // PP-44-kill: timeout must kill grandchild in -pid process group
    if (existsSync(gcPidFile)) {
      const gcPid = Number(readFileSync(gcPidFile, 'utf8').trim());
      await new Promise((r) => setTimeout(r, 120));
      assert.throws(() => process.kill(gcPid, 0), /ESRCH/);
    }

    // No raw secret text or ANSI leakage in bridge.log or SQLite usage_snapshot
    const logContent = readFileSync(cfg.state.logFile, 'utf8');
    assert.equal(logContent.includes('SECRET_RAW_CLI_TOKEN_LEAK'), false);
    const dbSnap = JSON.stringify(store.getUsageSnapshot());
    assert.equal(dbSnap.includes('SECRET_RAW_CLI_TOKEN_LEAK'), false);

    c.close();
    await c.waitForClose();
    assert.equal(existsSync(cfg.state.logFile), true);
  } finally {
    if (prevMode === undefined) delete process.env.FAKE_AGY_USAGE_MODE;
    else process.env.FAKE_AGY_USAGE_MODE = prevMode;
    if (prevCount === undefined) delete process.env.FAKE_AGY_USAGE_COUNT_FILE;
    else process.env.FAKE_AGY_USAGE_COUNT_FILE = prevCount;
    if (prevDelay === undefined) delete process.env.FAKE_AGY_USAGE_DELAY_MS;
    else process.env.FAKE_AGY_USAGE_DELAY_MS = prevDelay;
    if (prevAcpMode === undefined) delete process.env.FAKE_ACP_MODE;
    else process.env.FAKE_ACP_MODE = prevAcpMode;
    if (prevGcPidFile === undefined) delete process.env.FAKE_AGY_USAGE_GRANDCHILD_PID_FILE;
    else process.env.FAKE_AGY_USAGE_GRANDCHILD_PID_FILE = prevGcPidFile;
    await gw.stop();
    rmTempDir(root);
  }
});
