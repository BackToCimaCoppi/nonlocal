import { existsSync } from 'node:fs';
import { dirname } from 'node:path';
import { loadConfig } from '../config/index.js';
import {
  assertPrivateFileTarget,
  atomicWritePrivateFile,
  generateBearerToken,
  MIN_TOKEN_BYTES,
  readValidatedSecretFile,
} from '../config/secrets.js';
import type { CliConfigOverrides } from '../config/types.js';
import { mkdirSync } from 'node:fs';

export function handleTokenCommand(
  action: string,
  opts: { reveal?: boolean; overrides: CliConfigOverrides }
): number {
  try {
    const cfg = loadConfig({ overrides: opts.overrides, requireConfigFile: true });
    const tokPath = cfg.security.tokenFile;

    if (action === 'path') {
      if (!existsSync(tokPath)) {
        console.error(`Token file missing: ${tokPath}`);
        return 1;
      }
      const info = readValidatedSecretFile(tokPath, 'security.tokenFile', MIN_TOKEN_BYTES);
      console.log(`${tokPath} (mode=0${info.mode.toString(8)}, length=${info.length})`);
      return 0;
    }

    if (action === 'show') {
      if (!opts.reveal) {
        console.error('Refusing to print plaintext token without --reveal flag.');
        return 1;
      }
      const info = readValidatedSecretFile(tokPath, 'security.tokenFile', MIN_TOKEN_BYTES);
      console.log(info.value);
      return 0;
    }

    if (action === 'rotate') {
      assertPrivateFileTarget(tokPath, 'security.tokenFile');
      mkdirSync(dirname(tokPath), { recursive: true, mode: 0o700 });
      atomicWritePrivateFile(tokPath, `${generateBearerToken()}\n`);
      console.log(`Rotated Bearer token at ${tokPath} (0600, 64 hex bytes). Restart the bridge to apply.`);
      return 0;
    }

    console.error(`Unknown token action "${action}": expected path|show|rotate`);
    return 1;
  } catch (err) {
    console.error(`token ${action} failed: ${err instanceof Error ? err.message : String(err)}`);
    return 1;
  }
}
