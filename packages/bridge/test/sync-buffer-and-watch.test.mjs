import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createDefaultConfig } from '../dist/config/schema.js';
import { WsServerTransport } from '../dist/transport/ws-server-transport.js';
import { NonlocalGateway } from '../dist/gateway/gateway.js';
import { StateStore } from '../dist/store/state-store.js';
import { SanitizedLogger } from '../dist/log/logger.js';
import { SessionSyncManager } from '../dist/sync/session-sync-manager.js';
import { FakeTestAdapter } from './helpers/fake-adapter.mjs';
import { connectWs } from './helpers/ws-client.mjs';
import { createTestToken, makeTempDir, rmTempDir } from './helpers/test-utils.mjs';

test('AC-29 & AC-65: active/completed/error nonlocal/sync shapes, handshake window isolation, monotonic seq, and cross-session stream isolation', async () => {
  const root = makeTempDir('nonlocal-sync-ac29-');
  const token = createTestToken(64);
  const cfg = createDefaultConfig(process.env, root);
  cfg.state.dir = join(root, 'state');
  cfg.state.logFile = join(root, 'state', 'bridge.log');

  const store = new StateStore({ stateDir: cfg.state.dir });
  const logger = new SanitizedLogger({ logFile: cfg.state.logFile, redactSecrets: [token] });

  let finishPromptA = null;
  const adapter = new FakeTestAdapter({
    onDispatch: async (req, self) => {
      if (req.method === 'session/new') {
        const sid = req.rawMessage.params.tag === 'B' ? 'sess-b' : 'sess-a';
        self.loadedSessions.add(sid);
        self.host.onAdapterMessage({
          kind: 'response',
          connId: req.connId,
          clientReqId: req.clientReqId,
          method: req.method,
          canonicalCwd: root,
          message: {
            jsonrpc: '2.0',
            id: req.clientReqId,
            result: {
              sessionId: sid,
              cwd: root,
              modes: { currentModeId: 'ask', availableModes: [{ id: 'ask' }] },
              models: { currentModelId: 'm1', availableModels: [{ modelId: 'm1' }] },
              configOptions: [{ id: 'model', currentValue: 'm1' }],
            },
          },
        });
        return;
      }
      if (req.method === 'session/prompt') {
        if (req.sessionId === 'sess-b') {
          self.host.onAdapterMessage({
            kind: 'response',
            connId: req.connId,
            clientReqId: req.clientReqId,
            method: req.method,
            sessionId: req.sessionId,
            canonicalCwd: root,
            message: { jsonrpc: '2.0', id: req.clientReqId, error: { code: -32005, message: 'RPC failed' } },
          });
          return;
        }
        // Emit thought, tool_call, plan, and server permission request
        for (const update of [
          { sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text: 'SECRET_THOUGHT_PLAN' } },
          { sessionUpdate: 'tool_call', toolCallId: 'tc-1', status: 'completed', title: 'read' },
          { sessionUpdate: 'plan', entries: [{ content: 'step1', status: 'completed' }] },
        ]) {
          self.host.onAdapterMessage({
            kind: 'notification',
            sessionId: req.sessionId,
            canonicalCwd: root,
            message: {
              jsonrpc: '2.0',
              method: 'session/update',
              params: { sessionId: req.sessionId, update },
            },
          });
        }
        self.host.onAdapterMessage({
          kind: 'server_request',
          sessionId: req.sessionId,
          canonicalCwd: root,
          message: {
            jsonrpc: '2.0',
            id: 'w1_s1_99',
            method: 'session/request_permission',
            params: { sessionId: req.sessionId, options: [{ optionId: 'allow' }] },
          },
        });
        finishPromptA = () => {
          self.host.onAdapterMessage({
            kind: 'notification',
            sessionId: req.sessionId,
            canonicalCwd: root,
            message: {
              jsonrpc: '2.0',
              method: 'session/update',
              params: {
                sessionId: req.sessionId,
                update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'SECRET_STREAM_REPLY' } },
              },
            },
          });
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
    c1.sendJson({ jsonrpc: '2.0', id: 1, method: 'nonlocal/sync', params: {} });
    await c1.waitFor((m) => m.id === 1);

    c1.sendJson({ jsonrpc: '2.0', id: 2, method: 'session/new', params: { cwd: root, tag: 'A' } });
    await c1.waitFor((m) => m.id === 2);
    c1.sendJson({ jsonrpc: '2.0', id: 3, method: 'session/new', params: { cwd: root, tag: 'B' } });
    await c1.waitFor((m) => m.id === 3);

    c1.sendJson({
      jsonrpc: '2.0',
      id: 4,
      method: 'session/prompt',
      params: {
        sessionId: 'sess-a',
        prompt: [{ type: 'text', text: 'SECRET_USER_PROMPT_AC29' }],
        _meta: { nonlocalClientTurnId: 'ct-1' },
      },
    });

    const u1 = await c1.waitFor((m) => m.params?.update?.sessionUpdate === 'agent_thought_chunk');
    const u2 = await c1.waitFor((m) => m.params?.update?.sessionUpdate === 'tool_call');
    const u3 = await c1.waitFor((m) => m.params?.update?.sessionUpdate === 'plan');
    const permReq = await c1.waitFor((m) => m.method === 'session/request_permission');
    assert.match(permReq.id, /^w\d+_s\d+_/);
    assert.ok(u1.params._meta.nonlocalSeq < u2.params._meta.nonlocalSeq);
    assert.ok(u2.params._meta.nonlocalSeq < u3.params._meta.nonlocalSeq);
    assert.equal(u1.params._meta.nonlocalTurnId, u2.params._meta.nonlocalTurnId);

    // Reconnect C2 without calling nonlocal/sync yet -> handshake window suppresses live turn updates
    c1.close();
    await c1.waitForClose();
    const c2 = await connectWs(url, token);
    adapter.host.onAdapterMessage({
      kind: 'notification',
      sessionId: 'sess-a',
      canonicalCwd: root,
      message: {
        jsonrpc: '2.0',
        method: 'session/update',
        params: {
          sessionId: 'sess-a',
          update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'offline-chunk' } },
        },
      },
    });
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(c2.messages.length, 0, 'suppressedHandshakeWindow must block events before nonlocal/sync');

    // Call nonlocal/sync while turn is ACTIVE
    c2.sendJson({ jsonrpc: '2.0', id: 10, method: 'nonlocal/sync', params: {} });
    const syncActive = await c2.waitFor((m) => m.id === 10);
    const snapA = syncActive.result.sessions.find((s) => s.sessionId === 'sess-a');
    assert.equal('models' in snapA, false);
    assert.equal('watchBaselineMs' in snapA, false);
    assert.equal(snapA.latestTurn.status, 'active');
    assert.equal(snapA.latestTurn.clientTurnId, 'ct-1');
    assert.equal(snapA.latestTurn.stopReason, undefined);
    assert.equal(snapA.latestTurn.hasUnresolvedToolCalls, undefined);
    assert.equal(snapA.latestTurn.truncated, false);
    assert.equal(snapA.latestTurn.pendingPermissions.length, 1);
    assert.match(snapA.latestTurn.pendingPermissions[0].requestId, /^w\d+_s\d+_/);

    // Approve permission -> requestId vanishes
    c2.sendJson({ jsonrpc: '2.0', id: permReq.id, result: { outcome: { outcome: 'selected', optionId: 'allow' } } });
    await new Promise((r) => setTimeout(r, 30));
    c2.sendJson({ jsonrpc: '2.0', id: 11, method: 'nonlocal/sync', params: {} });
    const syncApproved = await c2.waitFor((m) => m.id === 11);
    assert.equal(
      syncApproved.result.sessions.find((s) => s.sessionId === 'sess-a').latestTurn.pendingPermissions.length,
      0
    );

    // AC-65 (1): finish prompt A & check completed shape
    finishPromptA();
    await c2.waitFor((m) => m.method === 'nonlocal/turn_completed');
    c2.sendJson({ jsonrpc: '2.0', id: 12, method: 'nonlocal/sync', params: {} });
    const syncCompleted = await c2.waitFor((m) => m.id === 12);
    const doneTurn = syncCompleted.result.sessions.find((s) => s.sessionId === 'sess-a').latestTurn;
    assert.equal(doneTurn.status, 'completed');
    assert.equal(doneTurn.stopReason, 'end_turn');
    assert.equal(doneTurn.error, undefined);
    assert.deepEqual(doneTurn.pendingPermissions, []);
    assert.ok(doneTurn.events.some((e) => e.params?.update?.content?.text === 'offline-chunk'));

    // AC-65 (2): session B RPC error -> error latestTurn shape
    c2.sendJson({
      jsonrpc: '2.0',
      id: 13,
      method: 'session/prompt',
      params: { sessionId: 'sess-b', prompt: [{ type: 'text', text: 'fail' }] },
    });
    await c2.waitFor((m) => m.id === 13 && m.error);
    c2.sendJson({ jsonrpc: '2.0', id: 14, method: 'nonlocal/sync', params: {} });
    const syncErr = await c2.waitFor((m) => m.id === 14);
    const errTurn = syncErr.result.sessions.find((s) => s.sessionId === 'sess-b').latestTurn;
    assert.equal(errTurn.status, 'error');
    assert.deepEqual(errTurn.error, { code: -32005, message: 'RPC failed' });
    assert.deepEqual(errTurn.pendingPermissions, []);

    const logText = readFileSync(cfg.state.logFile, 'utf8');
    assert.equal(logText.includes('SECRET_USER_PROMPT_AC29'), false);
    assert.equal(logText.includes('SECRET_STREAM_REPLY'), false);
    c2.close();
    await c2.waitForClose();
  } finally {
    await gateway.stop();
    rmTempDir(root);
  }
});

