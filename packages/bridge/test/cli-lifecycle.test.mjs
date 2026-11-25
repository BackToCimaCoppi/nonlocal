import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { getFreePort, makeCleanEnv, makeTempDir, rmTempDir } from './helpers/test-utils.mjs';

const CLI_PATH = fileURLToPath(new URL('../dist/cli.js', import.meta.url));
const FAKE_SERVER = fileURLToPath(new URL('./helpers/fake-acp-server.mjs', import.meta.url));

test('AC-55 & AC-56: init --yes, foreground/standalone lifecycle, fake launchctl/systemctl 0-call isolation, exact 8-key runtime / 9-key status JSON, token guard', async () => {
  const root = makeTempDir('nonlocal-cli-ac55-');
  const home = join(root, 'home');
  const binDir = join(root, 'fake-bin');
  const svcCallLog = join(root, 'svc-calls.log');
  const { chmodSync, mkdirSync, writeFileSync } = await import('node:fs');
  const { spawn } = await import('node:child_process');
  mkdirSync(binDir, { recursive: true });
  for (const binName of ['launchctl', 'systemctl']) {
    const p = join(binDir, binName);
    writeFileSync(p, `#!/bin/sh\necho "${binName} $@" >> "${svcCallLog}"\nexit 0\n`, { mode: 0o755 });
    chmodSync(p, 0o755);
  }

  const port = await getFreePort('127.0.0.1');
  const env = makeCleanEnv({ HOME: home, PATH: `${binDir}:${process.env.PATH || ''}` });
  const cfgPath = join(root, 'custom', 'config.json');
  const stateDir = join(root, 'custom-state');

  try {
    // 1. init --yes (stdout zero plaintext token)
    const initOut = execFileSync(
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
    assert.ok(initOut.includes('Initialized'));
    const tokenPath = join(root, 'custom', 'bearer.token');
    const tokVal = readFileSync(tokenPath, 'utf8').trim();
    assert.equal(initOut.includes(tokVal), false, 'init must NEVER print token');
    assert.equal(statSync(tokenPath).mode & 0o777, 0o600);

    // AC-59: token show without --reveal fails; with --reveal prints token; token path works
    const showFail = spawnSync(process.execPath, [CLI_PATH, 'token', 'show', '--config', cfgPath], {
      encoding: 'utf8',
      env,
    });
    assert.equal(showFail.status, 1);
    assert.equal(showFail.stdout.includes(tokVal), false);

    const showOk = execFileSync(process.execPath, [CLI_PATH, 'token', 'show', '--reveal', '--config', cfgPath], {
      encoding: 'utf8',
      env,
    }).trim();
    assert.equal(showOk, tokVal);

    const pathOut = execFileSync(process.execPath, [CLI_PATH, 'token', 'path', '--config', cfgPath], {
      encoding: 'utf8',
      env,
    });
    assert.ok(pathOut.includes('0600'));

    // logs on missing logFile fails cleanly
    const logMiss = spawnSync(process.execPath, [CLI_PATH, 'logs', '--config', cfgPath], { encoding: 'utf8', env });
    assert.equal(logMiss.status, 1);

    // 2. start --standalone & idempotent start
    execFileSync(process.execPath, [CLI_PATH, 'start', '--standalone', '--config', cfgPath], {
      encoding: 'utf8',
      env,
    });
    execFileSync(process.execPath, [CLI_PATH, 'start', '--standalone', '--config', cfgPath], {
      encoding: 'utf8',
      env,
    });

    // Exact 8 keys in bridge.runtime.json
    const rtPath = join(stateDir, 'bridge.runtime.json');
    assert.equal(existsSync(rtPath), true);
    assert.equal(statSync(rtPath).mode & 0o777, 0o600);
    const rt = JSON.parse(readFileSync(rtPath, 'utf8'));
    assert.deepEqual(
      Object.keys(rt).sort(),
      ['commandFingerprint', 'configPath', 'host', 'listenAddresses', 'mode', 'pid', 'port', 'startedAt']
    );
    assert.equal(rt.mode, 'standalone');
    assert.equal(rt.port, port);

    // 3. status --json exact 9 keys, zero plaintext token
    const statusText = execFileSync(process.execPath, [CLI_PATH, 'status', '--json', '--config', cfgPath], {
      encoding: 'utf8',
      env,
    });
    assert.equal(statusText.includes(tokVal), false);
    const st = JSON.parse(statusText);
    assert.deepEqual(
      Object.keys(st).sort(),
      ['health', 'listenAddresses', 'mode', 'pid', 'portState', 'running', 'securityWarning', 'service', 'token']
    );
    assert.equal(st.running, true);
    assert.equal(st.portState, 'owned_running');
    assert.equal(st.health.ok, true);

    // logs -n 10 succeeds
    const logsOut = execFileSync(process.execPath, [CLI_PATH, 'logs', '-n', '10', '--config', cfgPath], {
      encoding: 'utf8',
      env,
    });
    assert.ok(logsOut.includes('bridge_listening'));

    // token rotate writes new 0600 64-hex token
    execFileSync(process.execPath, [CLI_PATH, 'token', 'rotate', '--config', cfgPath], {
      encoding: 'utf8',
      env,
    });
    const newTok = readFileSync(tokenPath, 'utf8').trim();
    assert.notEqual(newTok, tokVal);
    assert.equal(newTok.length, 64);

    // 4. restart & idempotent stop
    execFileSync(process.execPath, [CLI_PATH, 'restart', '--standalone', '--config', cfgPath], {
      encoding: 'utf8',
      env,
    });
    const rt2 = JSON.parse(readFileSync(rtPath, 'utf8'));
    assert.notEqual(rt2.pid, rt.pid);

    execFileSync(process.execPath, [CLI_PATH, 'stop', '--standalone', '--config', cfgPath], {
      encoding: 'utf8',
      env,
    });
    // Idempotent second stop returns 0
    execFileSync(process.execPath, [CLI_PATH, 'stop', '--standalone', '--config', cfgPath], {
      encoding: 'utf8',
      env,
    });
    assert.equal(existsSync(rtPath), false);

    // status after stop exits 1 with running: false, portState: free
    const stDown = spawnSync(process.execPath, [CLI_PATH, 'status', '--json', '--config', cfgPath], {
      encoding: 'utf8',
      env,
    });
    assert.equal(stDown.status, 1);
    const stDownJson = JSON.parse(stDown.stdout);
    assert.equal(stDownJson.running, false);
    assert.equal(stDownJson.portState, 'free');

    // Verify start --foreground outputs exact LISTENING line
    const fgPort = await getFreePort('127.0.0.1');
    const fgChild = spawn(process.execPath, [CLI_PATH, 'start', '--foreground', '--config', cfgPath, '--port', String(fgPort)], {
      env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let fgOut = '';
    await new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error('timeout waiting for LISTENING line')), 4000);
      fgChild.stdout.on('data', (chunk) => {
        fgOut += chunk.toString('utf8');
        if (fgOut.includes(`LISTENING host=127.0.0.1 port=${fgPort}`)) {
          clearTimeout(t);
          resolve();
        }
      });
    });
    fgChild.kill('SIGTERM');
    await new Promise((r) => fgChild.once('close', r));

    // Verify sentinel launchctl/systemctl had ZERO mutating calls during standalone / custom --config / --port runs
    const svcCalls = existsSync(svcCallLog) ? readFileSync(svcCallLog, 'utf8').trim().split('\n').filter(Boolean) : [];
    const mutatingCalls = svcCalls.filter((l) => !l.includes('launchctl print ') && !l.includes('systemctl --user is-active '));
    assert.deepEqual(mutatingCalls, [], 'standalone / custom config must NEVER call mutating launchctl/systemctl actions');
  } finally {
    try {
      spawnSync(process.execPath, [CLI_PATH, 'stop', '--standalone', '--config', cfgPath], { env });
    } catch {
      // ignore
    }
    rmTempDir(root);
  }
});
