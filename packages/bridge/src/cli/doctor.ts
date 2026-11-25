import { execFileSync } from 'node:child_process';
import { constants as fsConstants, accessSync, existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { WebSocket } from 'ws';
import { classifyListenWarning, getSecurityWarningText, resolveLocalProbeHost } from '../config/ip.js';
import { loadConfig } from '../config/index.js';
import { MIN_TOKEN_BYTES, readValidatedSecretFile } from '../config/secrets.js';
import type { BridgeConfig, CliConfigOverrides } from '../config/types.js';
import { probePortOwnership } from '../service/runtime.js';

export type DoctorStatus = 'pass' | 'warn' | 'fail';

export interface DoctorCheckItem {
  id:
    | 'platform'
    | 'node_runtime'
    | 'config_security'
    | 'bearer_token'
    | 'adapter_cli'
    | 'antigravity_settings'
    | 'port_binding'
    | 'bridge_live_handshake';
  status: DoctorStatus;
  summary: string;
  fixHint?: string;
  fixCommand?: string;
}

export interface DoctorReport {
  ok: boolean;
  timestamp: string;
  bridgeVersion: string;
  summary: {
    pass: number;
    warn: number;
    fail: number;
  };
  checks: DoctorCheckItem[];
}

function resolveExecutable(cmd: string): string | null {
  const trimmed = cmd.trim();
  if (!trimmed) return null;
  if (trimmed.includes('/')) {
    try {
      accessSync(trimmed, fsConstants.X_OK);
      return trimmed;
    } catch {
      return null;
    }
  }
  try {
    const out = execFileSync('which', [trimmed], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    if (!out) return null;
    accessSync(out, fsConstants.X_OK);
    return out;
  } catch {
    return null;
  }
}

async function performLiveWsHandshake(
  probeHost: string,
  port: number,
  token: string,
  bridgeVersion: string
): Promise<{ ok: boolean; detail: string }> {
  const hostFmt = probeHost.includes(':') ? `[${probeHost}]` : probeHost;
  const url = `ws://${hostFmt}:${port}/acp`;
  return new Promise((resolve) => {
    let settled = false;
    const finish = (ok: boolean, detail: string) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        ws.close(1000, 'doctor_done');
      } catch {
        // ignore
      }
      resolve({ ok, detail });
    };

    const ws = new WebSocket(url, {
      headers: { Authorization: `Bearer ${token}` },
      perMessageDeflate: false,
    });

    const timer = setTimeout(() => {
      try {
        ws.terminate();
      } catch {
        // ignore
      }
      finish(false, 'Timed out awaiting live WS initialize response');
    }, 3500);

    ws.on('open', () => {
      ws.send(
        JSON.stringify({
          jsonrpc: '2.0',
          id: 'doctor_init_1',
          method: 'initialize',
          params: {
            protocolVersion: 1,
            clientInfo: { name: 'nonlocal-bridge-doctor', version: bridgeVersion },
          },
        })
      );
    });

    ws.on('message', (data) => {
      try {
        const msg = JSON.parse(data.toString('utf8')) as {
          id?: unknown;
          result?: unknown;
          error?: { message?: unknown };
        };
        if (msg.id !== 'doctor_init_1') return;
        if (msg.result) {
          finish(true, 'Live WS Auth + JSON-RPC initialize succeeded');
          return;
        }
        const errMsg = String(msg.error?.message ?? '');
        if (/already\s*initialized/i.test(errMsg)) {
          finish(true, 'Live WS Auth + initialize (already initialized) succeeded');
          return;
        }
        finish(false, `Upstream initialize returned error: ${errMsg || 'unknown'}`);
      } catch {
        // ignore malformed frame
      }
    });

    ws.on('unexpected-response', (_req, res) => {
      finish(false, `WebSocket handshake rejected with HTTP ${res.statusCode}`);
    });

    ws.on('error', (err) => {
      finish(false, `WebSocket connection error: ${err.message}`);
    });
  });
}

