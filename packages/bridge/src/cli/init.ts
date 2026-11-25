import { existsSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, resolve as resolvePath } from 'node:path';
import readline from 'node:readline/promises';
import { classifyListenWarning, getSecurityWarningText } from '../config/ip.js';
import {
  assertPrivateFileTarget,
  atomicWritePrivateFile,
  generateBearerToken,
  MIN_TOKEN_BYTES,
  readValidatedSecretFile,
} from '../config/secrets.js';
import {
  createDefaultConfig,
  serializeConfigForDisk,
  validateResolvedConfig,
} from '../config/schema.js';

function parseAdapterArgsFlag(raw: string): string[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error('Invalid --adapter-args: expected a JSON array of strings');
  }
  if (!Array.isArray(parsed) || parsed.some((item) => typeof item !== 'string')) {
    throw new Error('Invalid --adapter-args: expected a JSON array of strings');
  }
  return parsed as string[];
}
import { expandHome, resolveDefaultConfigPath } from '../config/paths.js';
import type { TitleLanguage } from '../config/types.js';
import { probePortOwnership } from '../service/runtime.js';
import { runImportLegacy } from './import-legacy.js';

export interface InitCliOptions {
  yes?: boolean;
  force?: boolean;
  importLegacy?: boolean;
  legacyConfigDir?: string;
  legacyStateDir?: string;
  config?: string;
  host?: string;
  port?: number;
  allowNonLoopback?: boolean;
  adapter?: string;
  adapterCommand?: string;
  adapterArgs?: string;
  defaultModel?: string;
  defaultThoughtLevel?: string;
  titleLanguage?: TitleLanguage;
  stateDir?: string;
  tokenFile?: string;
}

