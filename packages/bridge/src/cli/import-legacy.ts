import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  renameSync,
  unlinkSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve as resolvePath } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import {
  assertPrivateFileTarget,
  atomicWritePrivateFile,
  MIN_TOKEN_BYTES,
  readValidatedSecretFile,
} from '../config/secrets.js';
const MIN_API_KEY_BYTES = 1;
import { createDefaultConfig, serializeConfigForDisk, validateResolvedConfig } from '../config/schema.js';
import { expandHome, resolveDefaultConfigPath, resolveDefaultStateDir, resolveDefaultTokenPath } from '../config/paths.js';
import type { BridgeConfig, TitleLanguage } from '../config/types.js';
import { probePortOwnership, type PortOwnershipState } from '../service/runtime.js';

export interface ImportLegacyOptions {
  homeDir?: string;
  env?: NodeJS.ProcessEnv;
  legacyConfigDir?: string;
  legacyStateDir?: string;
  configPath?: string;
  stateDir?: string;
  tokenFile?: string;
  host?: string;
  port?: number;
  allowNonLoopback?: boolean;
  titleLanguage?: TitleLanguage;
  force?: boolean;
}

export interface ImportLegacyResult {
  configPath: string;
  tokenPath: string;
  stateDir: string;
  dbPath: string | null;
  titleSummaryEnabled: boolean;
  warnings: string[];
  portState: PortOwnershipState;
}

function assertNotSymlinkIfExists(filePath: string, label: string): void {
  if (!existsSync(filePath)) return;
  const st = lstatSync(filePath);
  if (st.isSymbolicLink()) {
    throw new Error(`Refusing ${label} target "${filePath}": target is a symbolic link`);
  }
}

