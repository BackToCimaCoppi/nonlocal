import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { getFreePort, makeCleanEnv, makeTempDir, rmTempDir } from './helpers/test-utils.mjs';

const CLI_PATH = fileURLToPath(new URL('../dist/cli.js', import.meta.url));

function sha256File(p) {
  return createHash('sha256').update(readFileSync(p)).digest('hex');
}

test('AC-53 & AC-54: init --import-legacy read-only source, VACUUM INTO DB copy, bearer.token copy, translate.json secret stripping, overwrite refusal, and fail-closed corrupt/short inputs (PP-53-ro, PP-54-atomic)', async () => {
  const root = makeTempDir('nonlocal-imp-ac53-');
  const blocker = net.createServer();
  try {
    const legCfg = join(root, 'legacy-cfg');
    const legState = join(root, 'legacy-state');
    mkdirSync(legCfg, { recursive: true, mode: 0o700 });
    mkdirSync(legState, { recursive: true, mode: 0o700 });

    const tokVal = 'legacy_bearer_token_' + 'a'.repeat(48);
    const legTokPath = join(legCfg, 'bearer.token');
    writeFileSync(legTokPath, `${tokVal}\n`, { mode: 0o600 });

    const legDbPath = join(legState, 'bridge-state.db');
    const legDb = new DatabaseSync(legDbPath);
    legDb.exec(`
      CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      INSERT INTO meta VALUES ('schema_version', '1');
      CREATE TABLE capability_snapshots (hash TEXT PRIMARY KEY, kind TEXT NOT NULL, payload_json TEXT NOT NULL);
      CREATE TABLE sessions (
        session_id TEXT PRIMARY KEY, cwd TEXT NOT NULL, created_at TEXT, updated_at TEXT NOT NULL,
        upstream_title TEXT, custom_title TEXT, ai_title TEXT, fallback_title TEXT,
        summary_attempted INTEGER NOT NULL DEFAULT 0, summary_status TEXT,
        selected_model_id TEXT, selected_mode_id TEXT, selected_config_json TEXT,
        models_hash TEXT, modes_hash TEXT, config_options_hash TEXT, commands_hash TEXT,
        seen_in_upstream_list INTEGER NOT NULL DEFAULT 0, seen_on_disk INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE usage_snapshot (id INTEGER PRIMARY KEY CHECK (id = 1), payload_json TEXT NOT NULL, updated_at TEXT NOT NULL);
    `);
    legDb.prepare(
      "INSERT INTO sessions (session_id, cwd, created_at, updated_at, custom_title) VALUES ('leg-s1', ?, '2026-11-20T00:00:00Z', '2026-11-20T00:00:00Z', 'Legacy Title')"
    ).run(root);
    legDb.close();

    const legTranslatePath = join(legCfg, 'translate.json');
    writeFileSync(
      legTranslatePath,
      JSON.stringify({
        disabled: false,
        url: 'https://api.example.com/v1',
        model: 'gpt-mini',
        apiKey: 'sk-legacy-inline-secret-key',
      })
    );

    const tokHashBefore = sha256File(legTokPath);
    const dbHashBefore = sha256File(legDbPath);
    const transHashBefore = sha256File(legTranslatePath);
    const tokMtimeBefore = statSync(legTokPath).mtimeMs;
    const dbMtimeBefore = statSync(legDbPath).mtimeMs;

    // Test port-occupied notice with NONLOCAL_PORT pointing to an occupied ephemeral blocker (never touching 8765)
    const occPort = await getFreePort('127.0.0.1');
    const freePort = await getFreePort('127.0.0.1');
    await new Promise((res) => blocker.listen(occPort, '127.0.0.1', res));

    const newHome = join(root, 'new-home');
    mkdirSync(newHome, { recursive: true });
    const impOcc = spawnSync(
      process.execPath,
      [
        CLI_PATH,
        'init',
        '--yes',
        '--import-legacy',
        '--legacy-config-dir',
        legCfg,
        '--legacy-state-dir',
        legState,
      ],
      {
        encoding: 'utf8',
        env: makeCleanEnv({ HOME: newHome, NONLOCAL_PORT: String(occPort) }),
      }
    );
    assert.equal(impOcc.status, 0);
    const outOcc = `${impOcc.stdout}\n${impOcc.stderr}`;
    assert.equal(outOcc.includes('occupied_by_other'), true, 'must warn when target port is occupied_by_other');
    await new Promise((res) => blocker.close(res));
    assert.equal(outOcc.includes(tokVal), false, 'plaintext token must NEVER be printed');
    assert.equal(outOcc.includes('sk-legacy-inline-secret-key'), false);

    // Legacy files strictly untouched
    assert.equal(sha256File(legTokPath), tokHashBefore);
    assert.equal(sha256File(legDbPath), dbHashBefore);
    assert.equal(sha256File(legTranslatePath), transHashBefore);
    assert.equal(statSync(legTokPath).mtimeMs, tokMtimeBefore);
    assert.equal(statSync(legDbPath).mtimeMs, dbMtimeBefore);

    // New files verified
    const newCfgDir = join(newHome, '.config', 'nonlocal');
    const newStateDir = join(newHome, '.local', 'state', 'nonlocal');
    const newCfg = JSON.parse(readFileSync(join(newCfgDir, 'config.json'), 'utf8'));
    assert.equal(newCfg.server.port, occPort);
    assert.equal(newCfg.titleSummary.enabled, true);
    assert.equal(newCfg.titleSummary.language, 'zh');
    assert.equal(newCfg.titleSummary.apiKey, undefined);
    assert.equal(statSync(join(newCfgDir, 'bearer.token')).mode & 0o777, 0o600);
    assert.equal(statSync(join(newCfgDir, 'title-summary.key')).mode & 0o777, 0o600);
    assert.equal(readFileSync(join(newCfgDir, 'bearer.token'), 'utf8').trim(), tokVal);
    assert.equal(readFileSync(join(newCfgDir, 'title-summary.key'), 'utf8').trim(), 'sk-legacy-inline-secret-key');

    const newDb = new DatabaseSync(join(newStateDir, 'bridge-state.db'), { readOnly: true });
    assert.equal(newDb.prepare('PRAGMA quick_check').get().quick_check, 'ok');
    assert.equal(newDb.prepare("SELECT custom_title FROM sessions WHERE session_id = 'leg-s1'").get().custom_title, 'Legacy Title');
    newDb.close();

    // Re-running without --force refuses overwrite (exit 1), while --force succeeds on freePort with zero occupied warning
    assert.throws(
      () =>
        execFileSync(
          process.execPath,
          [CLI_PATH, 'init', '--yes', '--import-legacy', '--legacy-config-dir', legCfg, '--legacy-state-dir', legState],
          { encoding: 'utf8', env: makeCleanEnv({ HOME: newHome, NONLOCAL_PORT: String(freePort) }), stdio: 'pipe' }
        )
    );
    const forceFree = spawnSync(
      process.execPath,
      [CLI_PATH, 'init', '--yes', '--force', '--import-legacy', '--legacy-config-dir', legCfg, '--legacy-state-dir', legState, '--title-language', 'en'],
      { encoding: 'utf8', env: makeCleanEnv({ HOME: newHome, NONLOCAL_PORT: String(freePort) }) }
    );
    assert.equal(forceFree.status, 0);
    assert.equal(`${forceFree.stdout}\n${forceFree.stderr}`.includes('occupied_by_other'), false);
    assert.equal(JSON.parse(readFileSync(join(newCfgDir, 'config.json'), 'utf8')).titleSummary.language, 'en');

    // External keyFile import strips key into 0600 title-summary.key & disabled:true degrades gracefully
    const extKeyPath = join(root, 'ext-sum.key');
    writeFileSync(extKeyPath, 'sk-external-summary-key-value', { mode: 0o600 });
    writeFileSync(
      legTranslatePath,
      JSON.stringify({ disabled: false, url: 'https://api.example.com/v1', model: 'gpt-mini', keyFile: extKeyPath })
    );
    const extHome = join(root, 'ext-home');
    mkdirSync(extHome, { recursive: true });
    execFileSync(
      process.execPath,
      [CLI_PATH, 'init', '--yes', '--import-legacy', '--legacy-config-dir', legCfg, '--legacy-state-dir', legState],
      { encoding: 'utf8', env: makeCleanEnv({ HOME: extHome, NONLOCAL_PORT: String(freePort) }), stdio: 'pipe' }
    );
    assert.equal(readFileSync(join(extHome, '.config', 'nonlocal', 'title-summary.key'), 'utf8').trim(), 'sk-external-summary-key-value');

    writeFileSync(legTranslatePath, JSON.stringify({ disabled: true, url: 'https://api.example.com/v1', model: 'gpt-mini' }));
    const disHome = join(root, 'dis-home');
    mkdirSync(disHome, { recursive: true });
    execFileSync(
      process.execPath,
      [CLI_PATH, 'init', '--yes', '--import-legacy', '--legacy-config-dir', legCfg, '--legacy-state-dir', legState],
      { encoding: 'utf8', env: makeCleanEnv({ HOME: disHome, NONLOCAL_PORT: String(freePort) }), stdio: 'pipe' }
    );
    assert.equal(JSON.parse(readFileSync(join(disHome, '.config', 'nonlocal', 'config.json'), 'utf8')).titleSummary.enabled, false);

    // Degrade disabled/malformed translate.json gracefully with --force
    writeFileSync(legTranslatePath, '{broken-json');
    const badTransHome = join(root, 'bad-trans-home');
    mkdirSync(badTransHome, { recursive: true });
    execFileSync(
      process.execPath,
      [CLI_PATH, 'init', '--yes', '--import-legacy', '--legacy-config-dir', legCfg, '--legacy-state-dir', legState],
      { encoding: 'utf8', env: makeCleanEnv({ HOME: badTransHome, NONLOCAL_PORT: String(freePort) }), stdio: 'pipe' }
    );
    const downgradedCfg = JSON.parse(readFileSync(join(badTransHome, '.config', 'nonlocal', 'config.json'), 'utf8'));
    assert.equal(downgradedCfg.titleSummary.enabled, false);

    // Corrupt legacy DB -> fail-closed exit 1 with ZERO target leftovers
    const badDbHome = join(root, 'bad-db-home');
    mkdirSync(badDbHome, { recursive: true });
    writeFileSync(legDbPath, 'CORRUPT_DB_BYTES');
    assert.throws(
      () =>
        execFileSync(
          process.execPath,
          [CLI_PATH, 'init', '--yes', '--import-legacy', '--legacy-config-dir', legCfg, '--legacy-state-dir', legState],
          { encoding: 'utf8', env: makeCleanEnv({ HOME: badDbHome, NONLOCAL_PORT: String(freePort) }), stdio: 'pipe' }
        )
    );
    assert.equal(existsSync(join(badDbHome, '.config', 'nonlocal', 'config.json')), false);

    // Short (<32B) legacy token -> fail-closed exit 1
    const shortHome = join(root, 'short-tok-home');
    mkdirSync(shortHome, { recursive: true });
    writeFileSync(legTokPath, 'too-short\n', { mode: 0o600 });
    assert.throws(
      () =>
        execFileSync(
          process.execPath,
          [CLI_PATH, 'init', '--yes', '--import-legacy', '--legacy-config-dir', legCfg, '--legacy-state-dir', legState],
          { encoding: 'utf8', env: makeCleanEnv({ HOME: shortHome, NONLOCAL_PORT: String(freePort) }), stdio: 'pipe' }
        )
    );
    chmodSync(legTokPath, 0o600);
  } finally {
    try {
      blocker.close();
    } catch {
      // ignore
    }
    rmTempDir(root);
  }
});
