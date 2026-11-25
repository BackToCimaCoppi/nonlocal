import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { createDefaultConfig } from '../dist/config/schema.js';
import { WsServerTransport } from '../dist/transport/ws-server-transport.js';
import { NonlocalGateway } from '../dist/gateway/gateway.js';
import { StateStore } from '../dist/store/state-store.js';
import { SanitizedLogger } from '../dist/log/logger.js';
import { FakeTestAdapter } from './helpers/fake-adapter.mjs';
import { startMockOpenAiServer } from './helpers/mock-openai.mjs';
import { connectWs } from './helpers/ws-client.mjs';
import { createTestToken, makeTempDir, rmTempDir } from './helpers/test-utils.mjs';

test('AC-40: closed allowlist, no-id silent drops, capability-probe isolation, wire title:null sanitization, and deleted load notification', async () => {
  const root = makeTempDir('nonlocal-allow-ac40-');
  const token = createTestToken(64);
  const cfg = createDefaultConfig(process.env, root);
  cfg.state.dir = join(root, 'state');
  cfg.state.logFile = join(root, 'state', 'bridge.log');

  const store = new StateStore({ stateDir: cfg.state.dir });
  const logger = new SanitizedLogger({ logFile: cfg.state.logFile, redactSecrets: [token] });

  const upstreamSent = [];
  const adapter = new FakeTestAdapter({
    capabilities: { usage: false, sessionInfo: false, deleteSession: false, diskPresence: true },
    onDispatch: async (req, self) => {
      upstreamSent.push(req);
      if (req.method === 'session/new' || req.method === 'session/create') {
        const sid = req.rawMessage.params.forcedId || 'own-1';
        self.loadedSessions.add(sid);
        self.diskPresentSet.add(sid);
        if (req.rawMessage.params.disconnectBeforeReply) {
          await new Promise((r) => setTimeout(r, 80));
        }
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
              title: 'Raw English',
              rawTitle: 'Raw English',
              prompt: 'secret',
            },
          },
        });
        return;
      }
      if (req.method === 'session/load' || req.method === 'session/resume') {
        self.host.onAdapterMessage({
          kind: 'response',
          connId: req.connId,
          clientReqId: req.clientReqId,
          method: req.method,
          sessionId: req.sessionId,
          canonicalCwd: root,
          message: {
            jsonrpc: '2.0',
            id: req.clientReqId,
            result: { sessionId: req.sessionId, title: 'Raw English', rawTitle: 'Raw English', prompt: 'secret' },
          },
        });
        return;
      }
      if (req.method === 'session/list') {
        self.host.onAdapterMessage({
          kind: 'response',
          connId: req.connId,
          clientReqId: req.clientReqId,
          method: req.method,
          canonicalCwd: req.rawMessage.params.cwd || null,
          message: {
            jsonrpc: '2.0',
            id: req.clientReqId,
            result: {
              sessions: [
                { sessionId: 'ext-1', cwd: root, updatedAt: '2026-11-23T00:00:00Z', title: 'Raw English', prompt: 'secret' },
                { sessionId: 'own-1', cwd: root, updatedAt: '2026-11-23T01:00:00Z', title: 'Raw English', rawTitle: 'Raw English', prompt: 'secret' },
              ],
            },
          },
        });
        return;
      }
      if (req.sessionId === 'capability-probe') {
        self.host.onAdapterMessage({
          kind: 'notification',
          sessionId: 'capability-probe',
          message: {
            jsonrpc: '2.0',
            method: 'session/update',
            params: { sessionId: 'capability-probe', update: { sessionUpdate: 'config_option_update', configOptions: [{ id: 'x' }] } },
          },
        });
        self.host.onAdapterMessage({
          kind: 'response',
          connId: req.connId,
          clientReqId: req.clientReqId,
          method: req.method,
          sessionId: 'capability-probe',
          message: { jsonrpc: '2.0', id: req.clientReqId, result: { probeOk: true } },
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
    getHealthState: () => ({ childAlive: true, activeClient: true }),
    logger,
  });
  const gateway = new NonlocalGateway({ config: cfg, transport, adapter, store, logger });

  try {
    const { port } = await gateway.start();
    const url = `ws://127.0.0.1:${port}/acp`;
    const c = await connectWs(url, token);
    c.sendJson({ jsonrpc: '2.0', id: 1, method: 'nonlocal/sync', params: {} });
    await c.waitFor((m) => m.id === 1);

    // 1. ext-1 & missing sessionId blocked with -32602; no-id external notification silent
    let rpcId = 10;
    for (const method of ['session/prompt', 'session/load', 'session/resume', 'session/set_model', 'session/set_config_option', 'session/set_mode', 'session/cancel', 'session/fork', 'nonlocal/rename_session']) {
      const id = ++rpcId;
      c.sendJson({ jsonrpc: '2.0', id, method, params: { sessionId: 'ext-1', title: 'x' } });
      const err = await c.waitFor((m) => m.id === id);
      assert.equal(err.error.code, -32602, `${method} on ext-1 must return -32602`);
    }
    const noSidId = ++rpcId;
    c.sendJson({ jsonrpc: '2.0', id: noSidId, method: 'session/prompt', params: {} });
    assert.equal((await c.waitFor((m) => m.id === noSidId)).error.code, -32602);
    c.sendJson({ jsonrpc: '2.0', method: 'session/prompt', params: { sessionId: 'ext-1' } });

    // 2. capability-probe passes through without persisting or leaking into sync
    c.sendJson({ jsonrpc: '2.0', id: 30, method: 'session/prompt', params: { sessionId: 'capability-probe', prompt: 'hi' } });
    const probeRes = await c.waitFor((m) => m.id === 30);
    assert.equal(probeRes.result.probeOk, true);
    assert.equal(store.has('capability-probe'), false);

    // 4. Create own-1 and verify wire title: null & prompt/rawTitle removed across new/load/resume/list/sync/session_info_update
    c.sendJson({ jsonrpc: '2.0', id: 31, method: 'session/new', params: { cwd: root } });
    const newRes = await c.waitFor((m) => m.id === 31);
    assert.equal('title' in newRes.result, true);
    assert.equal(newRes.result.title, null);
    assert.equal(newRes.result.prompt, undefined);
    assert.equal(newRes.result.rawTitle, undefined);

    c.sendJson({ jsonrpc: '2.0', id: 32, method: 'session/load', params: { sessionId: 'own-1', cwd: root } });
    const loadRes = await c.waitFor((m) => m.id === 32);
    assert.equal(loadRes.result.title, null);
    assert.equal(loadRes.result.rawTitle, undefined);

    c.sendJson({ jsonrpc: '2.0', id: 33, method: 'session/list', params: { cwd: '~' } });
    const listRes = await c.waitFor((m) => m.id === 33);
    assert.equal(listRes.result.sessions.some((s) => s.sessionId === 'ext-1'), false);
    const ownItem = listRes.result.sessions.find((s) => s.sessionId === 'own-1');
    assert.equal(ownItem.title, null);
    assert.equal(ownItem.prompt, undefined);
    assert.equal(ownItem.rawTitle, undefined);

    // 6. Upstream session_info_update sanitized to title: null
    adapter.host.onAdapterMessage({
      kind: 'notification',
      sessionId: 'own-1',
      message: {
        jsonrpc: '2.0',
        method: 'session/update',
        params: {
          sessionId: 'own-1',
          update: { sessionUpdate: 'session_info_update', title: 'Raw English', rawTitle: 'Raw English', prompt: 'secret' },
        },
      },
    });
    const infoUpd = await c.waitFor((m) => m.params?.update?.sessionUpdate === 'session_info_update');
    assert.equal(infoUpd.params.update.title, null);
    assert.equal(infoUpd.params.update.rawTitle, undefined);
    assert.equal(infoUpd.params.update.prompt, undefined);

    // 5. Missing disk session load/resume pushes nonlocal/session_deleted
    c.sendJson({ jsonrpc: '2.0', id: 34, method: 'session/load', params: { sessionId: 'del-absent', cwd: root } });
    assert.equal((await c.waitFor((m) => m.id === 34)).error.code, -32602);
    const delPush = await c.waitFor((m) => m.method === 'nonlocal/session_deleted' && m.params?.sessionId === 'del-absent');
    assert.ok(delPush.params.instanceId);

    // 3. In-flight session/new persists to SQLite even if client disconnects before reply
    c.sendJson({
      jsonrpc: '2.0',
      id: 35,
      method: 'session/new',
      params: { cwd: root, forcedId: 'own-inflight', disconnectBeforeReply: true },
    });
    await new Promise((r) => setTimeout(r, 20));
    c.close();
    await c.waitForClose();
    await new Promise((r) => setTimeout(r, 120));
    assert.equal(store.has('own-inflight'), true);

    assert.equal(upstreamSent.some((r) => r.sessionId === 'ext-1'), false, 'ext-1 must never reach adapter');
  } finally {
    await gateway.stop();
    rmTempDir(root);
  }
});

