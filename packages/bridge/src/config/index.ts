import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve as resolvePath } from 'node:path';
import { expandHome, resolveDefaultConfigPath } from './paths.js';
import {
  applyRawJsonToConfig,
  createDefaultConfig,
  serializeConfigForDisk,
  validateRawConfigJson,
  validateResolvedConfig,
} from './schema.js';
import { assertPrivateFileTarget, readValidatedSecretFile } from './secrets.js';
import type { BridgeConfig, CliConfigOverrides } from './types.js';

export * from './types.js';
export * from './ip.js';
export * from './paths.js';
export * from './secrets.js';
export {
  createDefaultConfig,
  serializeConfigForDisk,
  validateRawConfigJson,
  validateResolvedConfig,
};

function parseBoolFlag(raw: string): boolean {
  const norm = raw.trim().toLowerCase();
  if (norm === '1' || norm === 'true' || norm === 'yes' || norm === 'on') return true;
  if (norm === '0' || norm === 'false' || norm === 'no' || norm === 'off') return false;
  throw new Error(`Invalid boolean value "${raw}"`);
}

export interface LoadConfigOptions {
  overrides?: CliConfigOverrides;
  env?: NodeJS.ProcessEnv;
  homeDir?: string;
  requireConfigFile?: boolean;
}

