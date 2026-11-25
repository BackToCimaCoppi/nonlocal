import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { StateStore } from '../dist/store/state-store.js';
import { loadConfig } from '../dist/config/index.js';
import { makeTempDir, rmTempDir, makeCleanEnv } from './helpers/test-utils.mjs';

const CLI_PATH = fileURLToPath(new URL('../dist/cli.js', import.meta.url));

test('AC-51: bridge-state.db v1 4-table 19-col schema, snapshot dedup, 16-col upgrade, and corrupt/v2 fail-closed', () => {
  const root = makeTempDir('nonlocal-db-ac51-');
  try {
    const stateDir = join(root, 'state1');
    const store = new StateStore({ stateDir });

    const dirMode = statSync(stateDir).mode & 0o777;
    const dbMode = statSync(store.dbPath).mode & 0o777;
    assert.equal(dirMode, 0o700);
    assert.equal(dbMode, 0o600);

    const sharedModels = {
      availableModels: [{ modelId: 'm1' }, { modelId: 'm2' }],
      currentModelId: 'm1',
    };
    const sharedModes = {
      availableModes: [{ id: 'ask' }, { id: 'code' }],
      currentModeId: 'ask',
    };
    const sharedConfig = [
      { id: 'model', currentValue: 'm1', options: [{ value: 'm1' }, { value: 'm2' }] },
      { id: 'thought_level', currentValue: 'low', options: [{ value: 'low' }, { value: 'high' }] },
    ];

    store.recordCreated({
      sessionId: 'sess-1',
      cwd: root,
      models: sharedModels,
      modes: sharedModes,
      configOptions: sharedConfig,
    });
    store.recordCreated({
      sessionId: 'sess-2',
      cwd: root,
      models: { ...sharedModels, currentModelId: 'm2' },
      modes: { ...sharedModes, currentModeId: 'code' },
      configOptions: [
        { id: 'model', currentValue: 'm2', options: [{ value: 'm1' }, { value: 'm2' }] },
        { id: 'thought_level', currentValue: 'high', options: [{ value: 'low' }, { value: 'high' }] },
      ],
    });

    assert.equal(store.get('sess-1')?.models?.currentModelId, 'm1');
    assert.equal(store.get('sess-2')?.models?.currentModelId, 'm2');
    assert.equal(store.get('sess-1')?.modes?.currentModeId, 'ask');
    assert.equal(store.get('sess-2')?.modes?.currentModeId, 'code');
    store.close();

    // Verify PRAGMAs, 4 tables, 19 cols, capability dedup
    const rawDb = new DatabaseSync(store.dbPath, { readOnly: true });
    assert.equal(rawDb.prepare('PRAGMA journal_mode').get().journal_mode, 'delete');
    assert.equal(rawDb.prepare('PRAGMA synchronous').get().synchronous, 2);
    assert.equal(rawDb.prepare('PRAGMA quick_check').get().quick_check, 'ok');
    const tables = rawDb
      .prepare("SELECT name FROM sqlite_master WHERE type='table'")
      .all()
      .map((r) => r.name);
    for (const tbl of ['meta', 'capability_snapshots', 'sessions', 'usage_snapshot']) {
      assert.ok(tables.includes(tbl), `missing table ${tbl}`);
    }
    const cols = rawDb.prepare('PRAGMA table_info(sessions)').all();
    assert.equal(cols.length, 19);
    const capCount = rawDb.prepare('SELECT COUNT(*) AS cnt FROM capability_snapshots').get().cnt;
    assert.equal(capCount, 3, 'models, modes, configOptions should deduplicate to 3 rows');
    rawDb.close();

    // 2. Upgrade old 16-column v1 DB idempotently
    const state16Dir = join(root, 'state16');
    mkdirSync(state16Dir, { recursive: true, mode: 0o700 });
    const oldDbPath = join(state16Dir, 'bridge-state.db');
    const oldDb = new DatabaseSync(oldDbPath);
    oldDb.exec(`
      CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      INSERT INTO meta (key, value) VALUES ('schema_version', '1');
      CREATE TABLE capability_snapshots (hash TEXT PRIMARY KEY, kind TEXT NOT NULL, payload_json TEXT NOT NULL);
      CREATE TABLE sessions (
        session_id TEXT PRIMARY KEY, cwd TEXT NOT NULL, created_at TEXT, updated_at TEXT NOT NULL,
        upstream_title TEXT, custom_title TEXT, ai_title TEXT, fallback_title TEXT,
        summary_attempted INTEGER NOT NULL DEFAULT 0, summary_status TEXT,
        selected_model_id TEXT, selected_mode_id TEXT, selected_config_json TEXT,
        models_hash TEXT, modes_hash TEXT, config_options_hash TEXT
      );
    `);
    oldDb.close();
    const upgraded = new StateStore({ stateDir: state16Dir });
    upgraded.close();
    const check16 = new DatabaseSync(oldDbPath, { readOnly: true });
    const upgradedCols = check16.prepare('PRAGMA table_info(sessions)').all().map((c) => c.name);
    assert.ok(upgradedCols.includes('commands_hash'));
    assert.ok(upgradedCols.includes('seen_in_upstream_list'));
    assert.ok(upgradedCols.includes('seen_on_disk'));
    check16.close();

    // 3. Corrupt DB & schema_version=2 fail-closed
    const corruptDir = join(root, 'corrupt');
    mkdirSync(corruptDir, { recursive: true, mode: 0o700 });
    writeFileSync(join(corruptDir, 'bridge-state.db'), 'not-a-sqlite-file', { mode: 0o600 });
    assert.throws(() => new StateStore({ stateDir: corruptDir }), /Fail-closed/);

    const v2Dir = join(root, 'v2');
    mkdirSync(v2Dir, { recursive: true, mode: 0o700 });
    const v2Db = new DatabaseSync(join(v2Dir, 'bridge-state.db'));
    v2Db.exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL); INSERT INTO meta VALUES ('schema_version', '2');");
    v2Db.close();
    assert.throws(() => new StateStore({ stateDir: v2Dir }), /schema_version/);
  } finally {
    rmTempDir(root);
  }
});

