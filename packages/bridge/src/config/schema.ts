import { homedir } from 'node:os';
import { join, resolve as resolvePath } from 'node:path';
import { isValidIpLiteral, parseTrustedProxyEntry } from './ip.js';
import {
  expandHome,
  resolveDefaultConfigPath,
  resolveDefaultStateDir,
  resolveDefaultTokenPath,
} from './paths.js';
import type { BridgeConfig, TitleLanguage } from './types.js';

const FORBIDDEN_SECRET_KEYS = new Set([
  'token',
  'bearertoken',
  'apikey',
  'key',
  'secret',
  'password',
]);

const ALLOWED_TOP_KEYS = new Set([
  'schemaVersion',
  'server',
  'security',
  'adapter',
  'titleSummary',
  'sync',
  'state',
]);

const ALLOWED_SERVER_KEYS = new Set([
  'host',
  'port',
  'allowNonLoopback',
  'maxFrameBytes',
  'pingIntervalMs',
  'pongTimeoutMs',
]);

const ALLOWED_SECURITY_KEYS = new Set([
  'tokenFile',
  'trustedProxies',
  'rateLimit',
]);

const ALLOWED_RATE_LIMIT_KEYS = new Set([
  'maxFailures',
  'windowMs',
  'banMs',
  'loopbackBackoffMs',
  'maxTrackedIps',
]);

const ALLOWED_ADAPTER_KEYS = new Set([
  'type',
  'command',
  'args',
  'defaultModel',
  'defaultThoughtLevel',
  'fallbackCwd',
  'childIdleTimeoutMs',
  'childStopGraceMs',
  'antigravity',
]);

const ALLOWED_ANTIGRAVITY_KEYS = new Set([
  'dataDirs',
  'disableDataDirs',
  'usageTimeoutMs',
  'usageCooldownMs',
]);

const ALLOWED_TITLE_SUMMARY_KEYS = new Set([
  'enabled',
  'endpoint',
  'model',
  'apiKeyFile',
  'language',
  'timeoutMs',
]);

const ALLOWED_SYNC_KEYS = new Set([
  'maxEventsPerTurn',
  'maxTurnBytes',
  'watchIntervalMs',
  'watchWindowMs',
  'settleWindowMs',
  'loadSettleQuietMs',
  'loadSettleMaxWaitMs',
]);

const ALLOWED_STATE_KEYS = new Set([
  'dir',
  'logFile',
  'logMaxBytes',
  'logMaxBackups',
]);

export function createDefaultConfig(
  env: NodeJS.ProcessEnv = process.env,
  homeDir: string = homedir(),
  adapterType: 'antigravity' | 'generic-acp' = 'antigravity'
): BridgeConfig {
  const stateDir = resolveDefaultStateDir(env, homeDir);
  const tokenFile = resolveDefaultTokenPath(env, homeDir);
  const configPath = resolveDefaultConfigPath(env, homeDir);

  return {
    schemaVersion: 1,
    configPath,
    server: {
      host: '127.0.0.1',
      port: 8765,
      allowNonLoopback: false,
      maxFrameBytes: 16 * 1024 * 1024,
      pingIntervalMs: 25_000,
      pongTimeoutMs: 60_000,
    },
    security: {
      tokenFile,
      trustedProxies: [],
      rateLimit: {
        maxFailures: 10,
        windowMs: 600_000,
        banMs: 300_000,
        loopbackBackoffMs: 200,
        maxTrackedIps: 4096,
      },
    },
    adapter: {
      type: adapterType,
      command: adapterType === 'antigravity' ? 'agy' : '',
      args: adapterType === 'antigravity' ? ['acp'] : [],
      defaultModel: '',
      defaultThoughtLevel: '',
      fallbackCwd: '/tmp',
      childIdleTimeoutMs: 86_400_000,
      childStopGraceMs: 3_000,
      antigravity: {
        dataDirs: [
          join(homeDir, '.gemini', 'antigravity-cli'),
          join(homeDir, '.gemini', 'antigravity'),
        ],
        disableDataDirs: false,
        usageTimeoutMs: 15_000,
        usageCooldownMs: 60_000,
      },
    },
    titleSummary: {
      enabled: false,
      endpoint: '',
      model: '',
      apiKeyFile: '',
      apiKey: '',
      language: 'auto',
      timeoutMs: 8_000,
    },
    sync: {
      maxEventsPerTurn: 2000,
      maxTurnBytes: 2 * 1024 * 1024,
      watchIntervalMs: 2500,
      watchWindowMs: 300_000,
      settleWindowMs: 60_000,
      loadSettleQuietMs: 60,
      loadSettleMaxWaitMs: 1000,
    },
    state: {
      dir: stateDir,
      logFile: join(stateDir, 'bridge.log'),
      logMaxBytes: 10 * 1024 * 1024,
      logMaxBackups: 3,
    },
  };
}

