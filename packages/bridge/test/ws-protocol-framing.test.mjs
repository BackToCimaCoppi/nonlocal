import test from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { createDefaultConfig } from '../dist/config/schema.js';
import { WsServerTransport } from '../dist/transport/ws-server-transport.js';
import { NonlocalGateway } from '../dist/gateway/gateway.js';
import { StateStore } from '../dist/store/state-store.js';
import { SanitizedLogger } from '../dist/log/logger.js';
import { FakeTestAdapter } from './helpers/fake-adapter.mjs';
import {
  buildRawClientFrame,
  connectWs,
  openRawWsSocket,
  parseFirstCloseCode,
} from './helpers/ws-client.mjs';
import { createTestToken, makeTempDir, rmTempDir } from './helpers/test-utils.mjs';

async function sendBadFrameExpectClose(port, token, frameBytes) {
  const { socket, leftover } = await openRawWsSocket({ host: '127.0.0.1', port, token });
  const chunks = leftover && leftover.length > 0 ? [leftover] : [];
  return await new Promise((resolve, reject) => {
    let settled = false;
    const finish = (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      resolve(code);
    };
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      socket.destroy();
      reject(new Error('timeout waiting for close frame'));
    }, 3000);
    const immediate = parseFirstCloseCode(Buffer.concat(chunks));
    if (immediate !== null) {
      finish(immediate);
      return;
    }
    socket.on('data', (c) => {
      chunks.push(c);
      const code = parseFirstCloseCode(Buffer.concat(chunks));
      if (code !== null) {
        finish(code);
      }
    });
    socket.on('close', () => {
      finish(parseFirstCloseCode(Buffer.concat(chunks)));
    });
    socket.on('error', () => {});
    socket.write(frameBytes);
  });
}

test('AC-24 (transport part): zero pseudo-welcome frame, WS close codes 1009/1003/1007/1002', async () => {
  const root = makeTempDir('nonlocal-ws-ac24-');
  const token = createTestToken(64);
  const cfg = createDefaultConfig(process.env, root);
  cfg.server.maxFrameBytes = 1024;
  cfg.state.dir = join(root, 'state');
  cfg.state.logFile = join(root, 'state', 'bridge.log');

  const store = new StateStore({ stateDir: cfg.state.dir });
  const logger = new SanitizedLogger({ logFile: cfg.state.logFile, redactSecrets: [token] });
  const adapter = new FakeTestAdapter();
  const transport = new WsServerTransport({
    host: '127.0.0.1',
    port: 0,
    allowNonLoopback: false,
    expectedToken: token,
    maxFrameBytes: cfg.server.maxFrameBytes,
    pingIntervalMs: 25000,
    pongTimeoutMs: 60000,
    rateLimit: cfg.security.rateLimit,
    getHealthState: () => ({ childAlive: false, activeClient: false }),
    logger,
  });
  const gateway = new NonlocalGateway({ config: cfg, transport, adapter, store, logger });

  try {
    const { port } = await gateway.start();

    // 0. Zero pseudo-welcome frame after handshake
    const probe = await connectWs(`ws://127.0.0.1:${port}/acp`, token);
    await new Promise((r) => setTimeout(r, 80));
    assert.equal(probe.messages.length, 0);
    probe.close();
    await probe.waitForClose();

    // 1. Single frame > maxFrameBytes -> 1009
    assert.equal(
      await sendBadFrameExpectClose(
        port,
        token,
        buildRawClientFrame({ fin: true, opcode: 0x1, payload: Buffer.alloc(1025, 0x41) })
      ),
      1009
    );

    // 2. Multi-fragment sum > maxFrameBytes -> 1009
    const frag1 = buildRawClientFrame({ fin: false, opcode: 0x1, payload: Buffer.alloc(600, 0x41) });
    const frag2 = buildRawClientFrame({ fin: true, opcode: 0x0, payload: Buffer.alloc(600, 0x42) });
    assert.equal(await sendBadFrameExpectClose(port, token, Buffer.concat([frag1, frag2])), 1009);

    // 3. Binary frame -> 1003
    assert.equal(
      await sendBadFrameExpectClose(
        port,
        token,
        buildRawClientFrame({ fin: true, opcode: 0x2, payload: Buffer.from([1, 2, 3]) })
      ),
      1003
    );

    // 4. Single-frame invalid UTF-8 -> 1007
    assert.equal(
      await sendBadFrameExpectClose(
        port,
        token,
        buildRawClientFrame({ fin: true, opcode: 0x1, payload: Buffer.from([0xff, 0xfe]) })
      ),
      1007
    );

    // 5. Cross-fragment invalid UTF-8 -> 1007
    const u1 = buildRawClientFrame({ fin: false, opcode: 0x1, payload: Buffer.from([0xe4, 0xb8]) });
    const u2 = buildRawClientFrame({ fin: true, opcode: 0x0, payload: Buffer.from([0x20]) });
    assert.equal(await sendBadFrameExpectClose(port, token, Buffer.concat([u1, u2])), 1007);

    // 6. Unmasked client frame -> 1002
    assert.equal(
      await sendBadFrameExpectClose(
        port,
        token,
        buildRawClientFrame({ fin: true, opcode: 0x1, masked: false, payload: 'hi' })
      ),
      1002
    );

    // 7. Non-zero RSV -> 1002
    assert.equal(
      await sendBadFrameExpectClose(
        port,
        token,
        buildRawClientFrame({ fin: true, rsv: 1, opcode: 0x1, payload: 'hi' })
      ),
      1002
    );

    // 8. Unsupported opcode (0x3) -> 1002
    assert.equal(
      await sendBadFrameExpectClose(
        port,
        token,
        buildRawClientFrame({ fin: true, opcode: 0x3, payload: 'hi' })
      ),
      1002
    );
  } finally {
    await gateway.stop();
    rmTempDir(root);
  }
});

