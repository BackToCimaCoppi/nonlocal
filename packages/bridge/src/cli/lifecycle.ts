import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { AntigravityAdapter } from '../adapter/antigravity-adapter.js';
import { BaseAcpAdapter } from '../adapter/base-acp-adapter.js';
import type { AgentAdapter } from '../adapter/types.js';
import { classifyListenWarning, getSecurityWarningText } from '../config/ip.js';
import { loadConfig } from '../config/index.js';
import { resolveDefaultConfigPath } from '../config/paths.js';
import { MIN_TOKEN_BYTES, readValidatedSecretFile } from '../config/secrets.js';
import type { BridgeConfig, CliConfigOverrides } from '../config/types.js';
import { NonlocalGateway } from '../gateway/gateway.js';
import { SanitizedLogger } from '../log/logger.js';
import { StateStore } from '../store/state-store.js';
import { WsServerTransport } from '../transport/ws-server-transport.js';
import {
  computeCommandFingerprint,
  getLaunchdServiceStatus,
  getSystemdServiceStatus,
  isPidAlive,
  matchesCommandFingerprint,
  probeLoopbackHealth,
  probePortOwnership,
  queryPlatformServiceStatus,
  removeRuntimeFile,
  writeRuntimeFile,
  type RuntimeMode,
} from '../service/index.js';

const CLI_ENTRY_SCRIPT = fileURLToPath(new URL('../cli.js', import.meta.url));

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function createAdapterFromConfig(config: BridgeConfig, logger: SanitizedLogger): AgentAdapter {
  if (config.adapter.type === 'antigravity') {
    return new AntigravityAdapter({ adapterConfig: config.adapter, syncConfig: config.sync, logger });
  }
  return new BaseAcpAdapter({ adapterConfig: config.adapter, syncConfig: config.sync, logger });
}

export function isForcedStandalone(overrides: CliConfigOverrides, standaloneFlag?: boolean): boolean {
  if (standaloneFlag) return true;
  if (overrides.config && overrides.config !== resolveDefaultConfigPath()) return true;
  if (overrides.host !== undefined || overrides.port !== undefined || overrides.allowNonLoopback !== undefined) {
    return true;
  }
  return false;
}

export async function runForegroundBridge(opts: {
  overrides: CliConfigOverrides;
  mode?: RuntimeMode;
}): Promise<number> {
  let config: BridgeConfig;
  let tokenValue: string;
  try {
    config = loadConfig({ overrides: opts.overrides, requireConfigFile: true });
    tokenValue = readValidatedSecretFile(config.security.tokenFile, 'security.tokenFile', MIN_TOKEN_BYTES).value;
  } catch (err) {
    console.error(`Failed loading configuration: ${err instanceof Error ? err.message : String(err)}`);
    return 1;
  }

  const ownership = await probePortOwnership(config);
  if (ownership.portState !== 'free') {
    console.error(
      `Cannot bind ${config.server.host}:${config.server.port} (portState=${ownership.portState}, reason=${ownership.reason})`
    );
    return 1;
  }

  mkdirSync(dirname(config.state.logFile), { recursive: true, mode: 0o700 });
  const logger = new SanitizedLogger({
    logFile: config.state.logFile,
    maxBytes: config.state.logMaxBytes,
    maxBackups: config.state.logMaxBackups,
    redactSecrets: [tokenValue, config.titleSummary.apiKey].filter(Boolean),
  });
  const store = new StateStore({ stateDir: config.state.dir });
  const adapter = createAdapterFromConfig(config, logger);

  let gwRef: NonlocalGateway | null = null;
  const transport = new WsServerTransport({
    host: config.server.host,
    port: config.server.port,
    allowNonLoopback: config.server.allowNonLoopback,
    expectedToken: tokenValue,
    maxFrameBytes: config.server.maxFrameBytes,
    pingIntervalMs: config.server.pingIntervalMs,
    pongTimeoutMs: config.server.pongTimeoutMs,
    trustedProxies: config.security.trustedProxies,
    rateLimit: config.security.rateLimit,
    getHealthState: () => gwRef?.getHealthState() ?? { childAlive: false, activeClient: false },
    logger,
  });

  const gateway = new NonlocalGateway({ config, transport, adapter, store, logger });
  gwRef = gateway;

  const bound = await gateway.start();
  const mode: RuntimeMode =
    opts.mode ||
    (process.env.NONLOCAL_SERVICE_MODE === 'launchd'
      ? 'launchd'
      : process.env.NONLOCAL_SERVICE_MODE === 'systemd'
        ? 'systemd'
        : 'standalone');

  writeRuntimeFile(config.state.dir, {
    pid: process.pid,
    mode,
    host: bound.host,
    port: bound.port,
    listenAddresses: bound.listenAddresses,
    configPath: config.configPath,
    startedAt: new Date().toISOString(),
    commandFingerprint: computeCommandFingerprint(CLI_ENTRY_SCRIPT),
  });

  const warnLevel = classifyListenWarning(bound.host);
  const warnText = getSecurityWarningText(warnLevel);
  if (warnText) {
    logger.log('warn', 'non_loopback_listening', {
      warningLevel: warnLevel,
      host: bound.host,
      port: bound.port,
      listenAddresses: bound.listenAddresses.map((a) => `${a.host}:${a.port}`),
    });
    console.warn(warnText);
  }

  logger.log('info', 'bridge_listening', {
    host: bound.host,
    port: bound.port,
    instanceId: gateway.getInstanceId(),
  });
  console.log(`LISTENING host=${bound.host} port=${bound.port} pid=${process.pid}`);

  return await new Promise<number>((resolve) => {
    let shuttingDown = false;
    const shutdown = async (signalName: string) => {
      if (shuttingDown) return;
      shuttingDown = true;
      removeRuntimeFile(config.state.dir, process.pid);
      try {
        await gateway.stop(signalName);
      } catch {
        // ignore
      }
      resolve(0);
    };
    process.once('SIGINT', () => void shutdown('SIGINT'));
    process.once('SIGTERM', () => void shutdown('SIGTERM'));
  });
}

