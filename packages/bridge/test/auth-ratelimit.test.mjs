import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import { AuthRateLimiter } from '../dist/transport/rate-limiter.js';
import { WsServerTransport } from '../dist/transport/ws-server-transport.js';
import { createDefaultConfig } from '../dist/config/schema.js';
import { resolveClientKey, parseTrustedProxyEntry } from '../dist/config/ip.js';
import { rawUpgradeRequest, makeWsKey, connectWs } from './helpers/ws-client.mjs';
import { createTestToken } from './helpers/test-utils.mjs';

function findNonLoopbackIpv4() {
  for (const addrs of Object.values(os.networkInterfaces())) {
    for (const a of addrs || []) {
      if (a.family === 'IPv4' && !a.internal && a.address) return a.address;
    }
  }
  return null;
}

test('AC-19: WS auth positive/negative (Basic, query token, wrong token, Origin ignored, permessage-deflate rejected) (PP-19-auth)', async () => {
  const token = createTestToken(64);
  const cfg = createDefaultConfig();
  const transport = new WsServerTransport({
    host: '127.0.0.1',
    port: 0,
    allowNonLoopback: false,
    expectedToken: token,
    maxFrameBytes: 1024 * 1024,
    pingIntervalMs: 25000,
    pongTimeoutMs: 60000,
    rateLimit: { ...cfg.security.rateLimit, loopbackBackoffMs: 0 },
    getHealthState: () => ({ childAlive: false, activeClient: false }),
  });

  try {
    const { port } = await transport.start();
    const baseHeaders = () => ({
      Upgrade: 'websocket',
      Connection: 'Upgrade',
      'Sec-WebSocket-Version': '13',
      'Sec-WebSocket-Key': makeWsKey(),
    });

    // Missing header, Basic auth, wrong token, query tokens -> 401 + WWW-Authenticate
    const negativeCases = [
      { path: '/acp', headers: baseHeaders() },
      { path: '/acp', headers: { ...baseHeaders(), Authorization: 'Basic dXNlcjpwYXNz' } },
      { path: '/acp', headers: { ...baseHeaders(), Authorization: `Bearer ${'x'.repeat(64)}` } },
      { path: `/acp?token=${token}`, headers: { ...baseHeaders(), Authorization: `Bearer ${token}` } },
      { path: `/acp?access_token=${token}`, headers: { ...baseHeaders(), Authorization: `Bearer ${token}` } },
    ];
    for (const nc of negativeCases) {
      const res = await rawUpgradeRequest({ host: '127.0.0.1', port, path: nc.path, headers: nc.headers });
      assert.equal(res.statusCode, 401);
      assert.equal(res.headers['www-authenticate'], 'Bearer realm="nonlocal-bridge"');
    }

    // Bad upgrade headers -> 400
    const badVer = await rawUpgradeRequest({
      host: '127.0.0.1',
      port,
      path: '/acp',
      headers: { Upgrade: 'websocket', Connection: 'Upgrade', 'Sec-WebSocket-Version': '12', 'Sec-WebSocket-Key': makeWsKey(), Authorization: `Bearer ${token}` },
    });
    assert.equal(badVer.statusCode, 400);

    // Valid Bearer + arbitrary Origin + explicit Sec-WebSocket-Extensions: permessage-deflate -> 101 WITHOUT permessage-deflate
    const okRes = await rawUpgradeRequest({
      host: '127.0.0.1',
      port,
      path: '/acp',
      headers: {
        ...baseHeaders(),
        Origin: 'https://evil.example',
        'Sec-WebSocket-Extensions': 'permessage-deflate; client_max_window_bits',
        Authorization: `Bearer ${token}`,
      },
    });
    assert.equal(okRes.statusCode, 101);
    assert.equal(String(okRes.headers['sec-websocket-extensions'] || '').includes('permessage-deflate'), false);
  } finally {
    await transport.stop();
  }
});

