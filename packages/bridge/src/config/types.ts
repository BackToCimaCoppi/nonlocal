export type ListenWarningLevel = 'none' | 'lan_plaintext' | 'public_or_wildcard_plaintext';

export interface RateLimitConfig {
  maxFailures: number;
  windowMs: number;
  banMs: number;
  loopbackBackoffMs: number;
  maxTrackedIps: number;
}

export interface ServerConfig {
  host: string;
  port: number;
  allowNonLoopback: boolean;
  maxFrameBytes: number;
  pingIntervalMs: number;
  pongTimeoutMs: number;
}

export interface SecurityConfig {
  tokenFile: string;
  trustedProxies: string[];
  rateLimit: RateLimitConfig;
}

export interface AntigravityAdapterConfig {
  dataDirs: string[];
  disableDataDirs: boolean;
  usageTimeoutMs: number;
  usageCooldownMs: number;
}

export interface AdapterConfig {
  type: 'antigravity' | 'generic-acp';
  command: string;
  args: string[];
  defaultModel: string;
  defaultThoughtLevel: string;
  fallbackCwd: string;
  childIdleTimeoutMs: number;
  childStopGraceMs: number;
  antigravity: AntigravityAdapterConfig;
}

export type TitleLanguage = 'auto' | 'zh' | 'en';

export interface TitleSummaryConfig {
  enabled: boolean;
  endpoint: string;
  model: string;
  apiKeyFile: string;
  apiKey: string; // runtime-only from file or NONLOCAL_TITLE_SUMMARY_API_KEY
  language: TitleLanguage;
  timeoutMs: number;
}

export interface SyncConfig {
  maxEventsPerTurn: number;
  maxTurnBytes: number;
  watchIntervalMs: number;
  watchWindowMs: number;
  settleWindowMs: number;
  loadSettleQuietMs: number;
  loadSettleMaxWaitMs: number;
}

export interface StateConfig {
  dir: string;
  logFile: string;
  logMaxBytes: number;
  logMaxBackups: number;
}

export interface BridgeConfig {
  schemaVersion: 1;
  configPath: string;
  server: ServerConfig;
  security: SecurityConfig;
  adapter: AdapterConfig;
  titleSummary: TitleSummaryConfig;
  sync: SyncConfig;
  state: StateConfig;
}

export interface CliConfigOverrides {
  config?: string;
  host?: string;
  port?: number;
  allowNonLoopback?: boolean;
  tokenFile?: string;
  stateDir?: string;
  logFile?: string;
  adapter?: string;
  adapterCommand?: string;
  adapterArgs?: string;
  defaultModel?: string;
  defaultThoughtLevel?: string;
}
