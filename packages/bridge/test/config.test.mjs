import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig } from '../dist/config/index.js';
import { makeTempDir, rmTempDir, makeCleanEnv, writePrivateTokenFile } from './helpers/test-utils.mjs';

const CLI_PATH = fileURLToPath(new URL('../dist/cli.js', import.meta.url));

const LEGACY_33_AGY_ENVS = {
  AGY_ACP_HOST: '203.0.113.99',
  AGY_ACP_PORT: '19999',
  AGY_ACP_TOKEN_FILE: '/tmp/legacy-token',
  AGY_ACP_STATE_DIR: '/tmp/legacy-state',
  AGY_ACP_LOG_FILE: '/tmp/legacy.log',
  AGY_ACP_LOG_MAX_BYTES: '999',
  AGY_ACP_LOG_MAX_BACKUPS: '9',
  AGY_ACP_BIN: '/nonexistent/legacy-bin',
  AGY_ACP_NODE_BIN: '/nonexistent/node',
  AGY_ACP_DEFAULT_MODEL: 'legacy-model',
  AGY_ACP_PING_INTERVAL_MS: '1234',
  AGY_ACP_PONG_TIMEOUT_MS: '5678',
  AGY_ACP_MAX_FRAME_BYTES: '4096',
  AGY_ACP_CHILD_CWD: '/nonexistent/cwd',
  AGY_ACP_CHILD_IDLE_TIMEOUT_MS: '100',
  AGY_ACP_CHILD_STOP_GRACE_MS: '100',
  AGY_ACP_ALLOW_EXTERNAL_SESSIONS: '1',
  AGY_ACP_ALLOW_LAN: '1',
  AGY_ACP_SEED_OWNED_SESSIONS: '{}',
  AGY_ACP_TRANSLATE_CONFIG: '/tmp/legacy-translate.json',
  AGY_ACP_TRANSLATE_URL: 'https://legacy.example/v1',
  AGY_ACP_TRANSLATE_MODEL: 'legacy-sum',
  AGY_ACP_TRANSLATE_KEY_FILE: '/tmp/legacy-key',
  AGY_ACP_TRANSLATE_API_KEY: 'legacy-secret',
  AGY_ACP_TRANSLATE_DISABLED: '1',
  AGY_ACP_TRANSLATE_TIMEOUT_MS: '1000',
  AGY_ACP_DATA_DIRS: '/tmp/legacy-data',
  AGY_ACP_USAGE_TIMEOUT_MS: '500',
  AGY_ACP_USAGE_COOLDOWN_MS: '500',
  AGY_ACP_FS_READ_DELAY_MS: '500',
  AGY_ACP_SYNC_WATCH_INTERVAL_MS: '500',
  AGY_ACP_SYNC_WATCH_WINDOW_MS: '500',
  AGY_ACP_SYNC_SETTLE_WINDOW_MS: '500',
};

