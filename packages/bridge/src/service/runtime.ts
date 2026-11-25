import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, unlinkSync } from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import { join } from 'node:path';
import { resolveCompanionLoopback, resolveLocalProbeHost } from '../config/ip.js';
import { atomicWritePrivateFile } from '../config/secrets.js';
import type { BridgeConfig } from '../config/types.js';
import type { ListenEndpoint } from '../transport/types.js';

export type RuntimeMode = 'standalone' | 'launchd' | 'systemd';
export type PortOwnershipState = 'owned_running' | 'free' | 'occupied_by_other';

export interface BridgeRuntimeInfo {
  pid: number;
  mode: RuntimeMode;
  host: string;
  port: number;
  listenAddresses: ListenEndpoint[];
  configPath: string;
  startedAt: string;
  commandFingerprint: string;
}

export interface HealthProbeResult {
  ok: boolean;
  childAlive: boolean;
  activeClient: boolean;
}

export interface PortOwnershipResult {
  portState: PortOwnershipState;
  runtime: BridgeRuntimeInfo | null;
  health: HealthProbeResult | null;
  reason: string;
}

export function getRuntimeFilePath(stateDir: string): string {
  return join(stateDir, 'bridge.runtime.json');
}

export function computeCommandFingerprint(entryScriptPath: string): string {
  return `${entryScriptPath}::nonlocal-bridge`;
}

export function isPidAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException)?.code === 'EPERM';
  }
}

export function readProcessCommandLine(pid: number): string | null {
  if (!Number.isInteger(pid) || pid <= 0) return null;
  try {
    const out = execFileSync('ps', ['-p', String(pid), '-o', 'command='], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 2000,
    });
    return out.trim() || null;
  } catch {
    return null;
  }
}

export function matchesCommandFingerprint(pid: number, fingerprint: string): boolean {
  if (!isPidAlive(pid) || !fingerprint) return false;
  const cmd = readProcessCommandLine(pid);
  if (!cmd) return false;
  const scriptPart = fingerprint.split('::')[0] || '';
  if (scriptPart && cmd.includes(scriptPart)) return true;
  return cmd.includes('nonlocal-bridge');
}

export function writeRuntimeFile(stateDir: string, info: BridgeRuntimeInfo): string {
  const path = getRuntimeFilePath(stateDir);
  const exact: BridgeRuntimeInfo = {
    pid: info.pid,
    mode: info.mode,
    host: info.host,
    port: info.port,
    listenAddresses: info.listenAddresses,
    configPath: info.configPath,
    startedAt: info.startedAt,
    commandFingerprint: info.commandFingerprint,
  };
  atomicWritePrivateFile(path, `${JSON.stringify(exact, null, 2)}\n`);
  return path;
}

export function readRuntimeFile(stateDir: string): BridgeRuntimeInfo | null {
  const path = getRuntimeFilePath(stateDir);
  if (!existsSync(path)) return null;
  try {
    const raw = JSON.parse(readFileSync(path, 'utf8')) as Record<string, unknown>;
    if (!raw || typeof raw !== 'object') return null;
    if (typeof raw.pid !== 'number' || !Number.isInteger(raw.pid) || raw.pid <= 0) return null;
    if (typeof raw.host !== 'string' || typeof raw.port !== 'number') return null;
    if (typeof raw.commandFingerprint !== 'string') return null;
    const mode = raw.mode === 'launchd' || raw.mode === 'systemd' ? raw.mode : 'standalone';
    return {
      pid: raw.pid,
      mode,
      host: raw.host,
      port: raw.port,
      listenAddresses: Array.isArray(raw.listenAddresses) ? (raw.listenAddresses as ListenEndpoint[]) : [],
      configPath: typeof raw.configPath === 'string' ? raw.configPath : '',
      startedAt: typeof raw.startedAt === 'string' ? raw.startedAt : '',
      commandFingerprint: raw.commandFingerprint,
    };
  } catch {
    return null;
  }
}

export function removeRuntimeFile(stateDir: string, onlyPid?: number): void {
  const path = getRuntimeFilePath(stateDir);
  if (!existsSync(path)) return;
  if (onlyPid !== undefined) {
    const current = readRuntimeFile(stateDir);
    if (current && current.pid !== onlyPid) return;
  }
  try {
    unlinkSync(path);
  } catch {
    // ignore
  }
}

export function probeLoopbackHealth(
  hostOrProbeIp: string,
  port: number,
  timeoutMs: number = 1500
): Promise<HealthProbeResult | null> {
  const probeHost = resolveLocalProbeHost(hostOrProbeIp);
  return new Promise((resolve) => {
    const req = http.request(
      {
        host: probeHost,
        port,
        method: 'GET',
        path: '/health',
        timeout: timeoutMs,
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on('data', (c: Buffer) => chunks.push(c));
        res.on('end', () => {
          if (res.statusCode !== 200) {
            resolve(null);
            return;
          }
          try {
            const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8')) as Record<string, unknown>;
            if (parsed?.ok === true) {
              resolve({
                ok: true,
                childAlive: Boolean(parsed.childAlive),
                activeClient: Boolean(parsed.activeClient),
              });
            } else {
              resolve(null);
            }
          } catch {
            resolve(null);
          }
        });
      }
    );
    req.on('timeout', () => {
      req.destroy();
      resolve(null);
    });
    req.on('error', () => resolve(null));
    req.end();
  });
}

function tryBindTcp(host: string, port: number): Promise<{ free: boolean; code?: string }> {
  return new Promise((resolve) => {
    const srv = net.createServer();
    srv.once('error', (err: NodeJS.ErrnoException) => {
      resolve({ free: false, code: err.code });
    });
    const listenOpts: { port: number; host: string; ipv6Only?: boolean } = { port, host };
    if (host === '::') {
      listenOpts.ipv6Only = false;
    }
    srv.listen(listenOpts, () => {
      srv.close(() => resolve({ free: true }));
    });
  });
}

export async function checkPortFree(
  host: string,
  port: number,
  allowNonLoopback: boolean
): Promise<{ free: boolean; code?: string }> {
  if (port === 0) return { free: true };
  const primary = await tryBindTcp(host, port);
  if (!primary.free) return primary;
  const companion = allowNonLoopback ? resolveCompanionLoopback(host) : null;
  if (companion) {
    return tryBindTcp(companion, port);
  }
  return { free: true };
}

export async function probePortOwnership(config: BridgeConfig): Promise<PortOwnershipResult> {
  const runtime = readRuntimeFile(config.state.dir);
  if (
    runtime &&
    runtime.port === config.server.port &&
    matchesCommandFingerprint(runtime.pid, runtime.commandFingerprint)
  ) {
    const health = await probeLoopbackHealth(runtime.host, runtime.port);
    if (health?.ok) {
      return {
        portState: 'owned_running',
        runtime,
        health,
        reason: 'live_runtime_and_health_verified',
      };
    }
  }

  const bindCheck = await checkPortFree(config.server.host, config.server.port, config.server.allowNonLoopback);
  if (bindCheck.free) {
    return {
      portState: 'free',
      runtime: null,
      health: null,
      reason: 'tcp_bind_available',
    };
  }

  return {
    portState: 'occupied_by_other',
    runtime: null,
    health: null,
    reason: runtime ? 'port_in_use_unowned_or_stale_runtime' : `port_in_use_${bindCheck.code || 'EADDRINUSE'}`,
  };
}
