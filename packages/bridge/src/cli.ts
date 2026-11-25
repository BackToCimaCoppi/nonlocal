#!/usr/bin/env node
import { Command } from 'commander';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import type { CliConfigOverrides, TitleLanguage } from './config/types.js';
import { handleInitCommand } from './cli/init.js';
import {
  handleRestartCommand,
  handleStartCommand,
  handleStatusCommand,
  handleStopCommand,
} from './cli/lifecycle.js';
import { handleDoctorCommand } from './cli/doctor.js';
import { handleServiceCommand } from './cli/service.js';
import { handleTemplateCommand } from './cli/template.js';
import { handleTokenCommand } from './cli/token.js';
import { handleLogsCommand } from './cli/logs.js';

function readPackageVersion(): string {
  try {
    const here = dirname(fileURLToPath(import.meta.url));
    const pkgPath = join(here, '..', 'package.json');
    if (existsSync(pkgPath)) {
      const parsed = JSON.parse(readFileSync(pkgPath, 'utf8')) as { version?: string };
      return parsed.version || '0.1.0';
    }
  } catch {
    // ignore
  }
  return '0.1.0';
}

function addConfigFlags(cmd: Command): Command {
  return cmd
    .option('--config <path>', 'Path to config.json')
    .option('--host <ip>', 'Listen IP address')
    .option('--port <port>', 'Listen port (0..65535)', (v) => Number(v))
    .option('--allow-non-loopback', 'Allow non-loopback listen address')
    .option('--token-file <path>', 'Bearer token file path (0600)')
    .option('--state-dir <path>', 'State directory path')
    .option('--log-file <path>', 'Log file path')
    .option('--adapter <type>', 'Adapter type (antigravity|generic-acp)')
    .option('--adapter-command <cmd>', 'Adapter executable command')
    .option('--adapter-args <json>', 'Adapter arguments as JSON string array')
    .option('--default-model <id>', 'Default model lock id')
    .option('--default-thought-level <level>', 'Default thought level lock');
}

function toOverrides(opts: Record<string, unknown>): CliConfigOverrides {
  return {
    config: typeof opts.config === 'string' ? opts.config : undefined,
    host: typeof opts.host === 'string' ? opts.host : undefined,
    port: typeof opts.port === 'number' && !Number.isNaN(opts.port) ? opts.port : undefined,
    allowNonLoopback: opts.allowNonLoopback === true ? true : undefined,
    tokenFile: typeof opts.tokenFile === 'string' ? opts.tokenFile : undefined,
    stateDir: typeof opts.stateDir === 'string' ? opts.stateDir : undefined,
    logFile: typeof opts.logFile === 'string' ? opts.logFile : undefined,
    adapter: typeof opts.adapter === 'string' ? opts.adapter : undefined,
    adapterCommand: typeof opts.adapterCommand === 'string' ? opts.adapterCommand : undefined,
    adapterArgs: typeof opts.adapterArgs === 'string' ? opts.adapterArgs : undefined,
    defaultModel: typeof opts.defaultModel === 'string' ? opts.defaultModel : undefined,
    defaultThoughtLevel:
      typeof opts.defaultThoughtLevel === 'string' ? opts.defaultThoughtLevel : undefined,
  };
}

const version = readPackageVersion();
const program = new Command();

program
  .name('nonlocal-bridge')
  .description('Cross-platform TypeScript ACP-to-WebSocket bridge for Nonlocal')
  .version(version);

addConfigFlags(
  program
    .command('init')
    .description('Initialize configuration and Bearer token, or import legacy agy-acp state')
    .option('-y, --yes', 'Run non-interactively with defaults/flags')
    .option('--force', 'Overwrite existing configuration/token/database')
    .option('--import-legacy', 'Read-only import from legacy agy-acp config/state directories')
    .option('--legacy-config-dir <path>', 'Override legacy config directory')
    .option('--legacy-state-dir <path>', 'Override legacy state directory')
    .option('--title-language <lang>', 'AI title summary language (auto|zh|en)')
).action(async (opts: Record<string, unknown>) => {
  process.exitCode = await handleInitCommand({
    yes: Boolean(opts.yes),
    force: Boolean(opts.force),
    importLegacy: Boolean(opts.importLegacy),
    legacyConfigDir: typeof opts.legacyConfigDir === 'string' ? opts.legacyConfigDir : undefined,
    legacyStateDir: typeof opts.legacyStateDir === 'string' ? opts.legacyStateDir : undefined,
    config: typeof opts.config === 'string' ? opts.config : undefined,
    host: typeof opts.host === 'string' ? opts.host : undefined,
    port: typeof opts.port === 'number' ? opts.port : undefined,
    allowNonLoopback: Boolean(opts.allowNonLoopback),
    adapter: typeof opts.adapter === 'string' ? opts.adapter : undefined,
    adapterCommand: typeof opts.adapterCommand === 'string' ? opts.adapterCommand : undefined,
    adapterArgs: typeof opts.adapterArgs === 'string' ? opts.adapterArgs : undefined,
    defaultModel: typeof opts.defaultModel === 'string' ? opts.defaultModel : undefined,
    defaultThoughtLevel: typeof opts.defaultThoughtLevel === 'string' ? opts.defaultThoughtLevel : undefined,
    titleLanguage:
      typeof opts.titleLanguage === 'string' ? (opts.titleLanguage as TitleLanguage) : undefined,
    stateDir: typeof opts.stateDir === 'string' ? opts.stateDir : undefined,
    tokenFile: typeof opts.tokenFile === 'string' ? opts.tokenFile : undefined,
  });
});