function assertPlainObject(val: unknown, pathLabel: string): Record<string, unknown> {
  if (!val || typeof val !== 'object' || Array.isArray(val)) {
    throw new Error(`${pathLabel} must be an object`);
  }
  return val as Record<string, unknown>;
}

function scanForPlaintextSecrets(obj: unknown, prefix: string): void {
  if (!obj || typeof obj !== 'object') return;
  if (Array.isArray(obj)) {
    for (let i = 0; i < obj.length; i++) {
      scanForPlaintextSecrets(obj[i], `${prefix}[${i}]`);
    }
    return;
  }
  for (const [k, v] of Object.entries(obj)) {
    const keyPath = prefix ? `${prefix}.${k}` : k;
    if (FORBIDDEN_SECRET_KEYS.has(k.toLowerCase())) {
      throw new Error(`Plaintext secret key "${keyPath}" is forbidden in config.json`);
    }
    scanForPlaintextSecrets(v, keyPath);
  }
}

function assertAllowedKeys(obj: Record<string, unknown>, allowed: Set<string>, prefix: string): void {
  for (const key of Object.keys(obj)) {
    const keyPath = prefix ? `${prefix}.${key}` : key;
    if (!allowed.has(key)) {
      if (keyPath === 'security.allowExternalSessions') {
        throw new Error(`Removed configuration key "${keyPath}" is not supported`);
      }
      throw new Error(`Unknown configuration key "${keyPath}"`);
    }
  }
}

export function validateRawConfigJson(raw: unknown): Record<string, unknown> {
  const root = assertPlainObject(raw, 'config.json');
  scanForPlaintextSecrets(root, '');
  assertAllowedKeys(root, ALLOWED_TOP_KEYS, '');

  if (root.schemaVersion !== 1) {
    throw new Error(`Invalid schemaVersion "${String(root.schemaVersion)}": expected 1`);
  }

  if (root.server !== undefined) {
    assertAllowedKeys(assertPlainObject(root.server, 'server'), ALLOWED_SERVER_KEYS, 'server');
  }
  if (root.security !== undefined) {
    const sec = assertPlainObject(root.security, 'security');
    assertAllowedKeys(sec, ALLOWED_SECURITY_KEYS, 'security');
    if (sec.rateLimit !== undefined) {
      assertAllowedKeys(assertPlainObject(sec.rateLimit, 'security.rateLimit'), ALLOWED_RATE_LIMIT_KEYS, 'security.rateLimit');
    }
  }
  if (root.adapter !== undefined) {
    const adp = assertPlainObject(root.adapter, 'adapter');
    assertAllowedKeys(adp, ALLOWED_ADAPTER_KEYS, 'adapter');
    if (adp.antigravity !== undefined) {
      assertAllowedKeys(
        assertPlainObject(adp.antigravity, 'adapter.antigravity'),
        ALLOWED_ANTIGRAVITY_KEYS,
        'adapter.antigravity'
      );
    }
  }
  if (root.titleSummary !== undefined) {
    assertAllowedKeys(
      assertPlainObject(root.titleSummary, 'titleSummary'),
      ALLOWED_TITLE_SUMMARY_KEYS,
      'titleSummary'
    );
  }
  if (root.sync !== undefined) {
    assertAllowedKeys(assertPlainObject(root.sync, 'sync'), ALLOWED_SYNC_KEYS, 'sync');
  }
  if (root.state !== undefined) {
    assertAllowedKeys(assertPlainObject(root.state, 'state'), ALLOWED_STATE_KEYS, 'state');
  }

  return root;
}