export async function handleStartCommand(opts: {
  foreground?: boolean;
  standalone?: boolean;
  overrides: CliConfigOverrides;
}): Promise<number> {
  if (opts.foreground) {
    return runForegroundBridge({ overrides: opts.overrides });
  }

  let config: BridgeConfig;
  try {
    config = loadConfig({ overrides: opts.overrides, requireConfigFile: true });
    readValidatedSecretFile(config.security.tokenFile, 'security.tokenFile', MIN_TOKEN_BYTES);
  } catch (err) {
    console.error(`start failed: ${err instanceof Error ? err.message : String(err)}`);
    return 1;
  }

  const ownership = await probePortOwnership(config);
  if (ownership.portState === 'owned_running') {
    console.log(`Nonlocal bridge already running (pid=${ownership.runtime?.pid}, port=${config.server.port}).`);
    return 0;
  }
  if (ownership.portState === 'occupied_by_other') {
    console.error(`Refusing to start: port ${config.server.host}:${config.server.port} is occupied by another process.`);
    return 1;
  }

  const forcedStandalone = isForcedStandalone(opts.overrides, opts.standalone);
  if (!forcedStandalone) {
    if (process.platform === 'darwin' && getLaunchdServiceStatus().installed) {
      const uid = typeof process.getuid === 'function' ? process.getuid() : 0;
      try {
        execFileSync('launchctl', ['kickstart', '-k', `gui/${uid}/com.nonlocal.bridge`], { stdio: 'pipe', timeout: 8000 });
        for (let i = 0; i < 40; i++) {
          const h = await probeLoopbackHealth(config.server.host, config.server.port);
          if (h?.ok) return 0;
          await sleep(100);
        }
      } catch {
        return 1;
      }
    } else if (process.platform === 'linux' && getSystemdServiceStatus().installed) {
      try {
        execFileSync('systemctl', ['--user', 'start', 'nonlocal-bridge.service'], { stdio: 'pipe', timeout: 8000 });
        for (let i = 0; i < 40; i++) {
          const h = await probeLoopbackHealth(config.server.host, config.server.port);
          if (h?.ok) return 0;
          await sleep(100);
        }
      } catch {
        return 1;
      }
    }
  }

  const args = [CLI_ENTRY_SCRIPT, 'start', '--foreground', '--config', config.configPath];
  if (opts.overrides.host !== undefined) args.push('--host', opts.overrides.host);
  if (opts.overrides.port !== undefined) args.push('--port', String(opts.overrides.port));
  if (opts.overrides.allowNonLoopback) args.push('--allow-non-loopback');
  if (opts.overrides.tokenFile !== undefined) args.push('--token-file', opts.overrides.tokenFile);
  if (opts.overrides.stateDir !== undefined) args.push('--state-dir', opts.overrides.stateDir);
  if (opts.overrides.logFile !== undefined) args.push('--log-file', opts.overrides.logFile);
  if (opts.overrides.adapter !== undefined) args.push('--adapter', opts.overrides.adapter);
  if (opts.overrides.adapterCommand !== undefined) args.push('--adapter-command', opts.overrides.adapterCommand);
  if (opts.overrides.adapterArgs !== undefined) args.push('--adapter-args', opts.overrides.adapterArgs);
  if (opts.overrides.defaultModel !== undefined) args.push('--default-model', opts.overrides.defaultModel);
  if (opts.overrides.defaultThoughtLevel !== undefined) {
    args.push('--default-thought-level', opts.overrides.defaultThoughtLevel);
  }

  const child = spawn(process.execPath, args, {
    detached: true,
    stdio: 'ignore',
    env: { ...process.env, NONLOCAL_SERVICE_MODE: 'standalone' },
  });
  child.unref();

  for (let i = 0; i < 60; i++) {
    if (!isPidAlive(child.pid ?? 0)) {
      console.error('Bridge child exited before becoming ready; check bridge.log');
      return 1;
    }
    const post = await probePortOwnership(config);
    if (post.portState === 'owned_running' && post.health?.ok) {
      console.log(`Started Nonlocal bridge (pid=${post.runtime?.pid}, host=${post.runtime?.host}, port=${post.runtime?.port}).`);
      return 0;
    }
    await sleep(100);
  }

  try {
    if (child.pid) process.kill(child.pid, 'SIGTERM');
  } catch {
    // ignore
  }
  console.error('Timed out waiting for Nonlocal bridge /health readiness');
  return 1;
}

