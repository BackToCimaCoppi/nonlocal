import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import os from 'node:os';
import {
  classifyListenWarning,
  getSecurityWarningText,
  resolveCompanionLoopback,
  resolveLocalProbeHost,
} from '../dist/config/ip.js';
import { createDefaultConfig, validateResolvedConfig } from '../dist/config/schema.js';
import { WsServerTransport } from '../dist/transport/ws-server-transport.js';
import { NonlocalGateway } from '../dist/gateway/gateway.js';
import { StateStore } from '../dist/store/state-store.js';
import { SanitizedLogger } from '../dist/log/logger.js';
import { FakeTestAdapter } from './helpers/fake-adapter.mjs';
import { httpRequest, connectWs } from './helpers/ws-client.mjs';
import { createTestToken, getFreePort, makeTempDir, rmTempDir } from './helpers/test-utils.mjs';
import { join } from 'node:path';

function findNonLoopbackIpv4() {
  const ifs = os.networkInterfaces();
  for (const addrs of Object.values(ifs)) {
    for (const a of addrs || []) {
      if (a.family === 'IPv4' && !a.internal && a.address) {
        return a.address;
      }
    }
  }
  return null;
}

test('AC-13: reject non-IP hostnames regardless of allowNonLoopback, reject non-loopback without switch, allow 127.0.0.2 (PP-13-reject)', async () => {
  const token = createTestToken(64);
  const cfg = createDefaultConfig();

  // 1. Non-IP hostnames forbidden regardless of allowNonLoopback
  for (const badHost of ['localhost', 'my-mac.local']) {
    for (const allow of [false, true]) {
      const badCfg = structuredClone(cfg);
      badCfg.server.host = badHost;
      badCfg.server.allowNonLoopback = allow;
      assert.throws(() => validateResolvedConfig(badCfg), /server\.host/);
    }
  }

  // 2. Non-loopback IP without allowNonLoopback=true throws before listening
  const port = await getFreePort('127.0.0.1');
  for (const host of ['0.0.0.0', '::']) {
    assert.throws(
      () =>
        new WsServerTransport({
          host,
          port,
          allowNonLoopback: false,
          expectedToken: token,
          maxFrameBytes: 1024 * 1024,
          pingIntervalMs: 25000,
          pongTimeoutMs: 60000,
          rateLimit: cfg.security.rateLimit,
          getHealthState: () => ({ childAlive: false, activeClient: false }),
        }),
      /allowNonLoopback/
    );
  }

  // 3. 127.0.0.2 is in 127.0.0.0/8 loopback whitelist and is accepted by config/transport with allowNonLoopback=false
  const cfg127_2 = structuredClone(cfg);
  cfg127_2.server.host = '127.0.0.2';
  cfg127_2.server.allowNonLoopback = false;
  assert.doesNotThrow(() => validateResolvedConfig(cfg127_2));

  const t127_2 = new WsServerTransport({
    host: '127.0.0.2',
    port: 0,
    allowNonLoopback: false,
    expectedToken: token,
    maxFrameBytes: 1024 * 1024,
    pingIntervalMs: 25000,
    pongTimeoutMs: 60000,
    rateLimit: cfg.security.rateLimit,
    getHealthState: () => ({ childAlive: false, activeClient: false }),
  });
  try {
    const bound = await t127_2.start();
    assert.equal(bound.listenAddresses.length, 1);
    assert.equal(bound.listenAddresses[0].host, '127.0.0.2');
    await t127_2.stop();
  } catch (err) {
    // macOS without `lo0 alias 127.0.0.2` returns EADDRNOTAVAIL only AFTER transport whitelist check passes
    assert.equal(err?.code, 'EADDRNOTAVAIL');
  }

  // Also verify real loopback start/stop on 127.0.0.1 and ::1 with allowNonLoopback=false
  for (const lbHost of ['127.0.0.1', '::1']) {
    const tLb = new WsServerTransport({
      host: lbHost,
      port: 0,
      allowNonLoopback: false,
      expectedToken: token,
      maxFrameBytes: 1024 * 1024,
      pingIntervalMs: 25000,
      pongTimeoutMs: 60000,
      rateLimit: cfg.security.rateLimit,
      getHealthState: () => ({ childAlive: false, activeClient: false }),
    });
    const bound = await tLb.start();
    assert.equal(bound.listenAddresses[0].host, lbHost);
    await tLb.stop();
  }
});

