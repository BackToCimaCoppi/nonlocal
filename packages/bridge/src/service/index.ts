import type { BridgeConfig } from '../config/types.js';
import { getLaunchdServiceStatus } from './launchd.js';
import { getSystemdServiceStatus } from './systemd.js';

export * from './runtime.js';
export * from './launchd.js';
export * from './systemd.js';

export type ServicePlatform = 'launchd' | 'systemd';

export function detectServicePlatform(explicitTarget?: string, platform: NodeJS.Platform = process.platform): ServicePlatform {
  if (explicitTarget === 'launchd' || explicitTarget === 'systemd') {
    return explicitTarget;
  }
  if (explicitTarget && explicitTarget.trim()) {
    throw new Error(`Unsupported service target "${explicitTarget}": expected launchd|systemd`);
  }
  return platform === 'darwin' ? 'launchd' : 'systemd';
}

export function queryPlatformServiceStatus(
  _config: BridgeConfig,
  opts: { target?: string; platform?: NodeJS.Platform; homeDir?: string; plistPath?: string; unitPath?: string } = {}
): { platform: ServicePlatform; installed: boolean; running: boolean; name: string } {
  const target = detectServicePlatform(opts.target, opts.platform);
  if (target === 'launchd') {
    const s = getLaunchdServiceStatus({ homeDir: opts.homeDir, plistPath: opts.plistPath });
    return { platform: 'launchd', installed: s.installed, running: s.running, name: s.name };
  }
  const s = getSystemdServiceStatus({ homeDir: opts.homeDir, unitPath: opts.unitPath });
  return { platform: 'systemd', installed: s.installed, running: s.running, name: s.name };
}