export async function runDoctor(opts: {
  overrides: CliConfigOverrides;
  env?: NodeJS.ProcessEnv;
  homeDir?: string;
  bridgeVersion?: string;
}): Promise<DoctorReport> {
  const env = opts.env ?? process.env;
  const homeDir = opts.homeDir ?? homedir();
  const bridgeVersion = opts.bridgeVersion ?? '0.1.0';
  const checks: DoctorCheckItem[] = [];

  // 1. platform
  checks.push({
    id: 'platform',
    status: 'pass',
    summary: `Platform ${process.platform} (${process.arch})`,
  });

  // 2. node_runtime
  const [major, minor] = process.versions.node.split('.').map(Number);
  const nodeOk = major > 22 || (major === 22 && minor >= 13);
  checks.push({
    id: 'node_runtime',
    status: nodeOk ? 'pass' : 'fail',
    summary: nodeOk ? `Node.js v${process.versions.node} >= 22.13.0` : `Node.js v${process.versions.node} < 22.13.0`,
    ...(nodeOk ? {} : { fixHint: 'Upgrade Node.js to >= 22.13.0 (LTS 22 or 24).' }),
  });

  // 3. config_security
  let config: BridgeConfig | null = null;
  let configErr: string | null = null;
  try {
    config = loadConfig({ overrides: opts.overrides, env, homeDir, requireConfigFile: true });
    const warnLevel = classifyListenWarning(config.server.host);
    const warnText = getSecurityWarningText(warnLevel);
    checks.push({
      id: 'config_security',
      status: warnText ? 'warn' : 'pass',
      summary: warnText ? `${warnText} (${config.configPath})` : `Validated config (${config.configPath})`,
      ...(warnText
        ? { fixHint: 'Bind 127.0.0.1 or ::1 behind Tailscale/SSH/TLS reverse proxy unless LAN access is intentional.' }
        : {}),
    });
  } catch (err) {
    configErr = err instanceof Error ? err.message : String(err);
    checks.push({
      id: 'config_security',
      status: 'fail',
      summary: `Configuration invalid or missing: ${configErr}`,
      fixCommand: 'nonlocal-bridge init --yes',
    });
  }

  // 4. bearer_token
  let tokenVal: string | null = null;
  if (!config) {
    checks.push({
      id: 'bearer_token',
      status: 'fail',
      summary: 'Skipped because config_security failed',
      fixCommand: 'nonlocal-bridge init --yes',
    });
  } else {
    try {
      const tok = readValidatedSecretFile(config.security.tokenFile, 'security.tokenFile', MIN_TOKEN_BYTES);
      tokenVal = tok.value;
      checks.push({
        id: 'bearer_token',
        status: 'pass',
        summary: `Bearer token valid (${tok.length} bytes, mode 0${tok.mode.toString(8)})`,
      });
    } catch (err) {
      checks.push({
        id: 'bearer_token',
        status: 'fail',
        summary: `Bearer token check failed: ${err instanceof Error ? err.message : String(err)}`,
        fixCommand: 'nonlocal-bridge token rotate',
      });
    }
  }

  // 5. adapter_cli
  if (!config) {
    checks.push({
      id: 'adapter_cli',
      status: 'fail',
      summary: 'Skipped because config_security failed',
    });
  } else {
    const cmd = config.adapter.type === 'antigravity' ? (config.adapter.command || 'agy') : config.adapter.command;
    const resolved = cmd ? resolveExecutable(cmd) : null;
    if (resolved) {
      checks.push({
        id: 'adapter_cli',
        status: 'pass',
        summary: `Adapter executable found (${resolved})`,
      });
    } else {
      checks.push({
        id: 'adapter_cli',
        status: 'fail',
        summary: `Adapter executable not found or not executable: "${cmd || '(empty)'}"`,
        fixHint: 'Install the adapter CLI or configure adapter.command.',
      });
    }
  }

  // 6. antigravity_settings (strictly read-only!)
  if (!config || config.adapter.type === 'generic-acp') {
    checks.push({
      id: 'antigravity_settings',
      status: 'pass',
      summary: 'Not applicable for generic-acp adapter',
    });
  } else {
    const settingsPath = join(homeDir, '.gemini', 'antigravity-cli', 'settings.json');
    if (!existsSync(settingsPath)) {
      checks.push({
        id: 'antigravity_settings',
        status: 'warn',
        summary: `Read-only check: ${settingsPath} not found`,
      });
    } else {
      try {
        const raw = JSON.parse(readFileSync(settingsPath, 'utf8')) as Record<string, unknown>;
        const acpOk = raw.enableACP === undefined || Boolean(raw.enableACP);
        checks.push({
          id: 'antigravity_settings',
          status: acpOk ? 'pass' : 'warn',
          summary: acpOk ? 'Read-only Antigravity settings OK' : 'Antigravity settings has enableACP disabled',
        });
      } catch {
        checks.push({
          id: 'antigravity_settings',
          status: 'warn',
          summary: `Read-only Antigravity settings file invalid JSON (${settingsPath})`,
        });
      }
    }
  }

  // 7. port_binding & 8. bridge_live_handshake
  if (!config) {
    checks.push({
      id: 'port_binding',
      status: 'fail',
      summary: 'Skipped because config_security failed',
    });
    checks.push({
      id: 'bridge_live_handshake',
      status: 'fail',
      summary: 'Skipped because config_security failed',
    });
  } else {
    const ownership = await probePortOwnership(config);
    if (ownership.portState === 'occupied_by_other') {
      checks.push({
        id: 'port_binding',
        status: 'fail',
        summary: `Port ${config.server.host}:${config.server.port} is occupied by another process (${ownership.reason})`,
        fixHint: 'Stop the conflicting process or change server.port in config.json.',
      });
      checks.push({
        id: 'bridge_live_handshake',
        status: 'fail',
        summary: 'Short-circuited: port_binding occupied_by_other (no WebSocket handshake attempted)',
        fixHint: 'Resolve port conflict before testing live handshake.',
      });
    } else if (ownership.portState === 'free') {
      checks.push({
        id: 'port_binding',
        status: 'pass',
        summary: `Port ${config.server.host}:${config.server.port} is free and available`,
      });
      checks.push({
        id: 'bridge_live_handshake',
        status: 'fail',
        summary: 'Bridge is not currently running on configured port',
        fixCommand: 'nonlocal-bridge start',
      });
    } else {
      checks.push({
        id: 'port_binding',
        status: 'pass',
        summary: `Owned Nonlocal bridge running on ${config.server.host}:${config.server.port} (pid=${ownership.runtime?.pid})`,
      });
      if (!tokenVal) {
        checks.push({
          id: 'bridge_live_handshake',
          status: 'fail',
          summary: 'Cannot run live WS handshake without valid Bearer token',
        });
      } else {
        const probeHost = resolveLocalProbeHost(config.server.host);
        const hs = await performLiveWsHandshake(probeHost, config.server.port, tokenVal, bridgeVersion);
        checks.push({
          id: 'bridge_live_handshake',
          status: hs.ok ? 'pass' : 'fail',
          summary: hs.detail,
          ...(hs.ok ? {} : { fixCommand: 'nonlocal-bridge restart' }),
        });
      }
    }
  }

  let pass = 0;
  let warn = 0;
  let fail = 0;
  for (const c of checks) {
    if (c.status === 'pass') pass += 1;
    else if (c.status === 'warn') warn += 1;
    else fail += 1;
  }

  return {
    ok: fail === 0,
    timestamp: new Date().toISOString(),
    bridgeVersion,
    summary: { pass, warn, fail },
    checks,
  };
}

export async function handleDoctorCommand(opts: {
  json?: boolean;
  overrides: CliConfigOverrides;
  bridgeVersion?: string;
}): Promise<number> {
  const report = await runDoctor({
    overrides: opts.overrides,
    bridgeVersion: opts.bridgeVersion,
  });

  if (opts.json) {
    console.log(JSON.stringify(report, null, 2));
  } else {
    console.log(`Nonlocal Doctor (${report.ok ? 'PASS' : 'FAIL'}): pass=${report.summary.pass} warn=${report.summary.warn} fail=${report.summary.fail}`);
    for (const c of report.checks) {
      console.log(`  [${c.status.toUpperCase()}] ${c.id}: ${c.summary}`);
      if (c.fixCommand) console.log(`         fix: ${c.fixCommand}`);
      else if (c.fixHint) console.log(`         hint: ${c.fixHint}`);
    }
  }

  return report.ok ? 0 : 1;
}