test('AC-20 & AC-21: non-loopback rate limiting (9->401, 10->429+Retry-After, ban short-circuit, ban expiry, window slide, success reset) (PP-20-ban)', async () => {
  const lanIp = findNonLoopbackIpv4();
  assert.ok(lanIp, 'ENV: expected non-loopback IPv4 interface on test host');
  const token = createTestToken(64);
  const cfg = createDefaultConfig();

  let fakeNow = 1_000_000;
  const transport = new WsServerTransport({
    host: lanIp,
    port: 0,
    allowNonLoopback: true,
    expectedToken: token,
    maxFrameBytes: 1024 * 1024,
    pingIntervalMs: 25000,
    pongTimeoutMs: 60000,
    trustedProxies: [],
    rateLimit: {
      maxFailures: 10,
      windowMs: 600_000,
      banMs: 300_000,
      loopbackBackoffMs: 0,
      maxTrackedIps: 4096,
    },
    nowFn: () => fakeNow,
    getHealthState: () => ({ childAlive: false, activeClient: false }),
  });

  try {
    const { port } = await transport.start();
    const makeHdrs = (idx, auth) => ({
      Upgrade: 'websocket',
      Connection: 'Upgrade',
      'Sec-WebSocket-Version': '13',
      'Sec-WebSocket-Key': makeWsKey(),
      'X-Forwarded-For': `10.0.0.${idx}`, // Must be ignored when trustedProxies=[]
      Authorization: auth,
    });

    // Failures 1..9 (including query token attempt) -> 401
    for (let i = 1; i <= 9; i++) {
      const res = await rawUpgradeRequest({
        host: lanIp,
        port,
        path: i === 5 ? `/acp?token=${token}` : '/acp',
        headers: makeHdrs(i, i === 5 ? `Bearer ${token}` : 'Bearer wrong-token-value'),
      });
      assert.equal(res.statusCode, 401, `failure #${i} should be 401`);
    }

    // 10th failure -> 429 + Retry-After in [1, ceil(banMs/1000)]
    const res10 = await rawUpgradeRequest({
      host: lanIp,
      port,
      path: '/acp',
      headers: makeHdrs(10, 'Bearer wrong-token-value'),
    });
    assert.equal(res10.statusCode, 429);
    const ra10 = Number(res10.headers['retry-after']);
    assert.ok(Number.isInteger(ra10) && ra10 >= 1 && ra10 <= 300);

    // 11th request during ban with VALID token -> short-circuits to 429 and does NOT extend bannedUntil
    fakeNow += 50_000;
    const res11 = await rawUpgradeRequest({
      host: lanIp,
      port,
      path: '/acp',
      headers: makeHdrs(11, `Bearer ${token}`),
    });
    assert.equal(res11.statusCode, 429);
    const ra11 = Number(res11.headers['retry-after']);
    assert.ok(ra11 <= 250, `bannedUntil must not extend (got Retry-After=${ra11})`);

    // AC-21 (1): Advance past banMs -> valid token succeeds 101
    fakeNow += 260_000;
    const resUnbanned = await rawUpgradeRequest({
      host: lanIp,
      port,
      path: '/acp',
      headers: makeHdrs(12, `Bearer ${token}`),
    });
    assert.equal(resUnbanned.statusCode, 101);

    // AC-21 (2) & (3): sliding window expiration & success reset
    const rl = new AuthRateLimiter(
      { maxFailures: 10, windowMs: 600_000, banMs: 300_000, loopbackBackoffMs: 0, maxTrackedIps: 64 },
      () => fakeNow
    );
    const ipSlide = '198.51.100.20';
    for (let i = 0; i < 9; i++) {
      assert.equal(rl.recordFailure(ipSlide).allowed, true);
    }
    fakeNow += 600_001; // old 9 failures slide out of window
    const afterWindow = rl.recordFailure(ipSlide);
    assert.equal(afterWindow.allowed, true, 'old failures outside windowMs must expire');

    const ipReset = '198.51.100.21';
    for (let i = 0; i < 5; i++) assert.equal(rl.recordFailure(ipReset).allowed, true);
    rl.recordSuccess(ipReset);
    for (let i = 0; i < 9; i++) {
      assert.equal(rl.recordFailure(ipReset).allowed, true, `post-reset failure ${i + 1} should remain 401`);
    }
    assert.equal(rl.recordFailure(ipReset).banned, true);
  } finally {
    await transport.stop();
  }
});