function asInteger(val: unknown, name: string, min: number, max: number = Number.MAX_SAFE_INTEGER): number {
  if (typeof val !== 'number' || !Number.isInteger(val) || val < min || val > max) {
    throw new Error(`Invalid ${name}: expected integer in [${min}, ${max}]`);
  }
  return val;
}

function asBoolean(val: unknown, name: string): boolean {
  if (typeof val !== 'boolean') {
    throw new Error(`Invalid ${name}: expected boolean`);
  }
  return val;
}

function asString(val: unknown, name: string): string {
  if (typeof val !== 'string') {
    throw new Error(`Invalid ${name}: expected string`);
  }
  return val;
}

function asStringArray(val: unknown, name: string): string[] {
  if (!Array.isArray(val) || val.some((item) => typeof item !== 'string')) {
    throw new Error(`Invalid ${name}: expected string[]`);
  }
  return [...val];
}

export function applyRawJsonToConfig(
  base: BridgeConfig,
  raw: Record<string, unknown>,
  homeDir: string = homedir()
): BridgeConfig {
  const next: BridgeConfig = structuredClone(base);

  if (raw.server && typeof raw.server === 'object') {
    const s = raw.server as Record<string, unknown>;
    if (s.host !== undefined) next.server.host = asString(s.host, 'server.host').trim();
    if (s.port !== undefined) next.server.port = asInteger(s.port, 'server.port', 0, 65535);
    if (s.allowNonLoopback !== undefined) next.server.allowNonLoopback = asBoolean(s.allowNonLoopback, 'server.allowNonLoopback');
    if (s.maxFrameBytes !== undefined) next.server.maxFrameBytes = asInteger(s.maxFrameBytes, 'server.maxFrameBytes', 1024);
    if (s.pingIntervalMs !== undefined) next.server.pingIntervalMs = asInteger(s.pingIntervalMs, 'server.pingIntervalMs', 0);
    if (s.pongTimeoutMs !== undefined) next.server.pongTimeoutMs = asInteger(s.pongTimeoutMs, 'server.pongTimeoutMs', 100);
  }

  if (raw.security && typeof raw.security === 'object') {
    const sec = raw.security as Record<string, unknown>;
    if (sec.tokenFile !== undefined) {
      next.security.tokenFile = resolvePath(expandHome(asString(sec.tokenFile, 'security.tokenFile'), homeDir));
    }
    if (sec.trustedProxies !== undefined) {
      next.security.trustedProxies = asStringArray(sec.trustedProxies, 'security.trustedProxies');
    }
    if (sec.rateLimit && typeof sec.rateLimit === 'object') {
      const rl = sec.rateLimit as Record<string, unknown>;
      if (rl.maxFailures !== undefined) next.security.rateLimit.maxFailures = asInteger(rl.maxFailures, 'security.rateLimit.maxFailures', 1);
      if (rl.windowMs !== undefined) next.security.rateLimit.windowMs = asInteger(rl.windowMs, 'security.rateLimit.windowMs', 10);
      if (rl.banMs !== undefined) next.security.rateLimit.banMs = asInteger(rl.banMs, 'security.rateLimit.banMs', 10);
      if (rl.loopbackBackoffMs !== undefined) {
        next.security.rateLimit.loopbackBackoffMs = asInteger(rl.loopbackBackoffMs, 'security.rateLimit.loopbackBackoffMs', 0, 5000);
      }
      if (rl.maxTrackedIps !== undefined) next.security.rateLimit.maxTrackedIps = asInteger(rl.maxTrackedIps, 'security.rateLimit.maxTrackedIps', 1);
    }
  }

  if (raw.adapter && typeof raw.adapter === 'object') {
    const adp = raw.adapter as Record<string, unknown>;
    if (adp.type !== undefined) {
      if (adp.type !== 'antigravity' && adp.type !== 'generic-acp') {
        throw new Error(`Invalid adapter.type "${String(adp.type)}"`);
      }
      next.adapter.type = adp.type;
      if (adp.type === 'generic-acp') {
        if (adp.command === undefined) next.adapter.command = '';
        if (adp.args === undefined) next.adapter.args = [];
      }
    }
    if (adp.command !== undefined) next.adapter.command = asString(adp.command, 'adapter.command').trim();
    if (adp.args !== undefined) next.adapter.args = asStringArray(adp.args, 'adapter.args');
    if (adp.defaultModel !== undefined) next.adapter.defaultModel = asString(adp.defaultModel, 'adapter.defaultModel').trim();
    if (adp.defaultThoughtLevel !== undefined) next.adapter.defaultThoughtLevel = asString(adp.defaultThoughtLevel, 'adapter.defaultThoughtLevel').trim();
    if (adp.fallbackCwd !== undefined) next.adapter.fallbackCwd = resolvePath(expandHome(asString(adp.fallbackCwd, 'adapter.fallbackCwd'), homeDir));
    if (adp.childIdleTimeoutMs !== undefined) next.adapter.childIdleTimeoutMs = asInteger(adp.childIdleTimeoutMs, 'adapter.childIdleTimeoutMs', 0);
    if (adp.childStopGraceMs !== undefined) next.adapter.childStopGraceMs = asInteger(adp.childStopGraceMs, 'adapter.childStopGraceMs', 50);

    if (adp.antigravity && typeof adp.antigravity === 'object') {
      const ag = adp.antigravity as Record<string, unknown>;
      if (ag.dataDirs !== undefined) {
        next.adapter.antigravity.dataDirs = asStringArray(ag.dataDirs, 'adapter.antigravity.dataDirs')
          .map((d) => resolvePath(expandHome(d, homeDir)));
      }
      if (ag.disableDataDirs !== undefined) next.adapter.antigravity.disableDataDirs = asBoolean(ag.disableDataDirs, 'adapter.antigravity.disableDataDirs');
      if (ag.usageTimeoutMs !== undefined) next.adapter.antigravity.usageTimeoutMs = asInteger(ag.usageTimeoutMs, 'adapter.antigravity.usageTimeoutMs', 50);
      if (ag.usageCooldownMs !== undefined) next.adapter.antigravity.usageCooldownMs = asInteger(ag.usageCooldownMs, 'adapter.antigravity.usageCooldownMs', 0);
    }
  }

  if (raw.titleSummary && typeof raw.titleSummary === 'object') {
    const ts = raw.titleSummary as Record<string, unknown>;
    if (ts.enabled !== undefined) next.titleSummary.enabled = asBoolean(ts.enabled, 'titleSummary.enabled');
    if (ts.endpoint !== undefined) next.titleSummary.endpoint = asString(ts.endpoint, 'titleSummary.endpoint').trim();
    if (ts.model !== undefined) next.titleSummary.model = asString(ts.model, 'titleSummary.model').trim();
    if (ts.apiKeyFile !== undefined) {
      const rawKeyFile = asString(ts.apiKeyFile, 'titleSummary.apiKeyFile').trim();
      next.titleSummary.apiKeyFile = rawKeyFile ? resolvePath(expandHome(rawKeyFile, homeDir)) : '';
    }
    if (ts.language !== undefined) {
      if (ts.language !== 'auto' && ts.language !== 'zh' && ts.language !== 'en') {
        throw new Error(`Invalid titleSummary.language "${String(ts.language)}": must be auto|zh|en`);
      }
      next.titleSummary.language = ts.language as TitleLanguage;
    }
    if (ts.timeoutMs !== undefined) next.titleSummary.timeoutMs = asInteger(ts.timeoutMs, 'titleSummary.timeoutMs', 50);
  }

  if (raw.sync && typeof raw.sync === 'object') {
    const sy = raw.sync as Record<string, unknown>;
    if (sy.maxEventsPerTurn !== undefined) next.sync.maxEventsPerTurn = asInteger(sy.maxEventsPerTurn, 'sync.maxEventsPerTurn', 1);
    if (sy.maxTurnBytes !== undefined) next.sync.maxTurnBytes = asInteger(sy.maxTurnBytes, 'sync.maxTurnBytes', 128);
    if (sy.watchIntervalMs !== undefined) next.sync.watchIntervalMs = asInteger(sy.watchIntervalMs, 'sync.watchIntervalMs', 20);
    if (sy.watchWindowMs !== undefined) next.sync.watchWindowMs = asInteger(sy.watchWindowMs, 'sync.watchWindowMs', 50);
    if (sy.settleWindowMs !== undefined) next.sync.settleWindowMs = asInteger(sy.settleWindowMs, 'sync.settleWindowMs', 50);
    if (sy.loadSettleQuietMs !== undefined) next.sync.loadSettleQuietMs = asInteger(sy.loadSettleQuietMs, 'sync.loadSettleQuietMs', 0);
    if (sy.loadSettleMaxWaitMs !== undefined) next.sync.loadSettleMaxWaitMs = asInteger(sy.loadSettleMaxWaitMs, 'sync.loadSettleMaxWaitMs', 0);
  }

  if (raw.state && typeof raw.state === 'object') {
    const st = raw.state as Record<string, unknown>;
    if (st.dir !== undefined) {
      next.state.dir = resolvePath(expandHome(asString(st.dir, 'state.dir'), homeDir));
      if (st.logFile === undefined) {
        next.state.logFile = join(next.state.dir, 'bridge.log');
      }
    }
    if (st.logFile !== undefined) {
      next.state.logFile = resolvePath(expandHome(asString(st.logFile, 'state.logFile'), homeDir));
    }
    if (st.logMaxBytes !== undefined) next.state.logMaxBytes = asInteger(st.logMaxBytes, 'state.logMaxBytes', 256);
    if (st.logMaxBackups !== undefined) next.state.logMaxBackups = asInteger(st.logMaxBackups, 'state.logMaxBackups', 0);
  }

  return next;
}