test('AC-14 & AC-15: unicast companion loopback atomic start/rollback, IPv6 probe family, and tiered plaintext warnings (PP-14-rollback)', async () => {
  const lanIp = findNonLoopbackIpv4();
  assert.ok(lanIp, 'ENV: expected non-loopback IPv4 interface on test host');

  const cfg = createDefaultConfig();
  const token = createTestToken(64);

  // 1. Occupy 127.0.0.1:<P> so companion-loopback bind fails and rolls back primary <lanIp>:<P>
  const conflictPort = await getFreePort('127.0.0.1');
  const blocker = net.createServer();
  await new Promise((res) => blocker.listen(conflictPort, '127.0.0.1', res));

  const transportRollback = new WsServerTransport({
    host: lanIp,
    port: conflictPort,
    allowNonLoopback: true,
    expectedToken: token,
    maxFrameBytes: 1024 * 1024,
    pingIntervalMs: 25000,
    pongTimeoutMs: 60000,
    rateLimit: cfg.security.rateLimit,
    getHealthState: () => ({ childAlive: false, activeClient: false }),
  });
  await assert.rejects(() => transportRollback.start(), /companion loopback/);
  // Verify primary <lanIp>:<conflictPort> is NOT bound after rollback
  const verifyBind = net.createServer();
  await new Promise((res, rej) => {
    verifyBind.once('error', rej);
    verifyBind.listen(conflictPort, lanIp, () => res());
  });
  await new Promise((res) => verifyBind.close(res));
  await new Promise((res) => blocker.close(res));

  // 2. Normal unicast + companion loopback start & stop
  const t = new WsServerTransport({
    host: lanIp,
    port: 0,
    allowNonLoopback: true,
    expectedToken: token,
    maxFrameBytes: 1024 * 1024,
    pingIntervalMs: 25000,
    pongTimeoutMs: 60000,
    rateLimit: cfg.security.rateLimit,
    getHealthState: () => ({ childAlive: false, activeClient: false }),
  });
  const started = await t.start();
  assert.equal(started.listenAddresses.length, 2);
  assert.deepEqual(
    started.listenAddresses.map((a) => [a.role, a.host]),
    [
      ['primary', lanIp],
      ['companion-loopback', '127.0.0.1'],
    ]
  );
  await t.stop();

  // 3. IPv6 companion loopback & local probe family resolution
  assert.equal(resolveCompanionLoopback('fd00::1'), '::1');
  assert.equal(resolveCompanionLoopback('0.0.0.0'), null);
  assert.equal(resolveCompanionLoopback('::'), null);
  assert.equal(resolveLocalProbeHost('::1'), '::1');
  assert.equal(resolveLocalProbeHost('::'), '::1');
  assert.equal(resolveLocalProbeHost('fd00::1'), '::1');
  assert.equal(resolveLocalProbeHost('192.168.1.10'), '127.0.0.1');

  // 4. AC-15 tiered plaintext warning classification (including CGNAT 100.64.0.0/10)
  assert.equal(classifyListenWarning('127.0.0.1'), 'none');
  assert.equal(classifyListenWarning('192.168.1.50'), 'lan_plaintext');
  assert.equal(classifyListenWarning('100.64.10.5'), 'lan_plaintext');
  assert.match(getSecurityWarningText('lan_plaintext') || '', /局域网明文/);
  assert.equal(classifyListenWarning('0.0.0.0'), 'public_or_wildcard_plaintext');
  assert.equal(classifyListenWarning('::'), 'public_or_wildcard_plaintext');
  assert.equal(classifyListenWarning('203.0.113.10'), 'public_or_wildcard_plaintext');
  assert.match(getSecurityWarningText('public_or_wildcard_plaintext') || '', /强烈建议改回/);
});