export async function handleInitCommand(
  opts: InitCliOptions,
  env: NodeJS.ProcessEnv = process.env,
  homeDir: string = homedir()
): Promise<number> {
  try {
    if (opts.importLegacy) {
      const imported = await runImportLegacy({
        homeDir,
        env,
        legacyConfigDir: opts.legacyConfigDir,
        legacyStateDir: opts.legacyStateDir,
        configPath: opts.config,
        stateDir: opts.stateDir,
        tokenFile: opts.tokenFile,
        host: opts.host,
        port: opts.port,
        allowNonLoopback: opts.allowNonLoopback,
        titleLanguage: opts.titleLanguage,
        force: opts.force,
      });
      console.log(`Imported legacy configuration into: ${imported.configPath}`);
      console.log(`Bearer token copied to: ${imported.tokenPath} (0600, value redacted)`);
      if (imported.dbPath) console.log(`Database migrated via VACUUM INTO: ${imported.dbPath}`);
      for (const w of imported.warnings) console.warn(w);
      return 0;
    }

    const cfg = createDefaultConfig(env, homeDir);
    if (opts.config) {
      cfg.configPath = resolvePath(expandHome(opts.config, homeDir));
    } else {
      cfg.configPath = resolveDefaultConfigPath(env, homeDir);
    }

    const useInteractive = !opts.yes && Boolean(process.stdin.isTTY && process.stdout.isTTY);
    if (useInteractive) {
      const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
      try {
        const ansAdapter = (await rl.question(`Adapter type [antigravity/generic-acp] (${cfg.adapter.type}): `)).trim();
        if (ansAdapter === 'antigravity' || ansAdapter === 'generic-acp') {
          opts.adapter = ansAdapter;
        }
        const ansHost = (await rl.question(`Listen host IP (${cfg.server.host}): `)).trim();
        if (ansHost) opts.host = ansHost;
        const ansPort = (await rl.question(`Listen port (${cfg.server.port}): `)).trim();
        if (ansPort) opts.port = Number(ansPort);
      } finally {
        rl.close();
      }
    }

    if (opts.host !== undefined) cfg.server.host = String(opts.host).trim();
    if (opts.port !== undefined) cfg.server.port = Number(opts.port);
    if (opts.allowNonLoopback) cfg.server.allowNonLoopback = true;
    if (opts.adapter) {
      if (opts.adapter !== 'antigravity' && opts.adapter !== 'generic-acp') {
        throw new Error(`Invalid adapter "${opts.adapter}": expected antigravity|generic-acp`);
      }
      cfg.adapter.type = opts.adapter;
      if (opts.adapter === 'generic-acp' && !opts.adapterCommand) {
        cfg.adapter.command = '';
        cfg.adapter.args = [];
      }
    }
    if (opts.adapterCommand !== undefined) cfg.adapter.command = opts.adapterCommand.trim();
    if (opts.adapterArgs !== undefined) cfg.adapter.args = parseAdapterArgsFlag(opts.adapterArgs);
    if (opts.defaultModel !== undefined) cfg.adapter.defaultModel = opts.defaultModel.trim();
    if (opts.defaultThoughtLevel !== undefined) cfg.adapter.defaultThoughtLevel = opts.defaultThoughtLevel.trim();
    if (opts.titleLanguage) {
      if (opts.titleLanguage !== 'auto' && opts.titleLanguage !== 'zh' && opts.titleLanguage !== 'en') {
        throw new Error(`Invalid --title-language "${opts.titleLanguage}"`);
      }
      cfg.titleSummary.language = opts.titleLanguage;
    }
    if (opts.stateDir) {
      cfg.state.dir = resolvePath(expandHome(opts.stateDir, homeDir));
      cfg.state.logFile = resolvePath(cfg.state.dir, 'bridge.log');
    }
    if (opts.tokenFile) {
      cfg.security.tokenFile = resolvePath(expandHome(opts.tokenFile, homeDir));
    } else if (opts.config) {
      cfg.security.tokenFile = resolvePath(dirname(cfg.configPath), 'bearer.token');
    }

    validateResolvedConfig(cfg);

    if (!opts.force && (existsSync(cfg.configPath) || existsSync(cfg.security.tokenFile))) {
      throw new Error(
        `Target config/token already exists (${cfg.configPath}); re-run with --force to overwrite`
      );
    }

    assertPrivateFileTarget(cfg.configPath, 'config.json');
    assertPrivateFileTarget(cfg.security.tokenFile, 'security.tokenFile');
    mkdirSync(dirname(cfg.configPath), { recursive: true, mode: 0o700 });
    mkdirSync(cfg.state.dir, { recursive: true, mode: 0o700 });

    if (opts.force && existsSync(cfg.security.tokenFile)) {
      try {
        readValidatedSecretFile(cfg.security.tokenFile, 'security.tokenFile', MIN_TOKEN_BYTES);
      } catch {
        atomicWritePrivateFile(cfg.security.tokenFile, `${generateBearerToken()}\n`);
      }
    } else {
      atomicWritePrivateFile(cfg.security.tokenFile, `${generateBearerToken()}\n`);
    }

    atomicWritePrivateFile(cfg.configPath, `${JSON.stringify(serializeConfigForDisk(cfg), null, 2)}\n`);
    const ownership = await probePortOwnership(cfg);
    if (ownership.portState === 'occupied_by_other') {
      console.warn(
        `Warning: port ${cfg.server.host}:${cfg.server.port} is currently occupied by another process (occupied_by_other).`
      );
    }
    const secWarn = getSecurityWarningText(classifyListenWarning(cfg.server.host));
    if (secWarn) {
      console.warn(secWarn);
    }

    console.log(`Initialized Nonlocal config: ${cfg.configPath}`);
    console.log(`Bearer token saved (0600, redacted): ${cfg.security.tokenFile}`);
    console.log('Run "nonlocal-bridge token show --reveal" if you need to view the Bearer token.');
    return 0;
  } catch (err) {
    console.error(`init failed: ${err instanceof Error ? err.message : String(err)}`);
    return 1;
  }
}
