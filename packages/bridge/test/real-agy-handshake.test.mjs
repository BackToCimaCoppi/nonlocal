import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { accessSync, constants as fsConstants, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { probeLoopbackHealth } from '../dist/service/runtime.js';
import { connectWs } from './helpers/ws-client.mjs';
import { createTestToken, getFreePort, makeCleanEnv, makeTempDir, rmTempDir } from './helpers/test-utils.mjs';

const CLI_PATH = fileURLToPath(new URL('../dist/cli.js', import.meta.url));

function resolveRealAgyBin() {
  if (process.env.NONLOCAL_TEST_AGY_BIN) {
    accessSync(process.env.NONLOCAL_TEST_AGY_BIN, fsConstants.X_OK);
    return process.env.NONLOCAL_TEST_AGY_BIN;
  }
  try {
    const out = execFileSync('which', ['agy'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    if (out) {
      accessSync(out, fsConstants.X_OK);
      return out;
    }
  } catch {
    // fallback check below
  }
  const userLocal = join(homedir(), '.local', 'bin', 'agy');
  try {
    accessSync(userLocal, fsConstants.X_OK);
    return userLocal;
  } catch {
    return null;
  }
}

test('AC-63: end-to-end handshake with real `agy acp` binary on isolated port/state (Antigravity ACP Server, /health, sync, list, clean exit)', async (t) => {
  const agyBin = resolveRealAgyBin();
  if (!agyBin) {
    t.skip('agy CLI not available in this environment');
    return;
  }
  const root = makeTempDir('nonlocal-real-agy-ac63-');
  const home = join(root, 'home');
  const cfgDir = join(root, 'cfg');
  const stateDir = join(root, 'state');
  mkdirSync(home, { recursive: true });
  mkdirSync(cfgDir, { recursive: true, mode: 0o700 });
  mkdirSync(stateDir, { recursive: true, mode: 0o700 });

  const port = await getFreePort('127.0.0.1');
  const token = createTestToken(64);
  const tokPath = join(cfgDir, 'bearer.token');
  writeFileSync(tokPath, `${token}\n`, { mode: 0o600 });

  const cfgPath = join(cfgDir, 'config.json');
  writeFileSync(
    cfgPath,
    JSON.stringify(
      {
        schemaVersion: 1,
        server: { host: '127.0.0.1', port, allowNonLoopback: false },
        security: { tokenFile: tokPath },
        adapter: {
          type: 'antigravity',
          command: agyBin,
          args: ['acp'],
          fallbackCwd: root,
          antigravity: { disableDataDirs: true },
        },
        state: { dir: stateDir, logFile: join(stateDir, 'bridge.log') },
      },
      null,
      2
    )
  );

  // Snapshot host settings.json if present to prove zero mutation
  const realSettingsPath = join(homedir(), '.gemini', 'antigravity-cli', 'settings.json');
  const settingsSnap = existsSync(realSettingsPath)
    ? {
        hash: createHash('sha256').update(readFileSync(realSettingsPath)).digest('hex'),
        mtimeMs: statSync(realSettingsPath).mtimeMs,
      }
    : null;

  // Preserve host HOME so `agy` can read its existing auth store read-only; bridge uses explicit --config/state-dir in root
  const env = makeCleanEnv({ HOME: homedir() });

  try {
    execFileSync(process.execPath, [CLI_PATH, 'start', '--standalone', '--config', cfgPath], {
      encoding: 'utf8',
      env,
    });

    const rt = JSON.parse(readFileSync(join(stateDir, 'bridge.runtime.json'), 'utf8'));
    assert.ok(rt.pid > 0);

    // Connect with iOS-equivalent WS handshake headers
    const c = await connectWs(`ws://127.0.0.1:${port}/acp`, token, {
      'X-Client-Id': 'nonlocal-ios-contract-probe',
    });

    // 1. initialize
    c.sendJson({
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {
        protocolVersion: 1,
        clientInfo: { name: 'Nonlocal-iOS-Verify', version: '0.1.0' },
        clientCapabilities: {},
      },
    });
    const initRes = await c.waitFor((m) => m.id === 1, 10_000);
    assert.ok(initRes.result);
    assert.ok(initRes.result.protocolVersion !== undefined);
    assert.equal(initRes.result.agentInfo?.name, 'Antigravity ACP Server');

    // 2. /health verifies live spawned agy child & active WS client
    const health = await probeLoopbackHealth('127.0.0.1', port);
    assert.deepEqual(health, { ok: true, childAlive: true, activeClient: true });

    // 3. nonlocal/sync
    c.sendJson({ jsonrpc: '2.0', id: 2, method: 'nonlocal/sync', params: {} });
    const syncRes = await c.waitFor((m) => m.id === 2);
    assert.ok(syncRes.result.instanceId);
    assert.equal(Array.isArray(syncRes.result.sessions), true);
    assert.equal(Array.isArray(syncRes.result.materializedSessionIds), true);

    // 4. session/list
    c.sendJson({ jsonrpc: '2.0', id: 3, method: 'session/list', params: { cwd: root } });
    const listRes = await c.waitFor((m) => m.id === 3, 10_000);
    assert.equal(Array.isArray(listRes.result?.sessions), true, `Unexpected session/list response: ${JSON.stringify(listRes)}`);

    c.close();
    await c.waitForClose();

    execFileSync(process.execPath, [CLI_PATH, 'stop', '--standalone', '--config', cfgPath], {
      encoding: 'utf8',
      env,
    });

    // Verify settings.json untouched
    if (settingsSnap) {
      assert.equal(createHash('sha256').update(readFileSync(realSettingsPath)).digest('hex'), settingsSnap.hash);
      assert.equal(statSync(realSettingsPath).mtimeMs, settingsSnap.mtimeMs);
    }

    // Verify no leaked test agy child running for our temp root
    const psOut = execFileSync('ps', ['-eo', 'pid,ppid,command'], { encoding: 'utf8' });
    assert.equal(psOut.includes(root), false, `Orphan process referencing ${root} remained after stop`);
  } finally {
    spawnSync(process.execPath, [CLI_PATH, 'stop', '--standalone', '--config', cfgPath], { env });
    rmTempDir(root);
  }
});