test('AC-16, AC-17, AC-18: /health loopback 4-state booleans, dual-stack ::ffff:127.0.0.1, proxy/non-loopback 404, HTTP 426/404/400 (PP-16-schema, PP-17-deny)', async () => {
  const lanIp = findNonLoopbackIpv4();
  assert.ok(lanIp, 'ENV: expected non-loopback IPv4 interface on test host');
  const root = makeTempDir('nonlocal-net-ac16-');
  const token = createTestToken(64);
  const cfg = createDefaultConfig(process.env, root);
  cfg.server.host = lanIp;
  cfg.server.port = 0;
  cfg.server.allowNonLoopback = true;
  cfg.state.dir = join(root, 'state');
  cfg.state.logFile = join(root, 'state', 'bridge.log');

  const store = new StateStore({ stateDir: cfg.state.dir });
  const logger = new SanitizedLogger({ logFile: cfg.state.logFile, redactSecrets: [token] });
  const adapter = new FakeTestAdapter();
  let gwRef = null;
  const transport = new WsServerTransport({
    host: cfg.server.host,
    port: 0,
    allowNonLoopback: true,
    expectedToken: token,
    maxFrameBytes: cfg.server.maxFrameBytes,
    pingIntervalMs: cfg.server.pingIntervalMs,
    pongTimeoutMs: cfg.server.pongTimeoutMs,
    rateLimit: cfg.security.rateLimit,
    getHealthState: () => gwRef?.getHealthState() ?? { childAlive: false, activeClient: false },
    logger,
  });
  const gateway = new NonlocalGateway({ config: cfg, transport, adapter, store, logger });
  gwRef = gateway;

  let dualStackTransport = null;
  try {
    const info = await gateway.start();
    const port = info.port;

    // State 1: cold start (childAlive:false, activeClient:false) via companion loopback
    const h1 = await httpRequest({ host: '127.0.0.1', port, path: '/health' });
    assert.equal(h1.statusCode, 200);
    assert.match(String(h1.headers['content-type'] || ''), /application\/json/);
    assert.equal(h1.headers['cache-control'], 'no-store');
    const j1 = JSON.parse(h1.body);
    assert.deepEqual(Object.keys(j1).sort(), ['activeClient', 'childAlive', 'ok']);
    assert.deepEqual(j1, { ok: true, childAlive: false, activeClient: false });

    // State 2: WS connected (childAlive:false, activeClient:true)
    const ws1 = await connectWs(`ws://127.0.0.1:${port}/acp`, token);
    const h2 = await httpRequest({ host: '127.0.0.1', port, path: '/health' });
    assert.deepEqual(JSON.parse(h2.body), { ok: true, childAlive: false, activeClient: true });

    // State 3: first RPC spawns adapter worker (childAlive:true, activeClient:true)
    ws1.sendJson({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: 1 } });
    await ws1.waitFor((m) => m.id === 1);
    const h3 = await httpRequest({ host: '127.0.0.1', port, path: '/health' });
    assert.deepEqual(JSON.parse(h3.body), { ok: true, childAlive: true, activeClient: true });

    // State 4: WS disconnected (childAlive:true, activeClient:false)
    ws1.close(1000, 'done');
    await ws1.waitForClose();
    const h4 = await httpRequest({ host: '127.0.0.1', port, path: '/health' });
    assert.deepEqual(JSON.parse(h4.body), { ok: true, childAlive: true, activeClient: false });

    // AC-17: non-loopback source & all 4 proxy forwarding headers return 404 without state keys
    const nonLoopHealth = await httpRequest({ host: lanIp, port, path: '/health' });
    assert.equal(nonLoopHealth.statusCode, 404);
    assert.equal(nonLoopHealth.body.includes('childAlive'), false);
    assert.equal(nonLoopHealth.body.includes('activeClient'), false);

    for (const hdr of ['X-Forwarded-For', 'Forwarded', 'X-Real-IP', 'CF-Connecting-IP']) {
      const proxied = await httpRequest({
        host: '127.0.0.1',
        port,
        path: '/health',
        headers: { [hdr]: '203.0.113.5' },
      });
      assert.equal(proxied.statusCode, 404, `header ${hdr} should make /health return 404`);
      assert.equal(proxied.body.includes('childAlive'), false);
    }

    // AC-16 dual-stack :: (ipv6Only:false) from both ::1 and 127.0.0.1 (::ffff:127.0.0.1)
    dualStackTransport = new WsServerTransport({
      host: '::',
      port: 0,
      allowNonLoopback: true,
      expectedToken: token,
      maxFrameBytes: 1024 * 1024,
      pingIntervalMs: 25000,
      pongTimeoutMs: 60000,
      rateLimit: cfg.security.rateLimit,
      getHealthState: () => ({ childAlive: true, activeClient: false }),
    });
    const dsInfo = await dualStackTransport.start();
    const dsV6 = await httpRequest({ host: '::1', port: dsInfo.port, path: '/health' });
    assert.equal(dsV6.statusCode, 200);
    const dsV4Mapped = await httpRequest({ host: '127.0.0.1', port: dsInfo.port, path: '/health' });
    assert.equal(dsV4Mapped.statusCode, 200);

    // AC-18: non-upgrade HTTP paths
    for (const p of ['/', '/acp', '/ws']) {
      const r = await httpRequest({ host: '127.0.0.1', port, path: p });
      assert.equal(r.statusCode, 426);
      assert.equal(r.headers.upgrade, 'websocket');
    }
    const r404 = await httpRequest({ host: '127.0.0.1', port, path: '/unknown' });
    assert.equal(r404.statusCode, 404);

    // Malformed URL & bad upgrade headers -> 400
    const badUpgrade = await httpRequest({
      host: '127.0.0.1',
      port,
      path: '/%E0%A4%A',
    });
    assert.equal(badUpgrade.statusCode, 400);
  } finally {
    if (dualStackTransport) await dualStackTransport.stop();
    await gateway.stop();
    rmTempDir(root);
  }
});

