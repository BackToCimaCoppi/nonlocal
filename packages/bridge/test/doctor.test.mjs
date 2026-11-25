import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { getFreePort, makeCleanEnv, makeTempDir, rmTempDir } from './helpers/test-utils.mjs';

const CLI_PATH = fileURLToPath(new URL('../dist/cli.js', import.meta.url));
const FAKE_SERVER = fileURLToPath(new URL('./helpers/fake-acp-server.mjs', import.meta.url));

const EXPECTED_8_IDS = [
  'platform',
  'node_runtime',
  'config_security',
  'bearer_token',
  'adapter_cli',
  'antigravity_settings',
  'port_binding',
  'bridge_live_handshake',
];

test('AC-58, AC-59 & AC-68: doctor --json exact 8 checks, free DEC-29, occupied short-circuit, live probe cleanup, generic-acp mode, and settings.json read-only (PP-58-doctor)', async () => {
  const root = makeTempDir('nonlocal-doc-ac58-');
  const home = join(root, 'home');
  const agyCliDir = join(home, '.gemini', 'antigravity-cli');
  mkdirSync(agyCliDir, { recursive: true });
  const settingsPath = join(agyCliDir, 'settings.json');
  writeFileSync(settingsPath, JSON.stringify({ enableACP: false }), 'utf8');
  const settingsHash = createHash('sha256').update(readFileSync(settingsPath)).digest('hex');
  const settingsMtime = statSync(settingsPath).mtimeMs;

  const cfgPath = join(root, 'cfg', 'config.json');
  const stateDir = join(root, 'state');
  const port = await getFreePort('127.0.0.1');
  const env = makeCleanEnv({ HOME: home });

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
    { env }
  );
  const tokVal = readFileSync(join(root, 'cfg', 'bearer.token'), 'utf8').trim();

  const blocker = net.createServer();
  try {
    // 1. Not running (free) -> port_binding='pass', bridge_live_handshake='fail' with fixCommand, exit 1
    const resFree = spawnSync(process.execPath, [CLI_PATH, 'doctor', '--json', '--config', cfgPath], {
      encoding: 'utf8',
      env,
    });
    assert.equal(resFree.status, 1);
    assert.equal(resFree.stdout.includes(tokVal), false);
    const docFree = JSON.parse(resFree.stdout);
    assert.deepEqual(docFree.checks.map((c) => c.id), EXPECTED_8_IDS);
    assert.equal(docFree.checks.find((c) => c.id === 'port_binding').status, 'pass');
    const hsFree = docFree.checks.find((c) => c.id === 'bridge_live_handshake');
    assert.equal(hsFree.status, 'fail');
    assert.equal(hsFree.fixCommand, 'nonlocal-bridge start');

    // 2. occupied_by_other -> port_binding='fail' & bridge_live_handshake short-circuited (0 upgrade attempts!)
    let connections = 0;
    blocker.on('connection', (sock) => {
      connections += 1;
      sock.destroy();
    });
    await new Promise((r) => blocker.listen(port, '127.0.0.1', r));
    const resOcc = spawnSync(process.execPath, [CLI_PATH, 'doctor', '--json', '--config', cfgPath], {
      encoding: 'utf8',
      env,
    });
    assert.equal(resOcc.status, 1);
    const docOcc = JSON.parse(resOcc.stdout);
    assert.equal(docOcc.checks.find((c) => c.id === 'port_binding').status, 'fail');
    assert.equal(docOcc.checks.find((c) => c.id === 'bridge_live_handshake').status, 'fail');
    assert.match(docOcc.checks.find((c) => c.id === 'bridge_live_handshake').summary, /Short-circuited/);
    assert.equal(connections, 0, 'occupied_by_other must NEVER attempt WS connection');
    await new Promise((r) => blocker.close(r));

    // 3. owned_running -> live WS handshake passes (exit 0) AND probe fallback worker is reclaimed on close!
    execFileSync(process.execPath, [CLI_PATH, 'start', '--standalone', '--config', cfgPath], { env });
    const docOkOut = execFileSync(process.execPath, [CLI_PATH, 'doctor', '--json', '--config', cfgPath], {
      encoding: 'utf8',
      env,
    });
    assert.equal(docOkOut.includes(tokVal), false);
    const docOk = JSON.parse(docOkOut);
    assert.equal(docOk.ok, true);
    assert.equal(docOk.summary.fail, 0);
    assert.equal(docOk.checks.find((c) => c.id === 'bridge_live_handshake').status, 'pass');
    // AC-59: generic-acp antigravity_settings status === 'pass' marked Not applicable
    assert.equal(docOk.checks.find((c) => c.id === 'adapter_cli').status, 'pass');
    assert.equal(docOk.checks.find((c) => c.id === 'antigravity_settings').status, 'pass');
    assert.match(docOk.checks.find((c) => c.id === 'antigravity_settings').summary, /not applicable|generic-acp/i);

    // AC-58 bad adapter_cli failure branch
    const badCmdDoc = spawnSync(
      process.execPath,
      [CLI_PATH, 'doctor', '--json', '--config', cfgPath, '--adapter-command', '/nonexistent/bin/cmd'],
      { encoding: 'utf8', env }
    );
    assert.equal(badCmdDoc.status, 1);
    assert.equal(JSON.parse(badCmdDoc.stdout).checks.find((c) => c.id === 'adapter_cli').status, 'fail');

    // Check bridge.log recorded reclaim_probe_fallback_worker
    await new Promise((r) => setTimeout(r, 80));
    const logText = readFileSync(join(stateDir, 'bridge.log'), 'utf8');
    assert.equal(logText.includes('reclaim_probe_fallback_worker'), true);

    // 4. Read-only check on antigravity-cli/settings.json
    assert.equal(createHash('sha256').update(readFileSync(settingsPath)).digest('hex'), settingsHash);
    assert.equal(statSync(settingsPath).mtimeMs, settingsMtime);
  } finally {
    try {
      blocker.close();
    } catch {
      // ignore
    }
    spawnSync(process.execPath, [CLI_PATH, 'stop', '--standalone', '--config', cfgPath], { env });
    rmTempDir(root);
  }
});