export async function runImportLegacy(opts: ImportLegacyOptions = {}): Promise<ImportLegacyResult> {
  const env = opts.env ?? process.env;
  const homeDir = opts.homeDir ?? homedir();

  const legacyConfigDir = resolvePath(
    expandHome(opts.legacyConfigDir || join(homeDir, '.config', 'agy-acp'), homeDir)
  );
  const legacyStateDir = resolvePath(
    expandHome(opts.legacyStateDir || join(homeDir, '.local', 'state', 'agy-acp-local'), homeDir)
  );

  const targetConfigPath = opts.configPath
    ? resolvePath(expandHome(opts.configPath, homeDir))
    : resolveDefaultConfigPath(env, homeDir);
  const targetStateDir = opts.stateDir
    ? resolvePath(expandHome(opts.stateDir, homeDir))
    : resolveDefaultStateDir(env, homeDir);
  const targetTokenPath = opts.tokenFile
    ? resolvePath(expandHome(opts.tokenFile, homeDir))
    : join(dirname(targetConfigPath), 'bearer.token') || resolveDefaultTokenPath(env, homeDir);
  const targetDbPath = join(targetStateDir, 'bridge-state.db');
  const targetTitleKeyPath = join(dirname(targetConfigPath), 'title-summary.key');

  const warnings: string[] = [];

  if (!opts.force) {
    for (const [p, label] of [
      [targetConfigPath, 'config.json'],
      [targetTokenPath, 'bearer.token'],
      [targetDbPath, 'bridge-state.db'],
      [targetTitleKeyPath, 'title-summary.key'],
    ] as const) {
      if (existsSync(p)) {
        throw new Error(`Target ${label} already exists (${p}); re-run with --force to overwrite`);
      }
    }
  }

  for (const [p, label] of [
    [targetConfigPath, 'config.json'],
    [targetTokenPath, 'bearer.token'],
    [targetDbPath, 'bridge-state.db'],
    [targetTitleKeyPath, 'title-summary.key'],
  ] as const) {
    assertNotSymlinkIfExists(p, label);
    assertPrivateFileTarget(p, label);
  }

  // 1. Validate & copy legacy bearer.token (strictly read-only on legacy)
  const legacyTokenPath = join(legacyConfigDir, 'bearer.token');
  if (!existsSync(legacyTokenPath)) {
    throw new Error(`Legacy bearer.token not found at "${legacyTokenPath}"`);
  }
  const legacyTokenRaw = readFileSync(legacyTokenPath, 'utf8');
  const legacyTokenTrimmed = legacyTokenRaw.trim();
  if (Buffer.byteLength(legacyTokenTrimmed, 'utf8') < MIN_TOKEN_BYTES) {
    throw new Error(`Legacy bearer.token (${legacyTokenPath}) is shorter than ${MIN_TOKEN_BYTES} bytes`);
  }

  // 2. Inspect legacy DB strictly readOnly and copy safely via VACUUM INTO (ZERO .backup)
  const legacyDbPath = join(legacyStateDir, 'bridge-state.db');
  let migratedDb = false;
  let tempVacuumPath: string | null = null;

  if (existsSync(legacyDbPath)) {
    let roDb: DatabaseSync | null = null;
    try {
      roDb = new DatabaseSync(legacyDbPath, { readOnly: true });
      const qc = roDb.prepare('PRAGMA quick_check;').all() as Array<{ quick_check?: string }>;
      if (qc.length !== 1 || qc[0]?.quick_check !== 'ok') {
        throw new Error('Legacy bridge-state.db failed PRAGMA quick_check');
      }
      const ver = roDb.prepare("SELECT value FROM meta WHERE key = 'schema_version'").get() as
        | { value?: string }
        | undefined;
      if (ver && ver.value !== '1') {
        throw new Error(`Unsupported legacy schema_version "${String(ver.value)}"`);
      }

      mkdirSync(targetStateDir, { recursive: true, mode: 0o700 });
      chmodSync(targetStateDir, 0o700);
      tempVacuumPath = `${targetDbPath}.tmp.${process.pid}.${Date.now()}`;
      const escapedSqlPath = tempVacuumPath.replace(/'/g, "''");
      roDb.exec(`VACUUM INTO '${escapedSqlPath}'`);
      roDb.close();
      roDb = null;

      // Verify freshly vacuumed DB copy before renaming into place
      const verifyDb = new DatabaseSync(tempVacuumPath, { readOnly: true });
      try {
        const vqc = verifyDb.prepare('PRAGMA quick_check;').all() as Array<{ quick_check?: string }>;
        if (vqc.length !== 1 || vqc[0]?.quick_check !== 'ok') {
          throw new Error('Migrated bridge-state.db failed post-VACUUM quick_check');
        }
      } finally {
        verifyDb.close();
      }
      chmodSync(tempVacuumPath, 0o600);
      renameSync(tempVacuumPath, targetDbPath);
      chmodSync(targetDbPath, 0o600);
      tempVacuumPath = null;
      migratedDb = true;
    } catch (err) {
      try {
        roDb?.close();
      } catch {
        // ignore
      }
      if (tempVacuumPath && existsSync(tempVacuumPath)) {
        try {
          unlinkSync(tempVacuumPath);
        } catch {
          // ignore
        }
      }
      throw new Error(
        `Fail-closed migrating legacy DB (${legacyDbPath}): ${err instanceof Error ? err.message : String(err)}`
      );
    }
  } else {
    mkdirSync(targetStateDir, { recursive: true, mode: 0o700 });
    chmodSync(targetStateDir, 0o700);
  }

  // 3. Parse legacy translate.json cleanly & safely (no plaintext secret inside config.json)
  const cfg: BridgeConfig = createDefaultConfig(env, homeDir);
  cfg.configPath = targetConfigPath;
  cfg.security.tokenFile = targetTokenPath;
  cfg.state.dir = targetStateDir;
  cfg.state.logFile = join(targetStateDir, 'bridge.log');

  if (env.NONLOCAL_HOST?.trim()) cfg.server.host = env.NONLOCAL_HOST.trim();
  if (env.NONLOCAL_PORT?.trim()) cfg.server.port = Number(env.NONLOCAL_PORT.trim());
  if (env.NONLOCAL_ALLOW_NON_LOOPBACK?.trim()) {
    const v = env.NONLOCAL_ALLOW_NON_LOOPBACK.trim().toLowerCase();
    if (v === '1' || v === 'true') cfg.server.allowNonLoopback = true;
    else if (v === '0' || v === 'false') cfg.server.allowNonLoopback = false;
  }
  if (opts.host !== undefined) cfg.server.host = String(opts.host).trim();
  if (opts.port !== undefined) cfg.server.port = Number(opts.port);
  if (opts.allowNonLoopback !== undefined) cfg.server.allowNonLoopback = Boolean(opts.allowNonLoopback);

  let titleSummaryEnabled = false;
  let apiKeyValueToWrite: string | null = null;
  const legacyTranslatePath = join(legacyConfigDir, 'translate.json');
  if (existsSync(legacyTranslatePath)) {
    try {
      const parsed = JSON.parse(readFileSync(legacyTranslatePath, 'utf8')) as Record<string, unknown>;
      const rawUrl = typeof parsed.url === 'string' ? parsed.url.trim() : typeof parsed.endpoint === 'string' ? parsed.endpoint.trim() : '';
      const rawModel = typeof parsed.model === 'string' ? parsed.model.trim() : '';
      const disabled = Boolean(parsed.disabled);

      let urlOk = false;
      if (rawUrl) {
        try {
          const u = new URL(rawUrl);
          urlOk = u.protocol === 'http:' || u.protocol === 'https:';
        } catch {
          urlOk = false;
        }
      }

      if (!disabled && urlOk && rawModel) {
        titleSummaryEnabled = true;
        cfg.titleSummary.enabled = true;
        cfg.titleSummary.endpoint = rawUrl;
        cfg.titleSummary.model = rawModel;
        cfg.titleSummary.language = opts.titleLanguage ?? 'zh';

        const inlineKey =
          typeof parsed.apiKey === 'string' && parsed.apiKey.trim()
            ? parsed.apiKey.trim()
            : typeof parsed.key === 'string' && parsed.key.trim()
              ? parsed.key.trim()
              : '';
        const extKeyFile =
          typeof parsed.apiKeyFile === 'string' && parsed.apiKeyFile.trim()
            ? resolvePath(expandHome(parsed.apiKeyFile.trim(), homeDir))
            : typeof parsed.keyFile === 'string' && parsed.keyFile.trim()
              ? resolvePath(expandHome(parsed.keyFile.trim(), homeDir))
              : '';

        if (inlineKey) {
          if (Buffer.byteLength(inlineKey, 'utf8') < MIN_API_KEY_BYTES) {
            titleSummaryEnabled = false;
            cfg.titleSummary.enabled = false;
            warnings.push('Legacy translate.json apiKey is empty/too short; downgraded titleSummary.enabled=false');
          } else {
            apiKeyValueToWrite = inlineKey;
            cfg.titleSummary.apiKeyFile = targetTitleKeyPath;
          }
        } else if (extKeyFile) {
          if (existsSync(extKeyFile)) {
            const loaded = readFileSync(extKeyFile, 'utf8').trim();
            if (Buffer.byteLength(loaded, 'utf8') >= MIN_API_KEY_BYTES) {
              apiKeyValueToWrite = loaded;
              cfg.titleSummary.apiKeyFile = targetTitleKeyPath;
            } else {
              titleSummaryEnabled = false;
              cfg.titleSummary.enabled = false;
              warnings.push(`Legacy title key file "${extKeyFile}" invalid; downgraded titleSummary.enabled=false`);
            }
          } else {
            titleSummaryEnabled = false;
            cfg.titleSummary.enabled = false;
            warnings.push(`Legacy title key file "${extKeyFile}" missing; downgraded titleSummary.enabled=false`);
          }
        }
      } else {
        cfg.titleSummary.enabled = false;
        if (disabled) {
          warnings.push('Legacy translate.json has disabled=true; imported with titleSummary.enabled=false');
        } else {
          warnings.push('Legacy translate.json incomplete (missing valid url/model); downgraded titleSummary.enabled=false');
        }
      }
    } catch {
      cfg.titleSummary.enabled = false;
      warnings.push('Legacy translate.json malformed JSON; downgraded titleSummary.enabled=false');
    }
  }

  validateResolvedConfig(cfg);

  // 4. Write new config, bearer token, and stripped title-summary.key atomically with 0600
  mkdirSync(dirname(targetConfigPath), { recursive: true, mode: 0o700 });
  atomicWritePrivateFile(targetTokenPath, `${legacyTokenTrimmed}\n`);
  if (apiKeyValueToWrite !== null) {
    atomicWritePrivateFile(targetTitleKeyPath, `${apiKeyValueToWrite}\n`);
  }
  readValidatedSecretFile(targetTokenPath, 'security.tokenFile', MIN_TOKEN_BYTES);
  atomicWritePrivateFile(targetConfigPath, `${JSON.stringify(serializeConfigForDisk(cfg), null, 2)}\n`);

  const ownership = await probePortOwnership(cfg);
  if (ownership.portState === 'occupied_by_other') {
    warnings.push(
      `Notice: configured port ${cfg.server.host}:${cfg.server.port} is currently occupied by another process (occupied_by_other). Choose a free port or stop the legacy bridge before starting.`
    );
  }

  return {
    configPath: targetConfigPath,
    tokenPath: targetTokenPath,
    stateDir: targetStateDir,
    dbPath: migratedDb ? targetDbPath : null,
    titleSummaryEnabled,
    warnings,
    portState: ownership.portState,
  };
}
