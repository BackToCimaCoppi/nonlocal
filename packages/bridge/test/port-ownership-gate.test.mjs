import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig } from '../dist/config/index.js';
import { probePortOwnership } from '../dist/service/runtime.js';
import { getFreePort, makeCleanEnv, makeTempDir, rmTempDir } from './helpers/test-utils.mjs';

const CLI_PATH = fileURLToPath(new URL('../dist/cli.js', import.meta.url));
const FAKE_SERVER = fileURLToPath(new URL('./helpers/fake-acp-server.mjs', import.meta.url));

test('AC-57: zero-lsof 3-state port ownership gate (free / occupied_by_other / owned_running) and stale/PID-reuse protection (PP-57-noclash)', async () => {
  const root = makeTempDir('nonlocal-gate-ac57-');
  const cfgPath = join(root, 'cfg', 'config.json');
  const stateDir = join(root, 'state');
  const env = makeCleanEnv({ HOME: root });
  const port = await getFreePort('127.0.0.1');

  execFileSync(
    process.execPath,
    [
      CLI_PATH,
      'init',
      '--yes',
      '--config',
      cfgPath,
      '--state-dir',
      stateDir,
      '--host',
      '127.0.0.1',
      '--port',
      String(port),
      '--adapter',
      'generic-acp',
      '--adapter-command',
      process.execPath,
      '--adapter-args',
      JSON.stringify([FAKE_SERVER]),
    ],
    { encoding: 'utf8', env }
  );

  const cfg = loadConfig({ overrides: { config: cfgPath }, env, homeDir: root });

  let foreignProc = null;
  let blockerServer = null;
  try {
    // 1. free
    assert.equal((await probePortOwnership(cfg)).portState, 'free');

    // 2. Foreign listener holding the port (without runtime file -> occupied_by_other + 0 WS upgrades from doctor!)
    let upgradeAttempts = 0;
    blockerServer = net.createServer((sock) => {
      sock.once('data', () => {
        upgradeAttempts += 1;
      });
      sock.destroy();
    });
    await new Promise((res) => blockerServer.listen(port, '127.0.0.1', res));
    assert.equal((await probePortOwnership(cfg)).portState, 'occupied_by_other');

    // start & restart & status & doctor without bridge.runtime.json
    assert.equal(spawnSync(process.execPath, [CLI_PATH, 'start', '--standalone', '--config', cfgPath], { env }).status, 1);
    assert.equal(spawnSync(process.execPath, [CLI_PATH, 'restart', '--standalone', '--config', cfgPath], { env }).status, 1);
    const stNoRt = spawnSync(process.execPath, [CLI_PATH, 'status', '--json', '--config', cfgPath], { encoding: 'utf8', env });
    assert.equal(stNoRt.status, 1);
    assert.equal(JSON.parse(stNoRt.stdout).portState, 'occupied_by_other');
    const docNoRt = spawnSync(process.execPath, [CLI_PATH, 'doctor', '--json', '--config', cfgPath], { encoding: 'utf8', env });
    assert.equal(docNoRt.status, 1);
    assert.equal(JSON.parse(docNoRt.stdout).checks.find((c) => c.id === 'port_binding').status, 'fail');
    assert.equal(upgradeAttempts, 0);

    // 3. PP-57-noclash: Fake PID reuse (live unrelated sleep process recorded in bridge.runtime.json)
    foreignProc = spawn(process.execPath, ['-e', 'setInterval(() => {}, 10000);'], { stdio: 'ignore' });
    mkdirSync(stateDir, { recursive: true });
    writeFileSync(
      join(stateDir, 'bridge.runtime.json'),
      JSON.stringify({
        pid: foreignProc.pid,
        mode: 'standalone',
        host: '127.0.0.1',
        port,
        listenAddresses: [{ host: '127.0.0.1', port, role: 'primary' }],
        configPath: cfgPath,
        startedAt: new Date().toISOString(),
        commandFingerprint: '/nonexistent/cli.js::nonlocal-bridge',
      }),
      { mode: 0o600 }
    );
    assert.equal((await probePortOwnership(cfg)).portState, 'occupied_by_other');
    const stFakePid = spawnSync(process.execPath, [CLI_PATH, 'status', '--json', '--config', cfgPath], { encoding: 'utf8', env });
    assert.equal(stFakePid.status, 1);
    assert.equal(JSON.parse(stFakePid.stdout).portState, 'occupied_by_other');
    const docFakePid = spawnSync(process.execPath, [CLI_PATH, 'doctor', '--json', '--config', cfgPath], { encoding: 'utf8', env });
    assert.equal(docFakePid.status, 1);
    assert.equal(JSON.parse(docFakePid.stdout).checks.find((c) => c.id === 'port_binding').status, 'fail');
    assert.equal(upgradeAttempts, 0, 'doctor under stale/reused runtime.json MUST attempt 0 WS upgrades');

    // stop MUST refuse to kill the foreign PID!
    const stopRes = spawnSync(process.execPath, [CLI_PATH, 'stop', '--standalone', '--config', cfgPath], { env });
    assert.equal(stopRes.status, 1);
    assert.doesNotThrow(() => process.kill(foreignProc.pid, 0), 'foreign process MUST survive stop mismatch');

    await new Promise((res) => blockerServer.close(res));
    blockerServer = null;

    // 4. Stale dead PID in bridge.runtime.json with free port -> portState === 'free'
    foreignProc.kill('SIGKILL');
    await new Promise((r) => setTimeout(r, 40));
    foreignProc = null;
    assert.equal((await probePortOwnership(cfg)).portState, 'free');

    // 5. Real start -> owned_running
    execFileSync(process.execPath, [CLI_PATH, 'start', '--standalone', '--config', cfgPath], { env });
    assert.equal((await probePortOwnership(cfg)).portState, 'owned_running');
    execFileSync(process.execPath, [CLI_PATH, 'stop', '--standalone', '--config', cfgPath], { env });
    assert.equal(existsSync(join(stateDir, 'bridge.runtime.json')), false);
  } finally {
    if (foreignProc) {
      try {
        foreignProc.kill('SIGKILL');
      } catch {
        // ignore
      }
    }
    if (blockerServer) {
      try {
        blockerServer.close();
      } catch {
        // ignore
      }
    }
    spawnSync(process.execPath, [CLI_PATH, 'stop', '--standalone', '--config', cfgPath], { env });
    rmTempDir(root);
  }
});