test('AC-25 (transport part) & AC-26: Ping/Pong timeout 1001, ECONNRESET resilience, shutdown 1001, JSON-RPC -32700/-32600 zero spawn', async () => {
  const root = makeTempDir('nonlocal-ws-ac25-');
  const token = createTestToken(64);
  const cfg = createDefaultConfig(process.env, root);
  cfg.state.dir = join(root, 'state');
  cfg.state.logFile = join(root, 'state', 'bridge.log');

  const store = new StateStore({ stateDir: cfg.state.dir });
  const logger = new SanitizedLogger({ logFile: cfg.state.logFile, redactSecrets: [token] });
  const adapter = new FakeTestAdapter();
  const transport = new WsServerTransport({
    host: '127.0.0.1',
    port: 0,
    allowNonLoopback: false,
    expectedToken: token,
    maxFrameBytes: cfg.server.maxFrameBytes,
    pingIntervalMs: 80,
    pongTimeoutMs: 180,
    rateLimit: cfg.security.rateLimit,
    getHealthState: () => ({ childAlive: false, activeClient: false }),
    logger,
  });
  const gateway = new NonlocalGateway({ config: cfg, transport, adapter, store, logger });

  try {
    const { port } = await gateway.start();

    // AC-26: invalid JSON / array / no-method non-matching id -> -32700 / -32600 with ZERO adapter dispatches
    const c = await connectWs(`ws://127.0.0.1:${port}/acp`, token);
    c.ws.send('{bad-json');
    const rParse = await c.waitFor((m) => m.error?.code === -32700);
    assert.equal(rParse.id, null);

    c.sendJson([]);
    const rArr = await c.waitFor((m) => m.error?.code === -32600);
    assert.equal(rArr.id, null);

    c.sendJson({ jsonrpc: '2.0', id: 999, result: {} });
    const rNoMethod = await c.waitFor((m) => m.error?.code === -32600);
    assert.equal(rNoMethod.id, null);
    assert.equal(adapter.dispatchedRequests.length, 0);

    // AC-25: client Ping -> server Pong with identical payload
    const pongPromise = new Promise((resolve) => c.ws.once('pong', (d) => resolve(d.toString('utf8'))));
    c.ws.ping('hello-ping');
    assert.equal(await pongPromise, 'hello-ping');
    c.close();
    await c.waitForClose();

    // AC-25: Server sends 'ka' Ping and closes 1001(ping_timeout) when client stops replying Pong
    const { socket: silentSock } = await openRawWsSocket({ host: '127.0.0.1', port, token });
    const silentChunks = [];
    const silentRes = await new Promise((resolve) => {
      silentSock.on('data', (d) => silentChunks.push(d));
      silentSock.on('close', () => resolve(Buffer.concat(silentChunks)));
      silentSock.on('error', () => {});
    });
    assert.equal(silentRes.includes(Buffer.from('ka', 'utf8')), true);
    assert.equal(parseFirstCloseCode(silentRes), 1001);

    // AC-25: TCP RST (ECONNRESET) keeps bridge alive and accepts next client
    const { socket: rstSock } = await openRawWsSocket({ host: '127.0.0.1', port, token });
    rstSock.resetAndDestroy?.() ?? rstSock.destroy();
    await new Promise((r) => setTimeout(r, 40));

    const c2 = await connectWs(`ws://127.0.0.1:${port}/acp`, token);
    c2.sendJson({ jsonrpc: '2.0', id: 2, method: 'nonlocal/sync', params: {} });
    const syncRes = await c2.waitFor((m) => m.id === 2);
    assert.ok(syncRes.result.instanceId);

    // Graceful shutdown sends 1001('bridge_shutting_down')
    const closePromise = c2.waitForClose();
    await gateway.stop('test_shutdown');
    const closeInfo = await closePromise;
    assert.equal(closeInfo.code, 1001);
    assert.equal(closeInfo.reason, 'bridge_shutting_down');
  } finally {
    await gateway.stop();
    rmTempDir(root);
  }
});

