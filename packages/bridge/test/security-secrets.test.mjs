import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig, readValidatedSecretFile, MIN_TOKEN_BYTES } from '../dist/config/index.js';
import { SanitizedLogger } from '../dist/log/logger.js';
import { makeTempDir, rmTempDir, makeCleanEnv, createTestToken } from './helpers/test-utils.mjs';

const CLI_PATH = fileURLToPath(new URL('../dist/cli.js', import.meta.url));

test('AC-10: config.json rejects top-level and nested plaintext secret keys (PP-10-reject)', () => {
  const root = makeTempDir('nonlocal-sec-ac10-');
  try {
    const cfgPath = join(root, 'config.json');
    const badConfigs = [
      { schemaVersion: 1, token: 'secret-value' },
      { schemaVersion: 1, security: { bearerToken: 'secret-value' } },
      { schemaVersion: 1, titleSummary: { apiKey: 'sk-plain' } },
      { schemaVersion: 1, titleSummary: { key: 'sk-plain' } },
      { schemaVersion: 1, server: { secret: 's' } },
      { schemaVersion: 1, adapter: { password: 'p' } },
    ];
    for (const bad of badConfigs) {
      writeFileSync(cfgPath, JSON.stringify(bad), 'utf8');
      assert.throws(
        () => loadConfig({ env: makeCleanEnv({ NONLOCAL_CONFIG: cfgPath }), homeDir: root }),
        /forbidden/i
      );
    }
  } finally {
    rmTempDir(root);
  }
});

test('AC-11: secret files enforce existence, non-git repo, 0600 mode, and >=32B length (PP-11-reject)', () => {
  const root = makeTempDir('nonlocal-sec-ac11-');
  try {
    // 1. missing file
    assert.throws(() => readValidatedSecretFile(join(root, 'missing.token'), 'tokenFile', MIN_TOKEN_BYTES), /does not exist/);

    // 2. inside git repo (.git dir or .git file)
    const gitRepo = join(root, 'git-repo');
    mkdirSync(join(gitRepo, '.git'), { recursive: true });
    const gitTok = join(gitRepo, 'tok.txt');
    writeFileSync(gitTok, createTestToken(64), { mode: 0o600 });
    chmodSync(gitTok, 0o600);
    assert.throws(() => readValidatedSecretFile(gitTok, 'tokenFile', MIN_TOKEN_BYTES), /Git repository/);

    // 3. loose permission 0644
    const looseTok = join(root, 'loose.token');
    writeFileSync(looseTok, createTestToken(64), { mode: 0o644 });
    chmodSync(looseTok, 0o644);
    assert.throws(() => readValidatedSecretFile(looseTok, 'tokenFile', MIN_TOKEN_BYTES), /too open/);

    // 4. 31 bytes (< 32)
    const shortTok = join(root, 'short.token');
    writeFileSync(shortTok, 'a'.repeat(31) + '\n', { mode: 0o600 });
    chmodSync(shortTok, 0o600);
    assert.throws(() => readValidatedSecretFile(shortTok, 'tokenFile', MIN_TOKEN_BYTES), /shorter than 32/);

    // 5. positive boundary: 32 bytes, 0600, non-git
    const exact32 = join(root, 'exact32.token');
    const val32 = 'b'.repeat(32);
    writeFileSync(exact32, `${val32}\n`, { mode: 0o600 });
    chmodSync(exact32, 0o600);
    const ok = readValidatedSecretFile(exact32, 'tokenFile', MIN_TOKEN_BYTES);
    assert.equal(ok.value, val32);
    assert.equal(ok.length, 32);
    assert.equal(ok.mode, 0o600);

    // CLI start fails closed (exit 1) when bearer.token is 0644 or config contains plaintext secret
    const cliCfg = join(root, 'cli-cfg.json');
    writeFileSync(cliCfg, JSON.stringify({ schemaVersion: 1, security: { tokenFile: looseTok }, adapter: { type: 'generic-acp', command: process.execPath } }));
    const rLoose = spawnSync(process.execPath, [CLI_PATH, 'start', '--foreground', '--config', cliCfg], { env: makeCleanEnv({ HOME: root }) });
    assert.equal(rLoose.status, 1);

    writeFileSync(cliCfg, JSON.stringify({ schemaVersion: 1, token: 'plain', security: { tokenFile: exact32 }, adapter: { type: 'generic-acp', command: process.execPath } }));
    const rPlain = spawnSync(process.execPath, [CLI_PATH, 'start', '--foreground', '--config', cliCfg], { env: makeCleanEnv({ HOME: root }) });
    assert.equal(rPlain.status, 1);
  } finally {
    rmTempDir(root);
  }
});