test('AC-07: precedence CLI > 13 NONLOCAL_* > config.json > defaults and ignore 33 legacy AGY_ACP_*', () => {
  const root = makeTempDir('nonlocal-cfg-ac07-');
  try {
    const cfgDir = join(root, 'cfg');
    const stateDir = join(root, 'state');
    const keyDir = join(root, 'keys');
    mkdirSync(cfgDir, { recursive: true, mode: 0o700 });
    const { tokenPath } = writePrivateTokenFile(keyDir, 'bearer.token');

    const cfgPath = join(cfgDir, 'config.json');
    writeFileSync(
      cfgPath,
      JSON.stringify({
        schemaVersion: 1,
        server: { host: '127.0.0.1', port: 18100, allowNonLoopback: false },
        security: { tokenFile: tokenPath },
        adapter: {
          type: 'antigravity',
          command: 'cfg-cmd',
          args: ['from-cfg'],
          defaultModel: 'cfg-model',
          defaultThoughtLevel: 'low',
        },
        state: { dir: join(root, 'cfg-state') },
      })
    );

    const env = makeCleanEnv({
      ...LEGACY_33_AGY_ENVS,
      NONLOCAL_CONFIG: cfgPath,
      NONLOCAL_HOST: '127.0.0.2',
      NONLOCAL_PORT: '18200',
      NONLOCAL_ALLOW_NON_LOOPBACK: 'true',
      NONLOCAL_TOKEN_FILE: tokenPath,
      NONLOCAL_STATE_DIR: stateDir,
      NONLOCAL_LOG_FILE: join(root, 'env.log'),
      NONLOCAL_ADAPTER_TYPE: 'generic-acp',
      NONLOCAL_ADAPTER_COMMAND: 'env-cmd',
      NONLOCAL_ADAPTER_ARGS: '["--acp","--stdio"]',
      NONLOCAL_DEFAULT_MODEL: 'env-model',
      NONLOCAL_DEFAULT_THOUGHT_LEVEL: 'medium',
      NONLOCAL_TITLE_SUMMARY_API_KEY: 'sk-env-memory-only',
    });

    const cfgFromEnv = loadConfig({ env, homeDir: root });
    assert.equal(cfgFromEnv.configPath, cfgPath);
    assert.equal(cfgFromEnv.server.host, '127.0.0.2');
    assert.equal(cfgFromEnv.server.port, 18200);
    assert.equal(cfgFromEnv.server.allowNonLoopback, true);
    assert.equal(cfgFromEnv.security.tokenFile, tokenPath);
    assert.equal(cfgFromEnv.state.dir, stateDir);
    assert.equal(cfgFromEnv.state.logFile, join(root, 'env.log'));
    assert.equal(cfgFromEnv.adapter.type, 'generic-acp');
    assert.equal(cfgFromEnv.adapter.command, 'env-cmd');
    assert.deepEqual(cfgFromEnv.adapter.args, ['--acp', '--stdio']);
    assert.equal(cfgFromEnv.adapter.defaultModel, 'env-model');
    assert.equal(cfgFromEnv.adapter.defaultThoughtLevel, 'medium');
    assert.equal(cfgFromEnv.titleSummary.apiKey, 'sk-env-memory-only');

    // CLI overrides beat env
    const cfgFromCli = loadConfig({
      env,
      homeDir: root,
      overrides: {
        host: '127.0.0.3',
        port: 18300,
        adapterCommand: 'cli-cmd',
        adapterArgs: '["--cli"]',
        defaultModel: 'cli-model',
        defaultThoughtLevel: 'high',
      },
    });
    assert.equal(cfgFromCli.server.host, '127.0.0.3');
    assert.equal(cfgFromCli.server.port, 18300);
    assert.equal(cfgFromCli.adapter.command, 'cli-cmd');
    assert.deepEqual(cfgFromCli.adapter.args, ['--cli']);
    assert.equal(cfgFromCli.adapter.defaultModel, 'cli-model');
    assert.equal(cfgFromCli.adapter.defaultThoughtLevel, 'high');
  } finally {
    rmTempDir(root);
  }
});

