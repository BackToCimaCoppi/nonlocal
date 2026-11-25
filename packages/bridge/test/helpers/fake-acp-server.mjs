#!/usr/bin/env node
import { appendFileSync, writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';

const logFile = process.env.FAKE_ACP_LOG || '';
const mode = process.env.FAKE_ACP_MODE || 'normal';
const sleepChildPidFile = process.env.FAKE_ACP_GRANDCHILD_PID_FILE || '';
const workerTag = `pid-${process.pid}-cwd-${process.cwd()}`;

function recordEvent(ev) {
  if (!logFile) return;
  appendFileSync(logFile, JSON.stringify({ pid: process.pid, cwd: process.cwd(), ...ev }) + '\n', 'utf8');
}

function sendJson(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

if (sleepChildPidFile) {
  const grandchild = spawn(process.execPath, ['-e', 'setInterval(() => {}, 10000);'], {
    stdio: 'ignore',
  });
  writeFileSync(sleepChildPidFile, String(grandchild.pid), 'utf8');
}

let initializedCount = 0;
let reqBuf = Buffer.alloc(0);
const loadedSessions = new Set();

function handleLine(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    return;
  }
  recordEvent({ method: msg.method, id: msg.id, params: msg.params });

  if (msg.method === 'initialize') {
    initializedCount += 1;
    if (mode === 'already_init_on_replay' && initializedCount > 1) {
      sendJson({ jsonrpc: '2.0', id: msg.id, error: { code: -32600, message: 'Already initialized' } });
      return;
    }
    sendJson({
      jsonrpc: '2.0',
      id: msg.id,
      result: {
        protocolVersion: 1,
        agentInfo: { name: 'fake-acp', version: '1.0.0' },
        agentCapabilities: { loadSession: true },
      },
    });
    return;
  }

  if (msg.method === 'session/new' || msg.method === 'session/create') {
    const sid = msg.params?.forcedId || `sess-${process.pid}-${Date.now().toString(36)}`;
    loadedSessions.add(sid);
    const defaultResp = {
      sessionId: sid,
      cwd: msg.params?.cwd || process.cwd(),
      modes: {
        currentModeId: 'ask',
        availableModes: [
          { id: 'ask', name: 'Ask' },
          { id: 'code', name: 'Code' },
        ],
      },
      models: {
        currentModelId: mode === 'mismatch_thought' ? 'm1-low' : 'm1-low',
        availableModels: [
          { modelId: 'm1-low', name: 'M1 Low' },
          { modelId: 'm1-high', name: 'M1 High' },
          { modelId: 'm2-high', name: 'M2 High' },
          { modelId: 'm2-medium', name: 'M2 Medium' },
        ],
      },
      configOptions: [
        {
          id: 'model',
          name: 'Model',
          currentValue: 'm1',
          options: [
            { value: 'm1', name: 'M1' },
            { value: 'm2', name: 'M2' },
          ],
        },
        {
          id: 'thought_level',
          name: 'Thought',
          currentValue: 'low',
          options: [
            { value: 'low', name: 'Low' },
            { value: 'medium', name: 'Medium' },
            { value: 'high', name: 'High' },
          ],
        },
      ],
      ...(mode === 'tier_meta' ? { _meta: { antigravity: { tier: { id: 'pro-tier', name: 'Pro Tier' } } } } : {}),
    };
    sendJson({ jsonrpc: '2.0', id: msg.id, result: defaultResp });
    return;
  }

  if (msg.method === 'session/load' || msg.method === 'session/resume') {
    const sid = msg.params?.sessionId || 's-load';
    if (mode === 'missing_on_load') {
      sendJson({ jsonrpc: '2.0', id: msg.id, error: { code: -32602, message: 'Session not found' } });
      return;
    }
    loadedSessions.add(sid);
    // Emit replay noise BEFORE and slightly AFTER load response to verify settle suppression
    sendJson({
      jsonrpc: '2.0',
      method: 'session/update',
      params: {
        sessionId: sid,
        update: { sessionUpdate: 'config_option_update', configOptions: [{ id: 'model', currentValue: 'stale-replay' }] },
      },
    });
    sendJson({
      jsonrpc: '2.0',
      method: 'session/update',
      params: {
        sessionId: sid,
        update: { sessionUpdate: 'available_commands_update', availableCommands: [{ name: 'help', description: 'Help cmd' }] },
      },
    });
    sendJson({
      jsonrpc: '2.0',
      id: msg.id,
      result: {
        sessionId: sid,
        cwd: msg.params?.cwd || process.cwd(),
        modes: { currentModeId: 'ask', availableModes: [{ id: 'ask' }, { id: 'code' }] },
        models: { currentModelId: 'm1-low', availableModels: [{ modelId: 'm1-low' }, { modelId: 'm2-high' }] },
        configOptions: [
          { id: 'model', currentValue: 'm1', options: [{ value: 'm1' }, { value: 'm2' }] },
          { id: 'thought_level', currentValue: 'low', options: [{ value: 'low' }, { value: 'high' }] },
        ],
      },
    });
    setTimeout(() => {
      sendJson({
        jsonrpc: '2.0',
        method: 'session/update',
        params: {
          sessionId: sid,
          update: { sessionUpdate: 'config_option_update', configOptions: [{ id: 'model', currentValue: 'late-noise' }] },
        },
      });
    }, 25);
    return;
  }

  if (msg.method === 'session/set_model' || msg.method === 'session/set_config_option' || msg.method === 'session/set_mode') {
    sendJson({ jsonrpc: '2.0', id: msg.id, result: {} });
    return;
  }

  if (msg.method === 'session/prompt') {
    const sid = msg.params?.sessionId;
    if (mode === 'split_utf8_and_permission') {
      // Send a 3-byte UTF-8 character ('中' = 0xe4 0xb8 0xad) + newline split across two stdout writes!
      const payload = Buffer.from(
        JSON.stringify({
          jsonrpc: '2.0',
          method: 'session/update',
          params: { sessionId: sid, update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: '中文Split中测试' } } },
        }) + '\n',
        'utf8'
      );
      const splitPoint = payload.indexOf(0xe4) + 1; // cut inside multi-byte char!
      process.stdout.write(payload.subarray(0, splitPoint));
      setTimeout(() => {
        process.stdout.write(payload.subarray(splitPoint));
        sendJson({
          jsonrpc: '2.0',
          id: msg.id,
          result: { stopReason: 'end_turn', workerTag },
        });
      }, 20);
      return;
    }

    if (mode === 'slow_prompt') {
      setTimeout(() => {
        sendJson({ jsonrpc: '2.0', id: msg.id, result: { stopReason: 'end_turn', workerTag } });
      }, Number(process.env.FAKE_ACP_DELAY_MS || '180'));
      return;
    }

    sendJson({
      jsonrpc: '2.0',
      method: 'session/update',
      params: {
        sessionId: sid,
        update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: `reply-from-${workerTag}` } },
      },
    });
    sendJson({
      jsonrpc: '2.0',
      id: msg.id,
      result: { stopReason: 'end_turn', workerTag },
    });
    return;
  }

  if (msg.method === 'session/list') {
    sendJson({
      jsonrpc: '2.0',
      id: msg.id,
      result: { sessions: [] },
    });
    return;
  }

  if (msg.method === 'session/close') {
    if (msg.params?.sessionId) loadedSessions.delete(msg.params.sessionId);
    if (msg.id !== undefined) sendJson({ jsonrpc: '2.0', id: msg.id, result: {} });
    return;
  }

  if (msg.id !== undefined) {
    sendJson({ jsonrpc: '2.0', id: msg.id, result: { workerTag } });
  }
}

process.stdin.on('data', (chunk) => {
  reqBuf = Buffer.concat([reqBuf, chunk]);
  let idx = reqBuf.indexOf(0x0a);
  while (idx !== -1) {
    const line = reqBuf.subarray(0, idx).toString('utf8').trim();
    reqBuf = reqBuf.subarray(idx + 1);
    if (line) handleLine(line);
    idx = reqBuf.indexOf(0x0a);
  }
});

process.on('SIGTERM', () => {
  process.exit(0);
});