export async function handleStopCommand(opts: {
  standalone?: boolean;
  overrides: CliConfigOverrides;
}): Promise<number> {
  let config: BridgeConfig;
  try {
    config = loadConfig({ overrides: opts.overrides, requireConfigFile: true });
  } catch (err) {
    console.error(`stop failed: ${err instanceof Error ? err.message : String(err)}`);
    return 1;
  }

  const forcedStandalone = isForcedStandalone(opts.overrides, opts.standalone);
  if (!forcedStandalone) {
    if (process.platform === 'darwin' && getLaunchdServiceStatus().running) {
      const uid = typeof process.getuid === 'function' ? process.getuid() : 0;
      try {
        execFileSync('launchctl', ['kill', 'SIGTERM', `gui/${uid}/com.nonlocal.bridge`], { stdio: 'pipe' });
      } catch {
        // fallback below
      }
    } else if (process.platform === 'linux' && getSystemdServiceStatus().running) {
      try {
        execFileSync('systemctl', ['--user', 'stop', 'nonlocal-bridge.service'], { stdio: 'pipe' });
      } catch {
        // fallback below
      }
    }
  }

  const ownership = await probePortOwnership(config);
  if (ownership.portState === 'free') {
    removeRuntimeFile(config.state.dir);
    console.log('Nonlocal bridge is already stopped.');
    return 0;
  }
  if (ownership.portState === 'occupied_by_other' || !ownership.runtime) {
    console.error(`Refusing to stop: port ${config.server.port} is occupied by another process (pid mismatch or foreign process).`);
    return 1;
  }

  const targetPid = ownership.runtime.pid;
  if (!matchesCommandFingerprint(targetPid, ownership.runtime.commandFingerprint)) {
    console.error(`Refusing to signal pid=${targetPid}: command line fingerprint mismatch`);
    return 1;
  }

  try {
    process.kill(targetPid, 'SIGTERM');
  } catch (err) {
    if ((err as NodeJS.ErrnoException)?.code === 'ESRCH') {
      removeRuntimeFile(config.state.dir, targetPid);
      return 0;
    }
    console.error(`Failed signalling pid=${targetPid}: ${err instanceof Error ? err.message : String(err)}`);
    return 1;
  }

  for (let i = 0; i < 40; i++) {
    if (!isPidAlive(targetPid)) {
      removeRuntimeFile(config.state.dir, targetPid);
      console.log(`Stopped Nonlocal bridge (pid=${targetPid}).`);
      return 0;
    }
    await sleep(100);
  }

  try {
    process.kill(targetPid, 'SIGKILL');
  } catch {
    // ignore
  }
  removeRuntimeFile(config.state.dir, targetPid);
  console.log(`Stopped Nonlocal bridge forcefully (pid=${targetPid}).`);
  return 0;
}

