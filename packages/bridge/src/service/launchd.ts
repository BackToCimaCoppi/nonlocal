import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, unlinkSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve as resolvePath } from 'node:path';
import { atomicWritePrivateFile } from '../config/secrets.js';
import type { BridgeConfig } from '../config/types.js';

export const LAUNCHD_LABEL = 'com.nonlocal.bridge';

export function isEphemeralEntryPath(entryPath: string): boolean {
  const normalized = entryPath.replace(/\\/g, '/');
  return (
    normalized.includes('/_npx/') ||
    normalized.includes('/npx-') ||
    normalized.includes('/npm-cache/_npx/') ||
    normalized.includes('/pnpm/dlx/')
  );
}

export function xmlEscape(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

export function resolveDefaultPlistPath(homeDir: string = homedir()): string {
  return join(homeDir, 'Library', 'LaunchAgents', `${LAUNCHD_LABEL}.plist`);
}

export function resolveServiceLogPath(config: BridgeConfig): string {
  const candidate = join(config.state.dir, 'service.log');
  if (resolvePath(candidate) === resolvePath(config.state.logFile)) {
    return join(config.state.dir, 'bridge-service.log');
  }
  return candidate;
}

export interface LaunchdRenderOptions {
  config: BridgeConfig;
  nodeBin?: string;
  entryScript: string;
  homeDir?: string;
  pathEnv?: string;
  allowEphemeralPath?: boolean;
}

export function renderLaunchdPlist(opts: LaunchdRenderOptions): string {
  if (!opts.allowEphemeralPath && isEphemeralEntryPath(opts.entryScript)) {
    throw new Error(
      `Refusing to install service pointing to ephemeral cache path "${opts.entryScript}". Install globally or re-run with --allow-ephemeral-path.`
    );
  }

  const nodeBin = opts.nodeBin || process.execPath;
  const homeDir = opts.homeDir || homedir();
  const serviceLog = resolveServiceLogPath(opts.config);
  const pathEnv = opts.pathEnv ?? process.env.PATH ?? '/usr/local/bin:/usr/bin:/bin';

  const args = [
    nodeBin,
    opts.entryScript,
    'start',
    '--foreground',
    '--config',
    opts.config.configPath,
  ].filter((a) => typeof a === 'string' && a.length > 0);

  const argLines = args.map((a) => `    <string>${xmlEscape(a)}</string>`).join('\n');

  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0">',
    '<dict>',
    '  <key>Label</key>',
    `  <string>${xmlEscape(LAUNCHD_LABEL)}</string>`,
    '',
    '  <key>ProgramArguments</key>',
    '  <array>',
    argLines,
    '  </array>',
    '',
    '  <key>EnvironmentVariables</key>',
    '  <dict>',
    '    <key>HOME</key>',
    `    <string>${xmlEscape(homeDir)}</string>`,
    '    <key>PATH</key>',
    `    <string>${xmlEscape(pathEnv)}</string>`,
    '  </dict>',
    '',
    '  <key>WorkingDirectory</key>',
    `  <string>${xmlEscape(homeDir)}</string>`,
    '',
    '  <key>RunAtLoad</key>',
    '  <true/>',
    '',
    '  <key>KeepAlive</key>',
    '  <true/>',
    '',
    '  <key>ThrottleInterval</key>',
    '  <integer>5</integer>',
    '',
    '  <key>ProcessType</key>',
    '  <string>Interactive</string>',
    '',
    '  <key>Umask</key>',
    '  <integer>63</integer>',
    '',
    '  <key>StandardOutPath</key>',
    `  <string>${xmlEscape(serviceLog)}</string>`,
    '  <key>StandardErrorPath</key>',
    `  <string>${xmlEscape(serviceLog)}</string>`,
    '</dict>',
    '</plist>',
    '',
  ].join('\n');
}

export function lintPlistWithPlutil(plistPath: string): { ok: boolean; detail: string } {
  const plutilBin = existsSync('/usr/bin/plutil') ? '/usr/bin/plutil' : 'plutil';
  try {
    const out = execFileSync(plutilBin, ['-lint', plistPath], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 5000,
    });
    return { ok: true, detail: out.trim() };
  } catch (err) {
    return {
      ok: false,
      detail: err instanceof Error ? err.message : 'plutil lint failed',
    };
  }
}

