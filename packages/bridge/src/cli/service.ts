import { fileURLToPath } from 'node:url';
import { loadConfig } from '../config/index.js';
import { MIN_TOKEN_BYTES, readValidatedSecretFile } from '../config/secrets.js';
import type { CliConfigOverrides } from '../config/types.js';
import {
  detectServicePlatform,
  getLaunchdServiceStatus,
  getSystemdServiceStatus,
  installLaunchdService,
  installSystemdService,
  probePortOwnership,
  uninstallLaunchdService,
  uninstallSystemdService,
} from '../service/index.js';

const CLI_ENTRY_SCRIPT = fileURLToPath(new URL('../cli.js', import.meta.url));

export async function handleServiceCommand(
  action: string,
  opts: {
    target?: string;
    dryRun?: boolean;
    allowEphemeralPath?: boolean;
    plistPath?: string;
    unitPath?: string;
    overrides: CliConfigOverrides;
  }
): Promise<number> {
  try {
    const config = loadConfig({ overrides: opts.overrides, requireConfigFile: true });
    const target = detectServicePlatform(opts.target);

    if (action === 'install') {
      readValidatedSecretFile(config.security.tokenFile, 'security.tokenFile', MIN_TOKEN_BYTES);
      const ownership = await probePortOwnership(config);
      if (ownership.portState === 'occupied_by_other' && !opts.dryRun) {
        console.error(
          `Warning: port ${config.server.host}:${config.server.port} is occupied by another process; refusing automatic service startup.`
        );
        return 1;
      }

      if (target === 'launchd') {
        const res = installLaunchdService({
          config,
          entryScript: CLI_ENTRY_SCRIPT,
          plistPath: opts.plistPath,
          dryRun: opts.dryRun,
          allowEphemeralPath: opts.allowEphemeralPath,
        });
        console.log(`launchd plist written & verified (plutil): ${res.plistPath} (loaded=${res.loaded})`);
        return 0;
      }

      const res = installSystemdService({
        config,
        entryScript: CLI_ENTRY_SCRIPT,
        unitPath: opts.unitPath,
        dryRun: opts.dryRun,
        allowEphemeralPath: opts.allowEphemeralPath,
      });
      console.log(`systemd user unit written: ${res.unitPath} (started=${res.started})`);
      if (res.linger.warning) console.warn(res.linger.warning);
      if (res.linger.fixCommand) console.warn(`  Enable linger: ${res.linger.fixCommand}`);
      if (res.linger.diagnostic) console.warn(`  Diagnostic: ${res.linger.diagnostic}`);
      return 0;
    }

    if (action === 'uninstall') {
      if (target === 'launchd') {
        const res = uninstallLaunchdService({ plistPath: opts.plistPath, dryRun: opts.dryRun });
        console.log(`launchd uninstalled (removed=${res.removed}): ${res.plistPath}`);
        return 0;
      }
      const res = uninstallSystemdService({ unitPath: opts.unitPath, dryRun: opts.dryRun });
      console.log(`systemd user unit uninstalled (removed=${res.removed}): ${res.unitPath}`);
      return 0;
    }

    if (action === 'status') {
      if (target === 'launchd') {
        console.log(JSON.stringify(getLaunchdServiceStatus({ plistPath: opts.plistPath }), null, 2));
      } else {
        console.log(JSON.stringify(getSystemdServiceStatus({ unitPath: opts.unitPath }), null, 2));
      }
      return 0;
    }

    console.error(`Unknown service action "${action}": expected install|uninstall|status`);
    return 1;
  } catch (err) {
    console.error(`service ${action} failed: ${err instanceof Error ? err.message : String(err)}`);
    return 1;
  }
}