export async function handleRestartCommand(opts: {
  standalone?: boolean;
  overrides: CliConfigOverrides;
}): Promise<number> {
  const config = loadConfig({ overrides: opts.overrides, requireConfigFile: true });
  const before = await probePortOwnership(config);
  if (before.portState === 'occupied_by_other') {
    console.error(`Refusing restart: port ${config.server.host}:${config.server.port} is occupied_by_other.`);
    return 1;
  }
  if (before.portState === 'owned_running') {
    const stopCode = await handleStopCommand(opts);
    if (stopCode !== 0) return stopCode;
  }
  return handleStartCommand({ standalone: opts.standalone, overrides: opts.overrides });
}

export async function handleStatusCommand(opts: {
  json?: boolean;
  overrides: CliConfigOverrides;
}): Promise<number> {
  let config: BridgeConfig;
  try {
    config = loadConfig({ overrides: opts.overrides, requireConfigFile: true });
  } catch (err) {
    if (opts.json) {
      console.log(JSON.stringify({ running: false, portState: 'free', mode: 'none', pid: null, listenAddresses: [], securityWarning: null, token: null, health: null, service: null, error: err instanceof Error ? err.message : String(err) }, null, 2));
    } else {
      console.error(`status failed: ${err instanceof Error ? err.message : String(err)}`);
    }
    return 1;
  }

  const ownership = await probePortOwnership(config);
  let tokenMeta: { path: string; mode: string | null; length: number | null } = {
    path: config.security.tokenFile,
    mode: null,
    length: null,
  };
  try {
    const tok = readValidatedSecretFile(config.security.tokenFile, 'security.tokenFile', MIN_TOKEN_BYTES);
    tokenMeta = {
      path: config.security.tokenFile,
      mode: `0${tok.mode.toString(8)}`,
      length: tok.length,
    };
  } catch {
    // keep null mode/length
  }

  const svc = queryPlatformServiceStatus(config);
  const warnLevel = classifyListenWarning(config.server.host);
  const statusObj = {
    running: ownership.portState === 'owned_running',
    portState: ownership.portState,
    mode: ownership.runtime?.mode ?? 'none',
    pid: ownership.runtime?.pid ?? null,
    listenAddresses: ownership.runtime?.listenAddresses ?? [],
    securityWarning: getSecurityWarningText(warnLevel),
    token: tokenMeta,
    health: ownership.health,
    service: svc,
  };

  if (opts.json) {
    console.log(JSON.stringify(statusObj, null, 2));
  } else {
    console.log(`Running: ${statusObj.running} (portState=${statusObj.portState}, mode=${statusObj.mode}, pid=${statusObj.pid ?? '-'})`);
    console.log(`Target: ${config.server.host}:${config.server.port}`);
    if (statusObj.health) {
      console.log(`Health: ok=${statusObj.health.ok} childAlive=${statusObj.health.childAlive} activeClient=${statusObj.health.activeClient}`);
    }
    console.log(`Token: ${tokenMeta.path} (mode=${tokenMeta.mode ?? 'invalid'}, bytes=${tokenMeta.length ?? 0})`);
    if (statusObj.securityWarning) console.warn(statusObj.securityWarning);
  }

  return ownership.portState === 'owned_running' && Boolean(ownership.health?.ok) ? 0 : 1;
}