export function loadConfig(opts: LoadConfigOptions = {}): BridgeConfig {
  const env = opts.env ?? process.env;
  const homeDir = opts.homeDir ?? homedir();
  const overrides = opts.overrides ?? {};

  const envConfigPath = typeof env.NONLOCAL_CONFIG === 'string' && env.NONLOCAL_CONFIG.trim()
    ? resolvePath(expandHome(env.NONLOCAL_CONFIG, homeDir))
    : undefined;
  const cliConfigPath = typeof overrides.config === 'string' && overrides.config.trim()
    ? resolvePath(expandHome(overrides.config, homeDir))
    : undefined;
  const configPath = cliConfigPath || envConfigPath || resolveDefaultConfigPath(env, homeDir);

  let cfg = createDefaultConfig(env, homeDir);
  cfg.configPath = configPath;

  const hasExplicitConfig = Boolean(cliConfigPath || envConfigPath);
  if (existsSync(configPath)) {
    const rawText = readFileSync(configPath, 'utf8');
    let parsed: unknown;
    try {
      parsed = JSON.parse(rawText);
    } catch (err) {
      throw new Error(`Invalid JSON in ${configPath}: ${err instanceof Error ? err.message : String(err)}`);
    }
    const validatedRaw = validateRawConfigJson(parsed);
    cfg = applyRawJsonToConfig(cfg, validatedRaw, homeDir);
    cfg.configPath = configPath;
  } else if (opts.requireConfigFile || hasExplicitConfig) {
    throw new Error(`Configuration file not found: ${configPath}. Run "nonlocal-bridge init" first.`);
  }

  // Apply whitelisted NONLOCAL_* environment variables (ignoring all legacy AGY_ACP_*).
  const envHost = env.NONLOCAL_HOST?.trim();
  if (envHost) cfg.server.host = envHost;

  if (env.NONLOCAL_PORT !== undefined && env.NONLOCAL_PORT.trim() !== '') {
    const portNum = Number(env.NONLOCAL_PORT);
    if (!Number.isInteger(portNum) || portNum < 0 || portNum > 65535) {
      throw new Error(`Invalid NONLOCAL_PORT "${env.NONLOCAL_PORT}"`);
    }
    cfg.server.port = portNum;
  }

  if (env.NONLOCAL_ALLOW_NON_LOOPBACK !== undefined && env.NONLOCAL_ALLOW_NON_LOOPBACK.trim() !== '') {
    cfg.server.allowNonLoopback = parseBoolFlag(env.NONLOCAL_ALLOW_NON_LOOPBACK);
  }

  if (env.NONLOCAL_TOKEN_FILE !== undefined && env.NONLOCAL_TOKEN_FILE.trim() !== '') {
    cfg.security.tokenFile = resolvePath(expandHome(env.NONLOCAL_TOKEN_FILE, homeDir));
  }

  let stateDirOverridden = false;
  if (env.NONLOCAL_STATE_DIR !== undefined && env.NONLOCAL_STATE_DIR.trim() !== '') {
    cfg.state.dir = resolvePath(expandHome(env.NONLOCAL_STATE_DIR, homeDir));
    cfg.state.logFile = join(cfg.state.dir, 'bridge.log');
    stateDirOverridden = true;
  }

  if (env.NONLOCAL_LOG_FILE !== undefined && env.NONLOCAL_LOG_FILE.trim() !== '') {
    cfg.state.logFile = resolvePath(expandHome(env.NONLOCAL_LOG_FILE, homeDir));
  } else if (stateDirOverridden) {
    cfg.state.logFile = join(cfg.state.dir, 'bridge.log');
  }

  if (env.NONLOCAL_ADAPTER_TYPE !== undefined && env.NONLOCAL_ADAPTER_TYPE.trim() !== '') {
    const t = env.NONLOCAL_ADAPTER_TYPE.trim();
    if (t !== 'antigravity' && t !== 'generic-acp') {
      throw new Error(`Invalid NONLOCAL_ADAPTER_TYPE "${t}"`);
    }
    if (t !== cfg.adapter.type) {
      cfg.adapter.type = t;
      if (t === 'generic-acp') {
        cfg.adapter.command = '';
        cfg.adapter.args = [];
      } else {
        cfg.adapter.command = 'agy';
        cfg.adapter.args = ['acp'];
      }
    }
  }

  if (env.NONLOCAL_ADAPTER_COMMAND !== undefined && env.NONLOCAL_ADAPTER_COMMAND.trim() !== '') {
    cfg.adapter.command = env.NONLOCAL_ADAPTER_COMMAND.trim();
  }

  if (env.NONLOCAL_ADAPTER_ARGS !== undefined && env.NONLOCAL_ADAPTER_ARGS.trim() !== '') {
    let parsedArgs: unknown;
    try {
      parsedArgs = JSON.parse(env.NONLOCAL_ADAPTER_ARGS);
    } catch {
      throw new Error(`Invalid NONLOCAL_ADAPTER_ARGS: must be a JSON string array`);
    }
    if (!Array.isArray(parsedArgs) || parsedArgs.some((x) => typeof x !== 'string')) {
      throw new Error(`Invalid NONLOCAL_ADAPTER_ARGS: must be a JSON string array`);
    }
    cfg.adapter.args = parsedArgs;
  }

  if (env.NONLOCAL_DEFAULT_MODEL !== undefined) {
    cfg.adapter.defaultModel = env.NONLOCAL_DEFAULT_MODEL.trim();
  }
  if (env.NONLOCAL_DEFAULT_THOUGHT_LEVEL !== undefined) {
    cfg.adapter.defaultThoughtLevel = env.NONLOCAL_DEFAULT_THOUGHT_LEVEL.trim();
  }

  // Apply CLI overrides (highest priority).
  if (overrides.host !== undefined) cfg.server.host = overrides.host.trim();
  if (overrides.port !== undefined) cfg.server.port = overrides.port;
  if (overrides.allowNonLoopback !== undefined) cfg.server.allowNonLoopback = overrides.allowNonLoopback;
  if (overrides.tokenFile !== undefined) {
    cfg.security.tokenFile = resolvePath(expandHome(overrides.tokenFile, homeDir));
  }
  if (overrides.stateDir !== undefined) {
    cfg.state.dir = resolvePath(expandHome(overrides.stateDir, homeDir));
    if (overrides.logFile === undefined && !(env.NONLOCAL_LOG_FILE?.trim())) {
      cfg.state.logFile = join(cfg.state.dir, 'bridge.log');
    }
  }
  if (overrides.logFile !== undefined) {
    cfg.state.logFile = resolvePath(expandHome(overrides.logFile, homeDir));
  }
  if (overrides.adapter !== undefined) {
    const t = overrides.adapter.trim();
    if (t !== 'antigravity' && t !== 'generic-acp') {
      throw new Error(`Invalid --adapter "${t}"`);
    }
    if (t !== cfg.adapter.type) {
      cfg.adapter.type = t;
      if (t === 'generic-acp') {
        cfg.adapter.command = '';
        cfg.adapter.args = [];
      } else {
        cfg.adapter.command = 'agy';
        cfg.adapter.args = ['acp'];
      }
    }
  }
  if (overrides.adapterCommand !== undefined) {
    cfg.adapter.command = overrides.adapterCommand.trim();
  }
  if (overrides.adapterArgs !== undefined) {
    let parsedArgs: unknown;
    try {
      parsedArgs = JSON.parse(overrides.adapterArgs);
    } catch {
      throw new Error(`Invalid --adapter-args: must be a JSON string array`);
    }
    if (!Array.isArray(parsedArgs) || parsedArgs.some((x) => typeof x !== 'string')) {
      throw new Error(`Invalid --adapter-args: must be a JSON string array`);
    }
    cfg.adapter.args = parsedArgs;
  }
  if (overrides.defaultModel !== undefined) {
    cfg.adapter.defaultModel = overrides.defaultModel.trim();
  }
  if (overrides.defaultThoughtLevel !== undefined) {
    cfg.adapter.defaultThoughtLevel = overrides.defaultThoughtLevel.trim();
  }

  // Runtime-only API key resolution (NONLOCAL_TITLE_SUMMARY_API_KEY > titleSummary.apiKeyFile).
  const envApiKey = env.NONLOCAL_TITLE_SUMMARY_API_KEY?.trim();
  if (envApiKey) {
    cfg.titleSummary.apiKey = envApiKey;
  } else if (cfg.titleSummary.apiKeyFile) {
    assertPrivateFileTarget(cfg.titleSummary.apiKeyFile, 'titleSummary.apiKeyFile');
    if (existsSync(cfg.titleSummary.apiKeyFile)) {
      cfg.titleSummary.apiKey = readValidatedSecretFile(cfg.titleSummary.apiKeyFile, 'titleSummary.apiKeyFile', 1).value;
    } else if (cfg.titleSummary.enabled) {
      throw new Error(`titleSummary.apiKeyFile does not exist: ${cfg.titleSummary.apiKeyFile}`);
    }
  }

  validateResolvedConfig(cfg);
  return cfg;
}