test('AC-12: SanitizedLogger preserves G-4/security whitelist keys, strips non-whitelist keys, redacts secrets, rotates with 0600 (PP-12-redact)', () => {
  const root = makeTempDir('nonlocal-sec-ac12-');
  try {
    const logFile = join(root, 'state', 'bridge.log');
    const bearer = 'tok_' + createTestToken(48);
    const apiKey = 'sk-test-' + createTestToken(32);
    const logger = new SanitizedLogger({
      logFile,
      maxBytes: 320,
      maxBackups: 2,
      redactSecrets: [bearer],
    });
    logger.registerSecret(apiKey);

    for (let i = 0; i < 12; i++) {
      logger.log('info', i % 2 === 0 ? 'session_deleted' : 'ws_auth_rejected', {
        sessionId: `s-${i}`,
        alreadyAbsent: i === 0,
        deletedSubagentCount: i,
        message: `Authorization: Bearer ${bearer} key=${apiKey}`,
        reason: 'ws_auth_rate_limited',
        warningLevel: 'lan_plaintext',
        // Non-whitelisted keys must be stripped completely
        prompt: 'SENSITIVE_USER_PROMPT_BODY',
        rawTitle: 'SENSITIVE_RAW_TITLE',
        content: 'SENSITIVE_FILE_CONTENT',
      });
    }

    const files = readdirSync(join(root, 'state')).filter((f) => f.startsWith('bridge.log'));
    assert.ok(files.includes('bridge.log'));
    assert.ok(files.includes('bridge.log.1'));
    assert.ok(!files.includes('bridge.log.3'), 'rotations must stay <= maxBackups');

    let sawAlreadyAbsent = false;
    let sawDeletedSubagentCount = false;
    let sawMessage = false;

    for (const fname of files) {
      const full = join(root, 'state', fname);
      const st = statSync(full);
      assert.equal(st.mode & 0o777, 0o600, `${fname} must be 0600`);
      const text = readFileSync(full, 'utf8');
      assert.equal(text.includes(bearer), false, 'bearer token leaked in log');
      assert.equal(text.includes(apiKey), false, 'apiKey leaked in log');
      assert.equal(text.includes('SENSITIVE_USER_PROMPT_BODY'), false);
      assert.equal(text.includes('SENSITIVE_RAW_TITLE'), false);
      assert.equal(text.includes('SENSITIVE_FILE_CONTENT'), false);

      for (const line of text.trim().split('\n')) {
        const obj = JSON.parse(line);
        if (Object.hasOwn(obj, 'alreadyAbsent')) sawAlreadyAbsent = true;
        if (Object.hasOwn(obj, 'deletedSubagentCount')) sawDeletedSubagentCount = true;
        if (Object.hasOwn(obj, 'message')) sawMessage = true;
        assert.equal(obj.prompt, undefined);
        assert.equal(obj.rawTitle, undefined);
        assert.equal(obj.content, undefined);
      }
    }

    assert.equal(sawAlreadyAbsent, true);
    assert.equal(sawDeletedSubagentCount, true);
    assert.equal(sawMessage, true);
  } finally {
    rmTempDir(root);
  }
});