test('AC-41 & AC-42: 3-tier title priority, TitleSummaryService single-claim concurrency, auto/zh/en prompts, no-retry, rename_session & immutable updated_at (PP-41-claim)', async () => {
  const root = makeTempDir('nonlocal-title-ac41-');
  const token = createTestToken(64);
  const mockAi = await startMockOpenAiServer();

  try {
    // 1. Verify disabled titleSummary falls back to 30 Unicode code points with zero error & immutable updated_at
    const cfgOff = createDefaultConfig(process.env, root);
    cfgOff.state.dir = join(root, 'state-off');
    cfgOff.state.logFile = join(root, 'state-off', 'bridge.log');
    const storeOff = new StateStore({ stateDir: cfgOff.state.dir });
    const loggerOff = new SanitizedLogger({ logFile: cfgOff.state.logFile, redactSecrets: [token] });
    const fixedTs = '2026-11-20T10:00:00.000Z';
    storeOff.recordCreated({ sessionId: 's-off', cwd: root, updatedAt: fixedTs });
    const prompt35 = '第一二三四五六七八九十甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥';
    storeOff.recordPromptFallbackTitle('s-off', prompt35);
    assert.equal(Array.from(storeOff.getDisplayTitle('s-off')).length, 30);
    assert.equal(storeOff.get('s-off').updatedAt, fixedTs);
    storeOff.close();

    // 2. Enabled titleSummary: auto/zh/en distinguishable prompts, endpoint /chat/completions auto-append, concurrent claim=1, image-only skipped, updated_at immutable
    const sysPrompts = {};
    for (const lang of ['auto', 'zh', 'en']) {
      const cfg = createDefaultConfig(process.env, root);
      cfg.state.dir = join(root, `state-${lang}`);
      cfg.state.logFile = join(root, `state-${lang}`, 'bridge.log');
      cfg.titleSummary = {
        enabled: true,
        endpoint: mockAi.baseUrl, // omits /chat/completions
        model: 'test-small-model',
        apiKeyFile: '',
        apiKey: 'sk-mock-secret',
        language: lang,
        timeoutMs: 150,
      };
      const store = new StateStore({ stateDir: cfg.state.dir });
      const logger = new SanitizedLogger({ logFile: cfg.state.logFile, redactSecrets: [token, 'sk-mock-secret'] });
      const adapter = new FakeTestAdapter({
        onDispatch: async (req, self) => {
          if (req.method === 'session/prompt') {
            self.host.onAdapterMessage({
              kind: 'response',
              connId: req.connId,
              clientReqId: req.clientReqId,
              method: req.method,
              sessionId: req.sessionId,
              message: { jsonrpc: '2.0', id: req.clientReqId, result: { stopReason: 'end_turn' } },
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
        getHealthState: () => ({ childAlive: true, activeClient: true }),
        logger,
      });
      const gw = new NonlocalGateway({ config: cfg, transport, adapter, store, logger });
      let c = null;
      try {
        const { port } = await gw.start();
        c = await connectWs(`ws://127.0.0.1:${port}/acp`, token);

        const sid = `s-${lang}`;
        store.recordCreated({ sessionId: sid, cwd: root, updatedAt: fixedTs });

        if (lang === 'auto') {
          // Image-only prompt does not consume summary_attempted
          c.sendJson({
            jsonrpc: '2.0',
            id: 1,
            method: 'session/prompt',
            params: { sessionId: sid, prompt: [{ type: 'image', data: 'abc' }] },
          });
          await c.waitFor((m) => m.id === 1);
          assert.equal(store.get(sid).summaryAttempted, false);
        }

        mockAi.requests.length = 0;
        mockAi.setBehavior({ mode: 'ok', title: '<think>thinking</think> 「测试清理后的超长AI标题超过二十个字符截断验证」', delayMs: 0 });

        // Concurrent first text prompts (>3000B) -> only 1 HTTP request via claimSummaryAttempt
        const bigText = '请帮我分析这个超长日志' + 'A'.repeat(3200);
        c.sendJson({ jsonrpc: '2.0', id: 2, method: 'session/prompt', params: { sessionId: sid, prompt: [{ type: 'text', text: bigText }] } });
        c.sendJson({ jsonrpc: '2.0', id: 3, method: 'session/prompt', params: { sessionId: sid, prompt: [{ type: 'text', text: bigText }] } });
        const infoUpdate = await c.waitFor((m) => m.params?.update?.sessionUpdate === 'session_info_update');
        await c.waitFor((m) => m.id === 2);
        await c.waitFor((m) => m.id === 3);

        assert.equal(mockAi.requests.length, 1, 'concurrent prompts must trigger exactly 1 AI summary HTTP request');
        assert.equal(mockAi.requests[0].url, '/v1/chat/completions');
        const userMsg = mockAi.requests[0].body.messages[1].content;
        assert.ok(Buffer.byteLength(userMsg, 'utf8') <= 2048);
        sysPrompts[lang] = mockAi.requests[0].body.messages[0].content;

        const aiTitle = infoUpdate.params.update.title;
        assert.ok(Array.from(aiTitle).length <= 20);
        assert.equal(aiTitle.includes('<think>'), false);

        // Test AC-42 rename_session & updated_at immutability on a clean session with fixed updatedAt
        const sRename = `s-rename-${lang}`;
        store.recordCreated({ sessionId: sRename, cwd: root, updatedAt: fixedTs });
        store.recordPromptFallbackTitle(sRename, '兜底标题');
        const rawDbBefore = new DatabaseSync(store.dbPath, { readOnly: true });
        const tsBefore = rawDbBefore.prepare('SELECT updated_at FROM sessions WHERE session_id = ?').get(sRename).updated_at;
        rawDbBefore.close();
        assert.equal(tsBefore, fixedTs);

        if (lang === 'zh') {
          // AC-42: set custom, immune to upstream update, clear falls back to ai_title / fallback_title / null, no-id notification, invalid -32602
          c.sendJson({ jsonrpc: '2.0', id: 20, method: 'nonlocal/rename_session', params: { sessionId: sRename, title: '手动标题' } });
          const renRes = await c.waitFor((m) => m.id === 20);
          assert.deepEqual(renRes.result, { sessionId: sRename, title: '手动标题' });
          await c.waitFor((m) => m.params?.update?.sessionUpdate === 'session_info_update' && m.params.update.title === '手动标题');

          // Upstream title update cannot override custom_title
          adapter.host.onAdapterMessage({
            kind: 'notification',
            sessionId: sRename,
            message: { jsonrpc: '2.0', method: 'session/update', params: { sessionId: sRename, update: { sessionUpdate: 'session_info_update', title: 'Upstream Ignored' } } },
          });
          const upNotif = await c.waitFor((m) => m.params?.update?.sessionUpdate === 'session_info_update');
          assert.equal(upNotif.params.update.title, '手动标题');

          // Clear custom -> fallback_title
          c.sendJson({ jsonrpc: '2.0', id: 21, method: 'nonlocal/rename_session', params: { sessionId: sRename, title: '' } });
          assert.equal((await c.waitFor((m) => m.id === 21)).result.title, '兜底标题');

          // No-id notification still persists & pushes session_info_update without RPC response
          c.sendJson({ jsonrpc: '2.0', method: 'nonlocal/rename_session', params: { sessionId: sRename, title: '无ID通知标题' } });
          const noIdUpd = await c.waitFor((m) => m.params?.update?.title === '无ID通知标题');
          assert.equal(noIdUpd.id, undefined);

          // Clear on session with ai_title -> ai_title
          c.sendJson({ jsonrpc: '2.0', id: 22, method: 'nonlocal/rename_session', params: { sessionId: sid, title: null } });
          assert.equal((await c.waitFor((m) => m.id === 22)).result.title, aiTitle);

          // Invalid title type / probe / non-owned -> -32602
          c.sendJson({ jsonrpc: '2.0', id: 23, method: 'nonlocal/rename_session', params: { sessionId: sRename, title: 123 } });
          assert.equal((await c.waitFor((m) => m.id === 23)).error.code, -32602);
          c.sendJson({ jsonrpc: '2.0', id: 24, method: 'nonlocal/rename_session', params: { sessionId: 'capability-probe', title: 'x' } });
          assert.equal((await c.waitFor((m) => m.id === 24)).error.code, -32602);

          const rawDbAfter = new DatabaseSync(store.dbPath, { readOnly: true });
          const tsAfter = rawDbAfter.prepare('SELECT updated_at FROM sessions WHERE session_id = ?').get(sRename).updated_at;
          rawDbAfter.close();
          assert.equal(tsAfter, fixedTs, 'sessions.updated_at must remain bit-for-bit identical across all title ops');
        }

        // Check failure cases (think-only / http 500 / timeout) never retry and race with manual rename preserves custom_title
        if (lang === 'en') {
          for (const mode of ['think_only', 'http_500', 'timeout']) {
            const sFail = `s-fail-${mode}`;
            store.recordCreated({ sessionId: sFail, cwd: root, updatedAt: fixedTs });
            mockAi.requests.length = 0;
            mockAi.setBehavior(mode === 'timeout' ? { mode: 'ok', delayMs: 300 } : { mode, delayMs: 0 });
            c.sendJson({ jsonrpc: '2.0', id: 40, method: 'session/prompt', params: { sessionId: sFail, prompt: [{ type: 'text', text: 'first prompt text' }] } });
            await c.waitFor((m) => m.id === 40);
            await new Promise((r) => setTimeout(r, 220));
            assert.equal(mockAi.requests.length, 1);
            assert.equal(store.getDisplayTitle(sFail), 'first prompt text');
            // Turn 2 must never retry
            c.sendJson({ jsonrpc: '2.0', id: 41, method: 'session/prompt', params: { sessionId: sFail, prompt: [{ type: 'text', text: 'second prompt' }] } });
            await c.waitFor((m) => m.id === 41);
            await new Promise((r) => setTimeout(r, 50));
            assert.equal(mockAi.requests.length, 1, 'must never retry failed AI summary');
          }

          // Manual rename before async AI response arrives preserves custom_title
          const sRace = 's-race';
          store.recordCreated({ sessionId: sRace, cwd: root, updatedAt: fixedTs });
          mockAi.setBehavior({ mode: 'ok', title: '晚到的AI标题', delayMs: 80 });
          c.sendJson({ jsonrpc: '2.0', id: 50, method: 'session/prompt', params: { sessionId: sRace, prompt: [{ type: 'text', text: 'race prompt' }] } });
          await c.waitFor((m) => m.id === 50);
          c.sendJson({ jsonrpc: '2.0', id: 51, method: 'nonlocal/rename_session', params: { sessionId: sRace, title: '用户抢先改名' } });
          await c.waitFor((m) => m.id === 51);
          await new Promise((r) => setTimeout(r, 140));
          assert.equal(store.getDisplayTitle(sRace), '用户抢先改名');
        }

        const logText = readFileSync(cfg.state.logFile, 'utf8');
        assert.equal(logText.includes('手动标题'), false);
        assert.equal(logText.includes('sk-mock-secret'), false);
      } finally {
        c?.close();
        if (c) await c.waitForClose().catch(() => {});
        await gw.stop();
      }
    }

    // auto / zh / en system prompts are mutually distinguishable
    assert.notEqual(sysPrompts.auto, sysPrompts.zh);
    assert.notEqual(sysPrompts.auto, sysPrompts.en);
    assert.notEqual(sysPrompts.zh, sysPrompts.en);
  } finally {
    await mockAi.close();
    rmTempDir(root);
  }
});