test('AC-15 (end-to-end): non-loopback plaintext warnings consistent across init, non_loopback_listening log, status --json, and doctor --json', async () => {
  const { execFileSync, spawnSync } = await import('node:child_process');
  const { readFileSync } = await import('node:fs');
  const { fileURLToPath } = await import('node:url');
  const { makeCleanEnv } = await import('./helpers/test-utils.mjs');
  const cliPath = fileURLToPath(new URL('../dist/cli.js', import.meta.url));
  const fakeServer = fileURLToPath(new URL('./helpers/fake-acp-server.mjs', import.meta.url));
  const lanIp = findNonLoopbackIpv4();
  assert.ok(lanIp, 'ENV: expected non-loopback IPv4 interface on test host');

  const root = makeTempDir('nonlocal-ac15-cli-');
  const env = makeCleanEnv({ HOME: root });
  const port1 = await getFreePort('127.0.0.1');
  const port2 = await getFreePort('127.0.0.1');
  const cfgLan = join(root, 'lan', 'config.json');
  const stateLan = join(root, 'lan-state');
  const cfgWild = join(root, 'wild', 'config.json');
  const stateWild = join(root, 'wild-state');

  try {
    // 1. LAN unicast (lan_plaintext) across init / start log / status --json / doctor --json
    const initLan = spawnSync(
      process.execPath,
      [
        cliPath,
        'init',
        '--yes',
        '--config',
        cfgLan,
        '--state-dir',
        stateLan,
        '--host',
        lanIp,
        '--port',
        String(port1),
        '--allow-non-loopback',
        '--adapter',
        'generic-acp',
        '--adapter-command',
        process.execPath,
        '--adapter-args',
        JSON.stringify([fakeServer]),
      ],
      { encoding: 'utf8', env }
    );
    assert.equal(initLan.status, 0);
    assert.match(`${initLan.stdout}\n${initLan.stderr}`, /局域网明文/);

    execFileSync(process.execPath, [cliPath, 'start', '--standalone', '--config', cfgLan], { env });
    const logLan = readFileSync(join(stateLan, 'bridge.log'), 'utf8');
    assert.equal(logLan.includes('non_loopback_listening'), true);

    const statusLan = JSON.parse(
      execFileSync(process.execPath, [cliPath, 'status', '--json', '--config', cfgLan], { encoding: 'utf8', env })
    );
    assert.match(statusLan.securityWarning || '', /局域网明文/);

    const docLan = JSON.parse(
      execFileSync(process.execPath, [cliPath, 'doctor', '--json', '--config', cfgLan], { encoding: 'utf8', env })
    );
    const secCheckLan = docLan.checks.find((c) => c.id === 'config_security');
    assert.equal(secCheckLan.status, 'warn');
    assert.match(secCheckLan.summary, /局域网明文/);
    execFileSync(process.execPath, [cliPath, 'stop', '--standalone', '--config', cfgLan], { env });

    // 2. Wildcard 0.0.0.0 (public_or_wildcard_plaintext) across init & doctor --json
    const initWild = spawnSync(
      process.execPath,
      [
        cliPath,
        'init',
        '--yes',
        '--config',
        cfgWild,
        '--state-dir',
        stateWild,
        '--host',
        '0.0.0.0',
        '--port',
        String(port2),
        '--allow-non-loopback',
        '--adapter',
        'generic-acp',
        '--adapter-command',
        process.execPath,
        '--adapter-args',
        JSON.stringify([fakeServer]),
      ],
      { encoding: 'utf8', env }
    );
    assert.equal(initWild.status, 0);
    assert.match(`${initWild.stdout}\n${initWild.stderr}`, /强烈建议改回/);

    const docWild = spawnSync(process.execPath, [cliPath, 'doctor', '--json', '--config', cfgWild], {
      encoding: 'utf8',
      env,
    });
    assert.equal(docWild.status, 1); // free -> bridge_live_handshake fail, while config_security is warn
    const secCheckWild = JSON.parse(docWild.stdout).checks.find((c) => c.id === 'config_security');
    assert.equal(secCheckWild.status, 'warn');
    assert.match(secCheckWild.summary, /强烈建议改回/);
  } finally {
    spawnSync(process.execPath, [cliPath, 'stop', '--standalone', '--config', cfgLan], { env });
    rmTempDir(root);
  }
});