test('AC-22 & AC-23: trustedProxies CIDR XFF right-to-left stripping, loopback never-ban backoff, and bounded LRU/expiry eviction (PP-22-isolate, PP-23-loopback)', async () => {
  const token = createTestToken(64);
  const cfg = createDefaultConfig();

  // Unit check right-to-left CIDR XFF parsing
  const cidrs = [parseTrustedProxyEntry('127.0.0.0/8')];
  assert.equal(resolveClientKey('127.0.0.1', '203.0.113.9', cidrs), '203.0.113.9');
  assert.equal(resolveClientKey('127.0.0.1', '1.1.1.1, 203.0.113.9', cidrs), '203.0.113.9');
  assert.equal(resolveClientKey('127.0.0.1', '127.0.0.2', cidrs), '127.0.0.1');
  assert.equal(resolveClientKey('127.0.0.1', 'not-an-ip', cidrs), '127.0.0.1');

  // Integration check with trustedProxies=["127.0.0.0/8"]
  const transportProxy = new WsServerTransport({
    host: '127.0.0.1',
    port: 0,
    allowNonLoopback: false,
    expectedToken: token,
    maxFrameBytes: 1024 * 1024,
    pingIntervalMs: 25000,
    pongTimeoutMs: 60000,
    trustedProxies: ['127.0.0.0/8'],
    rateLimit: { ...cfg.security.rateLimit, loopbackBackoffMs: 0 },
    getHealthState: () => ({ childAlive: false, activeClient: false }),
  });

  try {
    const { port } = await transportProxy.start();
    const hdr = (xff, auth) => ({
      Upgrade: 'websocket',
      Connection: 'Upgrade',
      'Sec-WebSocket-Version': '13',
      'Sec-WebSocket-Key': makeWsKey(),
      ...(xff ? { 'X-Forwarded-For': xff } : {}),
      Authorization: auth,
    });

    for (let i = 1; i <= 9; i++) {
      const xff = i % 2 === 0 ? '1.1.1.1, 203.0.113.9' : '203.0.113.9';
      const r = await rawUpgradeRequest({ host: '127.0.0.1', port, path: '/acp', headers: hdr(xff, 'Bearer bad') });
      assert.equal(r.statusCode, 401);
    }
    const banned = await rawUpgradeRequest({
      host: '127.0.0.1',
      port,
      path: '/acp',
      headers: hdr('1.1.1.1, 203.0.113.9', 'Bearer bad'),
    });
    assert.equal(banned.statusCode, 429);

    // Other visitor & direct loopback & all-trusted/invalid XFF remain unaffected
    for (const xff of ['198.51.100.7', '127.0.0.2', 'not-ip', undefined]) {
      const r = await rawUpgradeRequest({ host: '127.0.0.1', port, path: '/acp', headers: hdr(xff, `Bearer ${token}`) });
      assert.equal(r.statusCode, 101);
    }
  } finally {
    await transportProxy.stop();
  }

  // AC-23 (1): Loopback 20 failures with 200ms backoff -> all 401, no 429, 21st valid succeeds
  for (const backoffMs of [200, 0]) {
    const tLoop = new WsServerTransport({
      host: '127.0.0.1',
      port: 0,
      allowNonLoopback: false,
      expectedToken: token,
      maxFrameBytes: 1024 * 1024,
      pingIntervalMs: 25000,
      pongTimeoutMs: 60000,
      trustedProxies: [],
      rateLimit: { ...cfg.security.rateLimit, loopbackBackoffMs: backoffMs },
      getHealthState: () => ({ childAlive: false, activeClient: false }),
    });
    try {
      const { port } = await tLoop.start();
      const count = backoffMs === 200 ? 20 : 20;
      const startMs = Date.now();
      for (let i = 0; i < count; i++) {
        // Test elapsed timing on first failure with 200ms, fast-forward rest? No, 20 * 200ms = 4s total, real 20 attempts!
        const r = await rawUpgradeRequest({
          host: '127.0.0.1',
          port,
          path: '/acp',
          headers: {
            Upgrade: 'websocket',
            Connection: 'Upgrade',
            'Sec-WebSocket-Version': '13',
            'Sec-WebSocket-Key': makeWsKey(),
            Authorization: 'Bearer bad',
          },
        });
        assert.equal(r.statusCode, 401);
      }
      const elapsed = Date.now() - startMs;
      if (backoffMs === 200) {
        assert.ok(elapsed >= 3000, `20x 200ms loopback backoff should take >= 3000ms (got ${elapsed}ms)`);
      } else {
        assert.ok(elapsed < 1000, `0ms backoff should be fast (got ${elapsed}ms)`);
      }
      const okClient = await connectWs(`ws://127.0.0.1:${port}/acp`, token);
      okClient.close();
      await okClient.waitForClose();
    } finally {
      await tLoop.stop();
    }
  }

  // AC-23 (2): bounded maxTrackedIps=16 (evict expired before LRU) + concurrent IP tracking
  let now = 10_000;
  const bounded = new AuthRateLimiter(
    { maxFailures: 10, windowMs: 1000, banMs: 5000, loopbackBackoffMs: 0, maxTrackedIps: 16 },
    () => now
  );
  for (let i = 0; i < 8; i++) bounded.recordFailure(`203.0.113.${i + 1}`); // will expire
  now += 1500;
  for (let i = 0; i < 8; i++) bounded.recordFailure(`198.51.100.${i + 1}`); // active
  // Now 24 new IPs arrive -> expired 8 purged first, active LRU kept within <= 16
  for (let i = 0; i < 24; i++) bounded.recordFailure(`192.0.2.${i + 1}`);
  assert.ok(bounded.size() <= 16);

  // Concurrent failures on same IP via Promise.all
  const tConc = new WsServerTransport({
    host: '127.0.0.1',
    port: 0,
    allowNonLoopback: false,
    expectedToken: token,
    maxFrameBytes: 1024 * 1024,
    pingIntervalMs: 25000,
    pongTimeoutMs: 60000,
    trustedProxies: ['127.0.0.1'],
    rateLimit: { maxFailures: 10, windowMs: 60_000, banMs: 60_000, loopbackBackoffMs: 0, maxTrackedIps: 16 },
    getHealthState: () => ({ childAlive: false, activeClient: false }),
  });
  try {
    const { port } = await tConc.start();
    const responses = await Promise.all(
      Array.from({ length: 12 }, () =>
        rawUpgradeRequest({
          host: '127.0.0.1',
          port,
          path: '/acp',
          headers: {
            Upgrade: 'websocket',
            Connection: 'Upgrade',
            'Sec-WebSocket-Version': '13',
            'Sec-WebSocket-Key': makeWsKey(),
            'X-Forwarded-For': '203.0.113.77',
            Authorization: 'Bearer bad',
          },
        })
      )
    );
    assert.equal(responses.filter((r) => r.statusCode === 401).length, 9);
    assert.equal(responses.filter((r) => r.statusCode === 429).length, 3);
  } finally {
    await tConc.stop();
  }
});