addConfigFlags(
  program
    .command('start')
    .description('Start the bridge server')
    .option('--foreground', 'Run in foreground')
    .option('--standalone', 'Run detached standalone without invoking launchd/systemd')
).action(async (opts: Record<string, unknown>) => {
  process.exitCode = await handleStartCommand({
    foreground: Boolean(opts.foreground),
    standalone: Boolean(opts.standalone),
    overrides: toOverrides(opts),
  });
});

addConfigFlags(
  program
    .command('stop')
    .description('Stop the running bridge server')
    .option('--standalone', 'Signal runtime PID directly without touching launchd/systemd')
).action(async (opts: Record<string, unknown>) => {
  process.exitCode = await handleStopCommand({
    standalone: Boolean(opts.standalone),
    overrides: toOverrides(opts),
  });
});

addConfigFlags(
  program
    .command('restart')
    .description('Restart the bridge server')
    .option('--standalone', 'Restart standalone without touching launchd/systemd')
).action(async (opts: Record<string, unknown>) => {
  process.exitCode = await handleRestartCommand({
    standalone: Boolean(opts.standalone),
    overrides: toOverrides(opts),
  });
});

addConfigFlags(
  program
    .command('status')
    .description('Inspect bridge runtime, /health, and service status')
    .option('--json', 'Output structured JSON')
).action(async (opts: Record<string, unknown>) => {
  process.exitCode = await handleStatusCommand({
    json: Boolean(opts.json),
    overrides: toOverrides(opts),
  });
});

addConfigFlags(
  program
    .command('logs')
    .description('Inspect bridge or service logs')
    .option('-n <lines>', 'Number of tail lines to show', (v) => Number(v), 50)
    .option('-f, --follow', 'Follow log output')
    .option('--service', 'Read service stdout/stderr log instead of bridge.log')
).action(async (opts: Record<string, unknown>) => {
  process.exitCode = await handleLogsCommand({
    lines: typeof opts.n === 'number' ? opts.n : 50,
    follow: Boolean(opts.follow),
    service: Boolean(opts.service),
    overrides: toOverrides(opts),
  });
});

const tokenCmd = program.command('token').description('Manage Bearer token');
addConfigFlags(tokenCmd.command('path').description('Show token file path, mode, and byte length')).action(
  (opts: Record<string, unknown>) => {
    process.exitCode = handleTokenCommand('path', { overrides: toOverrides(opts) });
  }
);
addConfigFlags(
  tokenCmd
    .command('show')
    .description('Display Bearer token (requires --reveal)')
    .option('--reveal', 'Confirm outputting plaintext Bearer token')
).action((opts: Record<string, unknown>) => {
  process.exitCode = handleTokenCommand('show', {
    reveal: Boolean(opts.reveal),
    overrides: toOverrides(opts),
  });
});
addConfigFlags(tokenCmd.command('rotate').description('Generate a new 64-char hex Bearer token')).action(
  (opts: Record<string, unknown>) => {
    process.exitCode = handleTokenCommand('rotate', { overrides: toOverrides(opts) });
  }
);

addConfigFlags(
  program
    .command('doctor')
    .description('Run 8-point diagnostics including live WebSocket handshake')
    .option('--json', 'Output structured JSON')
).action(async (opts: Record<string, unknown>) => {
  process.exitCode = await handleDoctorCommand({
    json: Boolean(opts.json),
    overrides: toOverrides(opts),
    bridgeVersion: version,
  });
});

const svcCmd = program.command('service').description('Manage background user service (launchd/systemd)');
for (const act of ['install', 'uninstall', 'status']) {
  addConfigFlags(
    svcCmd
      .command(act)
      .description(`${act} background service`)
      .option('--target <platform>', 'Service manager target (launchd|systemd)')
      .option('--dry-run', 'Generate/validate unit without calling launchctl/systemctl')
      .option('--allow-ephemeral-path', 'Allow installing from ephemeral cache path')
      .option('--plist-path <path>', 'Custom launchd plist output path')
      .option('--unit-path <path>', 'Custom systemd unit output path')
  ).action(async (opts: Record<string, unknown>) => {
    process.exitCode = await handleServiceCommand(act, {
      target: typeof opts.target === 'string' ? opts.target : undefined,
      dryRun: Boolean(opts.dryRun),
      allowEphemeralPath: Boolean(opts.allowEphemeralPath),
      plistPath: typeof opts.plistPath === 'string' ? opts.plistPath : undefined,
      unitPath: typeof opts.unitPath === 'string' ? opts.unitPath : undefined,
      overrides: toOverrides(opts),
    });
  });
}

addConfigFlags(
  program
    .command('template [name]')
    .description('Render sanitized remote-access templates (list|tailscale|cloudflare|vps-caddy|vps-nginx|vps-ssh-tunnel|lan)')
).action((name: string | undefined, opts: Record<string, unknown>) => {
  process.exitCode = handleTemplateCommand(name, toOverrides(opts));
});

await program.parseAsync(process.argv);