test('AC-08: strict schema whitelist and 6 invalid configuration classes fail-closed', () => {
  const root = makeTempDir('nonlocal-cfg-ac08-');
  try {
    const baseCfgPath = join(root, 'config.json');
    const writeCfg = (obj) => writeFileSync(baseCfgPath, JSON.stringify(obj), 'utf8');

    // 1. schemaVersion: 2
    writeCfg({ schemaVersion: 2 });
    assert.throws(() => loadConfig({ env: makeCleanEnv({ NONLOCAL_CONFIG: baseCfgPath }), homeDir: root }), /schemaVersion/);

    // 2a. removed security.allowExternalSessions
    writeCfg({ schemaVersion: 1, security: { allowExternalSessions: true } });
    assert.throws(
      () => loadConfig({ env: makeCleanEnv({ NONLOCAL_CONFIG: baseCfgPath }), homeDir: root }),
      /security\.allowExternalSessions/
    );

    // 2b. unknown / misspelled key
    writeCfg({ schemaVersion: 1, server: { allowNonLoopBak: true } });
    assert.throws(
      () => loadConfig({ env: makeCleanEnv({ NONLOCAL_CONFIG: baseCfgPath }), homeDir: root }),
      /server\.allowNonLoopBak/
    );

    // 3. invalid NONLOCAL_ADAPTER_ARGS
    writeCfg({ schemaVersion: 1 });
    assert.throws(
      () =>
        loadConfig({
          env: makeCleanEnv({ NONLOCAL_CONFIG: baseCfgPath, NONLOCAL_ADAPTER_ARGS: 'bad' }),
          homeDir: root,
        }),
      /NONLOCAL_ADAPTER_ARGS/
    );

    // 4. trustedProxies 0.0.0.0/0, ::/0, or invalid IP/CIDR
    for (const badProxy of ['0.0.0.0/0', '::/0', 'not-an-ip']) {
      writeCfg({ schemaVersion: 1, security: { trustedProxies: [badProxy] } });
      assert.throws(
        () => loadConfig({ env: makeCleanEnv({ NONLOCAL_CONFIG: baseCfgPath }), homeDir: root }),
        /trustedProxies/
      );
    }

    // 5. titleSummary.enabled=true invalid endpoint / empty model / invalid language
    writeCfg({
      schemaVersion: 1,
      titleSummary: { enabled: true, endpoint: 'ftp://bad.example/v1', model: 'm', language: 'auto' },
    });
    assert.throws(() => loadConfig({ env: makeCleanEnv({ NONLOCAL_CONFIG: baseCfgPath }), homeDir: root }), /protocol/);

    writeCfg({
      schemaVersion: 1,
      titleSummary: { enabled: true, endpoint: 'https://api.example.com/v1', model: '', language: 'auto' },
    });
    assert.throws(() => loadConfig({ env: makeCleanEnv({ NONLOCAL_CONFIG: baseCfgPath }), homeDir: root }), /model/);

    writeCfg({
      schemaVersion: 1,
      titleSummary: { enabled: true, endpoint: 'https://api.example.com/v1', model: 'm', language: 'fr' },
    });
    assert.throws(() => loadConfig({ env: makeCleanEnv({ NONLOCAL_CONFIG: baseCfgPath }), homeDir: root }), /language/);
  } finally {
    rmTempDir(root);
  }
});

test('AC-09: defaultThoughtLevel without defaultModel fails closed, generic-acp requires command and defaults args to []', () => {
  const root = makeTempDir('nonlocal-cfg-ac09-');
  try {
    const cfgPath = join(root, 'config.json');

    // 1. defaultModel="" + defaultThoughtLevel="high"
    writeFileSync(
      cfgPath,
      JSON.stringify({
        schemaVersion: 1,
        adapter: { defaultModel: '', defaultThoughtLevel: 'high' },
      })
    );
    assert.throws(
      () => loadConfig({ env: makeCleanEnv({ NONLOCAL_CONFIG: cfgPath }), homeDir: root }),
      /defaultThoughtLevel/
    );

    // 2. generic-acp without command
    writeFileSync(
      cfgPath,
      JSON.stringify({
        schemaVersion: 1,
        adapter: { type: 'generic-acp', command: '' },
      })
    );
    assert.throws(
      () => loadConfig({ env: makeCleanEnv({ NONLOCAL_CONFIG: cfgPath }), homeDir: root }),
      /adapter\.command/
    );

    // 3. generic-acp with command and omitted args -> defaults to []
    writeFileSync(
      cfgPath,
      JSON.stringify({
        schemaVersion: 1,
        adapter: { type: 'generic-acp', command: process.execPath },
      })
    );
    const loaded = loadConfig({ env: makeCleanEnv({ NONLOCAL_CONFIG: cfgPath }), homeDir: root });
    assert.equal(loaded.adapter.type, 'generic-acp');
    assert.equal(loaded.adapter.command, process.execPath);
    assert.deepEqual(loaded.adapter.args, []);

    // Real CLI invocation fails closed (exit code 1) with invalid config
    writeFileSync(cfgPath, JSON.stringify({ schemaVersion: 2 }));
    const res = spawnSync(process.execPath, [CLI_PATH, 'start', '--foreground', '--config', cfgPath], {
      encoding: 'utf8',
      env: makeCleanEnv({ HOME: root }),
    });
    assert.equal(res.status, 1);
  } finally {
    rmTempDir(root);
  }
});