test('AC-24 & AC-25 (adapter part): NDJSON cross-chunk UTF-8 byte splitting and SIGTERM process-group grandchild cleanup', async () => {
  const { readFileSync, existsSync } = await import('node:fs');
  const { fileURLToPath } = await import('node:url');
  const { BaseAcpAdapter } = await import('../dist/adapter/base-acp-adapter.js');
  const fakeServer = fileURLToPath(new URL('./helpers/fake-acp-server.mjs', import.meta.url));

  const root = makeTempDir('nonlocal-ndjson-ac24-');
  const grandchildPidFile = join(root, 'grandchild.pid');
  const token = createTestToken(64);
  const cfg = createDefaultConfig(process.env, root);
  cfg.state.dir = join(root, 'state');
  cfg.state.logFile = join(root, 'state', 'bridge.log');
  cfg.adapter.type = 'generic-acp';
  cfg.adapter.command = process.execPath;
  cfg.adapter.args = [fakeServer];
  cfg.adapter.fallbackCwd = root;
  cfg.adapter.childStopGraceMs = 150;

  const store = new StateStore({ stateDir: cfg.state.dir });
  const logger = new SanitizedLogger({ logFile: cfg.state.logFile, redactSecrets: [token] });
  const adapter = new BaseAcpAdapter({ adapterConfig: cfg.adapter, syncConfig: cfg.sync, logger });
  const gateway = new NonlocalGateway({
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
  const prevPidFile = process.env.FAKE_ACP_GRANDCHILD_PID_FILE;
  process.env.FAKE_ACP_MODE = 'split_utf8_and_permission';
  process.env.FAKE_ACP_GRANDCHILD_PID_FILE = grandchildPidFile;

  let grandchildPid = 0;
  try {
    const { port } = await gateway.start();
    const c = await connectWs(`ws://127.0.0.1:${port}/acp`, token);
    c.sendJson({ jsonrpc: '2.0', id: 1, method: 'session/new', params: { cwd: root, forcedId: 's-utf8' } });
    await c.waitFor((m) => m.id === 1);
    c.sendJson({ jsonrpc: '2.0', id: 2, method: 'session/prompt', params: { sessionId: 's-utf8', prompt: [{ type: 'text', text: 'split' }] } });
    const chunkMsg = await c.waitFor((m) => m.params?.update?.sessionUpdate === 'agent_message_chunk');
    assert.equal(chunkMsg.params.update.content.text, '中文Split中测试');
    await c.waitFor((m) => m.id === 2);

    assert.equal(existsSync(grandchildPidFile), true);
    grandchildPid = Number(readFileSync(grandchildPidFile, 'utf8').trim());
    assert.ok(grandchildPid > 0);
    // Grandchild should currently be alive
    assert.doesNotThrow(() => process.kill(grandchildPid, 0));

    c.close();
    await c.waitForClose();
    await gateway.stop();

    // After adapter stop (-pid SIGTERM process group), grandchild MUST also be dead!
    await new Promise((r) => setTimeout(r, 80));
    assert.throws(() => process.kill(grandchildPid, 0), /ESRCH/);
  } finally {
    if (prevMode === undefined) delete process.env.FAKE_ACP_MODE;
    else process.env.FAKE_ACP_MODE = prevMode;
    if (prevPidFile === undefined) delete process.env.FAKE_ACP_GRANDCHILD_PID_FILE;
    else process.env.FAKE_ACP_GRANDCHILD_PID_FILE = prevPidFile;
    if (grandchildPid > 0) {
      try {
        process.kill(grandchildPid, 'SIGKILL');
      } catch {
        // already dead
      }
    }
    await gateway.stop();
    rmTempDir(root);
  }
});
