import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, unlinkSync } from 'node:fs';
import { homedir, userInfo } from 'node:os';
import { dirname, join } from 'node:path';
import { atomicWritePrivateFile } from '../config/secrets.js';
import type { BridgeConfig } from '../config/types.js';
import { isEphemeralEntryPath, resolveServiceLogPath } from './launchd.js';

export const SYSTEMD_SERVICE_NAME = 'nonlocal-bridge.service';

export function resolveDefaultSystemdUnitPath(homeDir: string = homedir()): string {
  return join(homeDir, '.config', 'systemd', 'user', SYSTEMD_SERVICE_NAME);
}

function systemdQuote(arg: string): string {
  if (/^[A-Za-z0-9_./:-]+$/.test(arg)) return arg;
  return `"${arg.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

export interface SystemdRenderOptions {
  config: BridgeConfig;
  nodeBin?: string;
  entryScript: string;
  homeDir?: string;
  pathEnv?: string;
  allowEphemeralPath?: boolean;
}

export function renderSystemdUnit(opts: SystemdRenderOptions): string {
  if (!opts.allowEphemeralPath && isEphemeralEntryPath(opts.entryScript)) {
    throw new Error(
      `Refusing to install service pointing to ephemeral cache path "${opts.entryScript}". Install globally or re-run with --allow-ephemeral-path.`
    );
  }

  const nodeBin = opts.nodeBin || process.execPath;
  const homeDir = opts.homeDir || homedir();
  const serviceLog = resolveServiceLogPath(opts.config);
  const pathEnv = opts.pathEnv ?? process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin';
  const execStart = [
    systemdQuote(nodeBin),
    systemdQuote(opts.entryScript),
    'start',
    '--foreground',
    '--config',
    systemdQuote(opts.config.configPath),
  ].join(' ');

  return [
    '[Unit]',
    'Description=Nonlocal ACP WebSocket Bridge',
    'After=network-online.target',
    'Wants=network-online.target',
    '',
    '[Service]',
    'Type=simple',
    `WorkingDirectory=${homeDir}`,
    `Environment=HOME=${homeDir}`,
    `Environment=PATH=${pathEnv}`,
    `ExecStart=${execStart}`,
    'Restart=always',
    'RestartSec=5',
    'KillMode=control-group',
    'TimeoutStopSec=10',
    'UMask=0077',
    `StandardOutput=append:${serviceLog}`,
    `StandardError=append:${serviceLog}`,
    '',
    '[Install]',
    'WantedBy=default.target',
    '',
  ].join('\n');
}

export interface LingerCheckResult {
  lingerEnabled: boolean | null;
  warning?: string;
  fixCommand?: string;
  diagnostic?: string;
}

export function checkSystemdLingerReadOnly(
  userName?: string,
  runCommand?: (bin: string, args: string[]) => { ok: boolean; stdout: string; stderr: string }
): LingerCheckResult {
  const resolvedUser = userName || userInfo().username || process.env.USER || '';
  if (!resolvedUser) {
    return { lingerEnabled: null, diagnostic: 'Cannot determine current OS user for loginctl check' };
  }
  const exec =
    runCommand ||
    ((bin: string, args: string[]) => {
      try {
        const stdout = execFileSync(bin, args, {
          encoding: 'utf8',
          stdio: ['ignore', 'pipe', 'pipe'],
          timeout: 3000,
        });
        return { ok: true, stdout, stderr: '' };
      } catch (err) {
        const e = err as { stdout?: Buffer | string; stderr?: Buffer | string; message?: string };
        return { ok: false, stdout: String(e.stdout ?? ''), stderr: String(e.stderr ?? e.message ?? '') };
      }
    });

  const res = exec('loginctl', ['show-user', resolvedUser, '-p', 'Linger', '--value']);
  if (!res.ok) {
    const errText = `${res.stderr} ${res.stdout}`.trim();
    if (/dbus|bus/i.test(errText)) {
      return {
        lingerEnabled: null,
        diagnostic: `systemd user D-Bus session is unavailable (${errText}); verify lingering in an active login session.`,
      };
    }
    return {
      lingerEnabled: null,
      diagnostic: errText || 'loginctl command unavailable',
    };
  }

  const val = res.stdout.trim().toLowerCase();
  if (val === 'yes') {
    return { lingerEnabled: true };
  }
  if (val === 'no') {
    return {
      lingerEnabled: false,
      warning: `User "${resolvedUser}" does not have systemd linger enabled; background service will stop on SSH logout.`,
      fixCommand: `sudo loginctl enable-linger ${resolvedUser}`,
    };
  }
  return { lingerEnabled: null, diagnostic: `Unexpected loginctl output: "${val}"` };
}

export interface SystemdControlOptions extends SystemdRenderOptions {
  unitPath?: string;
  dryRun?: boolean;
  userName?: string;
  runSystemdCmd?: (bin: string, args: string[]) => { ok: boolean; stdout: string; stderr: string };
}

function defaultRunCmd(bin: string, args: string[]): { ok: boolean; stdout: string; stderr: string } {
  try {
    const stdout = execFileSync(bin, args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 8000,
    });
    return { ok: true, stdout, stderr: '' };
  } catch (err) {
    const e = err as { stdout?: Buffer | string; stderr?: Buffer | string; message?: string };
    return { ok: false, stdout: String(e.stdout ?? ''), stderr: String(e.stderr ?? e.message ?? '') };
  }
}

export function installSystemdService(opts: SystemdControlOptions): {
  unitPath: string;
  unitContent: string;
  started: boolean;
  linger: LingerCheckResult;
} {
  const unitPath = opts.unitPath || resolveDefaultSystemdUnitPath(opts.homeDir);
  const content = renderSystemdUnit(opts);
  mkdirSync(opts.config.state.dir, { recursive: true, mode: 0o700 });
  mkdirSync(dirname(unitPath), { recursive: true, mode: 0o755 });
  atomicWritePrivateFile(unitPath, content);

  const exec = opts.runSystemdCmd || defaultRunCmd;
  let started = false;
  if (!opts.dryRun) {
    const reload = exec('systemctl', ['--user', 'daemon-reload']);
    if (!reload.ok) {
      throw new Error(`systemctl --user daemon-reload failed: ${reload.stderr || 'D-Bus unavailable'}`);
    }
    const enable = exec('systemctl', ['--user', 'enable', '--now', SYSTEMD_SERVICE_NAME]);
    if (!enable.ok) {
      throw new Error(`systemctl --user enable --now failed: ${enable.stderr}`);
    }
    started = true;
  }

  const linger = checkSystemdLingerReadOnly(opts.userName, opts.runSystemdCmd);
  return { unitPath, unitContent: content, started, linger };
}

export function uninstallSystemdService(opts: {
  homeDir?: string;
  unitPath?: string;
  dryRun?: boolean;
  runSystemdCmd?: (bin: string, args: string[]) => { ok: boolean; stdout: string; stderr: string };
}): { unitPath: string; removed: boolean } {
  const unitPath = opts.unitPath || resolveDefaultSystemdUnitPath(opts.homeDir);
  if (!opts.dryRun) {
    const exec = opts.runSystemdCmd || defaultRunCmd;
    exec('systemctl', ['--user', 'disable', '--now', SYSTEMD_SERVICE_NAME]);
    exec('systemctl', ['--user', 'daemon-reload']);
  }
  let removed = false;
  if (existsSync(unitPath)) {
    unlinkSync(unitPath);
    removed = true;
  }
  return { unitPath, removed };
}

export function getSystemdServiceStatus(opts: {
  homeDir?: string;
  unitPath?: string;
  runSystemdCmd?: (bin: string, args: string[]) => { ok: boolean; stdout: string; stderr: string };
} = {}): { installed: boolean; running: boolean; name: string; unitPath: string } {
  const unitPath = opts.unitPath || resolveDefaultSystemdUnitPath(opts.homeDir);
  const installed = existsSync(unitPath);
  const exec = opts.runSystemdCmd || defaultRunCmd;
  const res = exec('systemctl', ['--user', 'is-active', SYSTEMD_SERVICE_NAME]);
  const running = res.ok && res.stdout.trim() === 'active';
  return { installed, running, name: SYSTEMD_SERVICE_NAME, unitPath };
}