test('AC-30, AC-31, AC-66: buffer FIFO truncation, worker crash isolation, #4c watch convergence, #4a dual-clock & #4d stale invariants', async () => {
  // AC-30 (1): maxEventsPerTurn=5 and maxTurnBytes=2048 FIFO truncation
  for (const opts of [{ maxEventsPerTurn: 5, maxTurnBytes: 1024 * 1024 }, { maxEventsPerTurn: 100, maxTurnBytes: 512 }]) {
    const sync = new SessionSyncManager(opts);
    sync.markSessionMaterialized('s1', '/tmp');
    sync.observeClientRequest('u1', { method: 'session/prompt', params: { sessionId: 's1' } }, 1);
    sync.observeUpstreamMessage({
      jsonrpc: '2.0',
      id: 'w1_s1_1',
      method: 'session/request_permission',
      params: { sessionId: 's1' },
    });
    for (let i = 0; i < 12; i++) {
      sync.observeUpstreamMessage({
        jsonrpc: '2.0',
        method: 'session/update',
        params: {
          sessionId: 's1',
          update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'X'.repeat(60) + i } },
        },
      });
    }
    const snap = sync.buildSyncSnapshot().sessions[0].latestTurn;
    assert.equal(snap.truncated, true);
    assert.equal(snap.lastSeq, 12);
    assert.equal(snap.events[snap.events.length - 1].seq, 12);
    assert.equal(snap.status, 'active');
    assert.equal(snap.pendingPermissions.length, 1);
  }

  // AC-30 (2): worker crash isolation (dirA crashes, dirB stays materialized)
  const syncCrash = new SessionSyncManager();
  syncCrash.markSessionMaterialized('dirA-s1', '/tmp/a');
  syncCrash.markSessionMaterialized('dirB-s1', '/tmp/b');
  syncCrash.observeClientRequest('uA', { method: 'session/prompt', params: { sessionId: 'dirA-s1' } }, 1);
  const comps = syncCrash.markSessionsExited(['dirA-s1']);
  assert.equal(comps.length, 1);
  assert.equal(comps[0].status, 'error');
  assert.ok(comps[0].error.code);
  const snapAfterCrash = syncCrash.buildSyncSnapshot();
  assert.equal(snapAfterCrash.materializedSessionIds.includes('dirA-s1'), false);
  assert.equal(snapAfterCrash.materializedSessionIds.includes('dirB-s1'), true);

  // AC-31: #4c watch 5m convergence, no duplicate push on identical updatedAt, offline update marks stale
  let now = 1_000_000;
  const syncWatch = new SessionSyncManager({ watchWindowMs: 5000, settleWindowMs: 2000 });
  syncWatch.markSessionMaterialized('sw-1', '/tmp/a');
  syncWatch.observeClientRequest('uw', { method: 'session/prompt', params: { sessionId: 'sw-1' } }, 1);
  syncWatch.observeUpstreamMessage({
    jsonrpc: '2.0',
    method: 'session/update',
    params: { sessionId: 'sw-1', update: { sessionUpdate: 'tool_call', toolCallId: 'tc-open', status: 'in_progress' } },
  });
  const promptDone = syncWatch.observeUpstreamMessage({
    jsonrpc: '2.0',
    id: 'uw',
    result: { stopReason: 'end_turn' },
  });
  assert.equal(promptDone.needsWatch, true);
  assert.equal(syncWatch.isSessionWatched('sw-1'), true);

  // Polling another directory does NOT clear watchUntilMs for /tmp/a
  syncWatch.observeSessionList([], Date.now(), { scopeSessionIds: new Set(['other-dir-session']) });
  assert.equal(syncWatch.isSessionWatched('sw-1'), true);

  // First updatedAt advance pushes stale once; second identical updatedAt pushes 0 times
  const futureIso = new Date(Date.now() + 10_000).toISOString();
  const s1 = syncWatch.observeSessionList([{ sessionId: 'sw-1', updatedAt: futureIso }], Date.now());
  assert.equal(s1.length, 1);
  assert.equal(s1[0].reason, 'background_updated');
  const s2 = syncWatch.observeSessionList([{ sessionId: 'sw-1', updatedAt: futureIso }], Date.now() + 100);
  assert.equal(s2.length, 0);

  // Past watchWindowMs converges hasUnresolvedToolCalls to false
  const convergedSnap = syncWatch.buildSyncSnapshot(Date.now() + 10_000);
  assert.equal(syncWatch.isSessionWatched('sw-1', Date.now() + 10_000), false);
  assert.equal(convergedSnap.sessions[0].latestTurn?.hasUnresolvedToolCalls, undefined);

  // Offline post-prompt update immediately marks stale
  const syncOff = new SessionSyncManager();
  syncOff.markSessionMaterialized('off-1', '/tmp');
  syncOff.recordOfflineSessionUpdate('off-1', now, { updateType: 'agent_message_chunk' });
  const offSnap = syncOff.buildSyncSnapshot(now);
  assert.equal(offSnap.materializedSessionIds.includes('off-1'), false);
  assert.equal(offSnap.staleSessionIds.includes('off-1'), true);

  // AC-66: #4a dual clock & #4d 8 branches
  const sync4d = new SessionSyncManager();
  sync4d.markSessionMaterialized('s4d', '/tmp');
  const beforeSnap = sync4d.buildSyncSnapshot(now);
  assert.equal(beforeSnap.sessions[0].lastActivityAt, undefined);

  // Non-content updates do NOT touch lastActivityAt and do NOT arm #4d
  for (const ut of ['usage_update', 'config_option_update', 'agent_thought_chunk', 'plan']) {
    sync4d.recordLiveSessionUpdate('s4d', now + 1000, { connId: 1, updateType: ut });
  }
  assert.equal(sync4d.buildSyncSnapshot(now + 1000).sessions[0].lastActivityAt, undefined);
  sync4d.handleConnectionClosed(1, { code: 1006, preempted: false });
  assert.equal(sync4d.buildSyncSnapshot(now + 1000).staleSessionIds.includes('s4d'), false);

  // Visible content update arms #4d; normal code 1000 close does NOT mark stale
  sync4d.recordLiveSessionUpdate('s4d', now + 2000, { connId: 2, updateType: 'agent_message_chunk' });
  assert.ok(sync4d.buildSyncSnapshot(now + 2000).sessions[0].lastActivityAt);
  sync4d.handleConnectionClosed(2, { code: 1000, preempted: false });
  assert.equal(sync4d.buildSyncSnapshot(now + 2000).staleSessionIds.includes('s4d'), false);

  // confirmSessionLoaded clears #4d so subsequent abnormal disconnect does NOT mark stale
  sync4d.recordLiveSessionUpdate('s4d', now + 3000, { connId: 3, updateType: 'tool_call' });
  sync4d.confirmSessionLoaded('s4d', 3);
  sync4d.handleConnectionClosed(3, { code: 1006, preempted: false });
  assert.equal(sync4d.buildSyncSnapshot(now + 3000).staleSessionIds.includes('s4d'), false);

  // Unconfirmed abnormal close, 4001 preemption, and markSessionsExited mark stale & clear non-active latestTurn
  for (const branch of ['abnormal', 'preempt', 'worker_exit']) {
    sync4d.markSessionMaterialized('s4d', '/tmp');
    sync4d.observeClientRequest('up', { method: 'session/prompt', params: { sessionId: 's4d' } }, 4);
    sync4d.observeUpstreamMessage({ jsonrpc: '2.0', id: 'up', result: { stopReason: 'end_turn' } });
    sync4d.recordLiveSessionUpdate('s4d', now + 4000, { connId: 4, updateType: 'agent_message_chunk' });
    if (branch === 'abnormal') sync4d.handleConnectionClosed(4, { code: 1006, preempted: false });
    if (branch === 'preempt') sync4d.handleConnectionClosed(4, { code: 4001, preempted: true });
    if (branch === 'worker_exit') sync4d.markSessionsExited(['s4d']);
    const after = sync4d.buildSyncSnapshot(now + 4000);
    assert.equal(after.staleSessionIds.includes('s4d'), true, `branch ${branch} must mark stale`);
    assert.equal(after.materializedSessionIds.includes('s4d'), false);
    assert.equal(after.sessions[0].latestTurn, undefined);
  }

  // Explicit session/load restores materialized and clears stale
  sync4d.observeUpstreamMessage(
    { jsonrpc: '2.0', id: 'ul', result: { sessionId: 's4d' } },
    { method: 'session/load', cwd: '/tmp' }
  );
  const restoredSnap = sync4d.buildSyncSnapshot(now + 5000);
  assert.equal(restoredSnap.materializedSessionIds.includes('s4d'), true);
  assert.equal(restoredSnap.staleSessionIds.includes('s4d'), false);
});