export function validateResolvedConfig(cfg: BridgeConfig): void {
  if (cfg.schemaVersion !== 1) {
    throw new Error(`Invalid schemaVersion "${cfg.schemaVersion}": expected 1`);
  }
  if (!isValidIpLiteral(cfg.server.host)) {
    throw new Error(
      `Invalid server.host "${cfg.server.host}": only valid IPv4/IPv6 literals are allowed (hostnames such as "localhost" are forbidden; use 127.0.0.1 or ::1)`
    );
  }
  if (!Number.isInteger(cfg.server.port) || cfg.server.port < 0 || cfg.server.port > 65535) {
    throw new Error(`Invalid server.port "${cfg.server.port}": must be integer 0..65535`);
  }
  if (cfg.security.rateLimit.loopbackBackoffMs < 0 || cfg.security.rateLimit.loopbackBackoffMs > 5000) {
    throw new Error(`Invalid security.rateLimit.loopbackBackoffMs "${cfg.security.rateLimit.loopbackBackoffMs}": must be 0..5000`);
  }
  for (const proxy of cfg.security.trustedProxies) {
    parseTrustedProxyEntry(proxy);
  }

  if (cfg.adapter.type === 'generic-acp' && !cfg.adapter.command.trim()) {
    throw new Error('adapter.command is required when adapter.type is "generic-acp"');
  }
  if (cfg.adapter.type === 'antigravity' && !cfg.adapter.command.trim()) {
    throw new Error('adapter.command cannot be empty');
  }

  if (!cfg.adapter.defaultModel.trim() && cfg.adapter.defaultThoughtLevel.trim()) {
    throw new Error('Invalid adapter configuration: defaultThoughtLevel requires a non-empty defaultModel');
  }

  if (cfg.titleSummary.enabled) {
    if (!cfg.titleSummary.endpoint) {
      throw new Error('titleSummary.endpoint is required when titleSummary.enabled is true');
    }
    let parsedUrl: URL;
    try {
      parsedUrl = new URL(cfg.titleSummary.endpoint);
    } catch {
      throw new Error(`Invalid titleSummary.endpoint "${cfg.titleSummary.endpoint}"`);
    }
    if (parsedUrl.protocol !== 'http:' && parsedUrl.protocol !== 'https:') {
      throw new Error(`Invalid titleSummary.endpoint protocol "${parsedUrl.protocol}": only http/https allowed`);
    }
    if (!cfg.titleSummary.model.trim()) {
      throw new Error('titleSummary.model is required when titleSummary.enabled is true');
    }
    if (cfg.titleSummary.language !== 'auto' && cfg.titleSummary.language !== 'zh' && cfg.titleSummary.language !== 'en') {
      throw new Error(`Invalid titleSummary.language "${cfg.titleSummary.language}"`);
    }
  }
}