test('AC-52: strict new/legacy directory isolation and no owned-sessions.json auto-migration (PP-52-isolate)', () => {
  const root = makeTempDir('nonlocal-db-ac52-');
  try {
    const legacyCfgDir = join(root, '.config', 'agy-acp');
    const legacyStateDir = join(root, '.local', 'state', 'agy-acp-local');
    mkdirSync(legacyCfgDir, { recursive: true, mode: 0o700 });
    mkdirSync(legacyStateDir, { recursive: true, mode: 0o700 });

    const legacyTok = join(legacyCfgDir, 'bearer.token');
    writeFileSync(legacyTok, 'a'.repeat(64), { mode: 0o600 });
    const legacyDb = new DatabaseSync(join(legacyStateDir, 'bridge-state.db'));
    legacyDb.exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL); INSERT INTO meta VALUES ('schema_version', '1');");
    legacyDb.close();
    const legacyOwned = join(legacyStateDir, 'owned-sessions.json');
    writeFileSync(legacyOwned, JSON.stringify({ version: 1, sessions: { 'old-1': { cwd: '/tmp' } } }));

    const mtimeBefore = statSync(legacyTok).mtimeMs;
    const dbMtimeBefore = statSync(join(legacyStateDir, 'bridge-state.db')).mtimeMs;

    // Require config file fails when ~/.config/nonlocal/config.json is absent (zero fallback to legacy)
    assert.throws(
      () => loadConfig({ env: makeCleanEnv({ HOME: root }), homeDir: root, requireConfigFile: true }),
      /nonlocal-bridge init/
    );
    assert.equal(statSync(legacyTok).mtimeMs, mtimeBefore);
    assert.equal(statSync(join(legacyStateDir, 'bridge-state.db')).mtimeMs, dbMtimeBefore);

    // Even if owned-sessions.json sits inside new state dir, StateStore ignores it completely
    const newStateDir = join(root, '.local', 'state', 'nonlocal');
    mkdirSync(newStateDir, { recursive: true, mode: 0o700 });
    const strayOwned = join(newStateDir, 'owned-sessions.json');
    writeFileSync(strayOwned, JSON.stringify({ version: 1, sessions: { 'old-2': { cwd: '/tmp' } } }));
    const store = new StateStore({ stateDir: newStateDir });
    assert.equal(store.size(), 0);
    assert.equal(store.has('old-2'), false);
    store.close();
    chmodSync(strayOwned, 0o600);

    // Real CLI invocation fails without ~/.config/nonlocal/config.json and leaves legacy dirs untouched
    const cliRes = spawnSync(process.execPath, [CLI_PATH, 'start', '--standalone'], {
      encoding: 'utf8',
      env: makeCleanEnv({ HOME: root }),
    });
    assert.equal(cliRes.status, 1);
    assert.equal(statSync(legacyTok).mtimeMs, mtimeBefore);
    assert.equal(statSync(join(legacyStateDir, 'bridge-state.db')).mtimeMs, dbMtimeBefore);
  } finally {
    rmTempDir(root);
  }
});