export interface LaunchdControlOptions extends LaunchdRenderOptions {
  plistPath?: string;
  dryRun?: boolean;
  runLaunchctl?: (args: string[]) => { ok: boolean; stdout: string; stderr: string };
}

function defaultLaunchctl(args: string[]): { ok: boolean; stdout: string; stderr: string } {
  try {
    const stdout = execFileSync('launchctl', args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 8000,
    });
    return { ok: true, stdout, stderr: '' };
  } catch (err) {
    const e = err as { stdout?: Buffer | string; stderr?: Buffer | string; message?: string };
    return {
      ok: false,
      stdout: String(e.stdout ?? ''),
      stderr: String(e.stderr ?? e.message ?? ''),
    };
  }
}

export function installLaunchdService(opts: LaunchdControlOptions): {
  plistPath: string;
  plistContent: string;
  plutilOk: boolean;
  loaded: boolean;
} {
  const plistPath = opts.plistPath || resolveDefaultPlistPath(opts.homeDir);
  const content = renderLaunchdPlist(opts);
  mkdirSync(opts.config.state.dir, { recursive: true, mode: 0o700 });
  mkdirSync(dirname(plistPath), { recursive: true });
  atomicWritePrivateFile(plistPath, content);

  const lint = lintPlistWithPlutil(plistPath);
  if (!lint.ok) {
    try {
      unlinkSync(plistPath);
    } catch {
      // ignore
    }
    throw new Error(`Invalid launchd plist (${plistPath}): ${lint.detail}`);
  }

  let loaded = false;
  if (!opts.dryRun) {
    const exec = opts.runLaunchctl || defaultLaunchctl;
    const uid = typeof process.getuid === 'function' ? process.getuid() : 0;
    const targetDomain = `gui/${uid}`;
    exec(['bootout', targetDomain, plistPath]);
    const boot = exec(['bootstrap', targetDomain, plistPath]);
    if (!boot.ok) {
      const legacy = exec(['load', '-w', plistPath]);
      loaded = legacy.ok;
      if (!loaded) {
        throw new Error(`launchctl load failed: ${boot.stderr || legacy.stderr}`);
      }
    } else {
      loaded = true;
    }
  }

  return { plistPath, plistContent: content, plutilOk: lint.ok, loaded };
}

export function uninstallLaunchdService(opts: {
  homeDir?: string;
  plistPath?: string;
  dryRun?: boolean;
  runLaunchctl?: (args: string[]) => { ok: boolean; stdout: string; stderr: string };
}): { plistPath: string; removed: boolean } {
  const plistPath = opts.plistPath || resolveDefaultPlistPath(opts.homeDir);
  if (!opts.dryRun) {
    const exec = opts.runLaunchctl || defaultLaunchctl;
    const uid = typeof process.getuid === 'function' ? process.getuid() : 0;
    exec(['bootout', `gui/${uid}`, plistPath]);
    exec(['unload', '-w', plistPath]);
  }
  let removed = false;
  if (existsSync(plistPath)) {
    unlinkSync(plistPath);
    removed = true;
  }
  return { plistPath, removed };
}

export function getLaunchdServiceStatus(opts: {
  homeDir?: string;
  plistPath?: string;
  runLaunchctl?: (args: string[]) => { ok: boolean; stdout: string; stderr: string };
} = {}): { installed: boolean; running: boolean; name: string; plistPath: string } {
  const plistPath = opts.plistPath || resolveDefaultPlistPath(opts.homeDir);
  const installed = existsSync(plistPath) && readFileSync(plistPath, 'utf8').includes(LAUNCHD_LABEL);
  const exec = opts.runLaunchctl || defaultLaunchctl;
  const uid = typeof process.getuid === 'function' ? process.getuid() : 0;
  const res = exec(['print', `gui/${uid}/${LAUNCHD_LABEL}`]);
  const running = res.ok && /state\s*=\s*running/i.test(res.stdout);
  return { installed, running, name: LAUNCHD_LABEL, plistPath };
}