export function serializeConfigForDisk(cfg: BridgeConfig): Record<string, unknown> {
  return {
    schemaVersion: 1,
    server: {
      host: cfg.server.host,
      port: cfg.server.port,
      allowNonLoopback: cfg.server.allowNonLoopback,
      maxFrameBytes: cfg.server.maxFrameBytes,
      pingIntervalMs: cfg.server.pingIntervalMs,
      pongTimeoutMs: cfg.server.pongTimeoutMs,
    },
    security: {
      tokenFile: cfg.security.tokenFile,
      trustedProxies: cfg.security.trustedProxies,
      rateLimit: { ...cfg.security.rateLimit },
    },
    adapter: {
      type: cfg.adapter.type,
      command: cfg.adapter.command,
      args: cfg.adapter.args,
      defaultModel: cfg.adapter.defaultModel,
      defaultThoughtLevel: cfg.adapter.defaultThoughtLevel,
      fallbackCwd: cfg.adapter.fallbackCwd,
      childIdleTimeoutMs: cfg.adapter.childIdleTimeoutMs,
      childStopGraceMs: cfg.adapter.childStopGraceMs,
      antigravity: {
        dataDirs: cfg.adapter.antigravity.dataDirs,
        disableDataDirs: cfg.adapter.antigravity.disableDataDirs,
        usageTimeoutMs: cfg.adapter.antigravity.usageTimeoutMs,
        usageCooldownMs: cfg.adapter.antigravity.usageCooldownMs,
      },
    },
    titleSummary: {
      enabled: cfg.titleSummary.enabled,
      endpoint: cfg.titleSummary.endpoint,
      model: cfg.titleSummary.model,
      apiKeyFile: cfg.titleSummary.apiKeyFile,
      language: cfg.titleSummary.language,
      timeoutMs: cfg.titleSummary.timeoutMs,
    },
    sync: { ...cfg.sync },
    state: {
      dir: cfg.state.dir,
      logFile: cfg.state.logFile,
      logMaxBytes: cfg.state.logMaxBytes,
      logMaxBackups: cfg.state.logMaxBackups,
    },
  };
}
