import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig } from '../config/index.js';
import type { CliConfigOverrides } from '../config/types.js';

export const TEMPLATE_FILES: Record<string, string> = {
  tailscale: 'tailscale.txt',
  cloudflare: 'cloudflare.yml',
  'vps-caddy': 'vps-caddy.Caddyfile',
  'vps-nginx': 'vps-nginx.conf',
  'vps-ssh-tunnel': 'vps-ssh-tunnel.sh',
  lan: 'lan.txt',
};

export function resolveTemplatesDir(): string {
  const here = dirname(fileURLToPath(import.meta.url));
  const candidate = join(here, '..', '..', 'templates');
  if (existsSync(candidate)) return candidate;
  return join(here, '..', '..', '..', 'templates');
}

export function renderNamedTemplate(name: string, vars: { host?: string; port?: number } = {}): string {
  const filename = TEMPLATE_FILES[name];
  if (!filename) {
    throw new Error(
      `Unknown template "${name}". Available templates: ${Object.keys(TEMPLATE_FILES).join(', ')}`
    );
  }
  const tplPath = join(resolveTemplatesDir(), filename);
  const raw = readFileSync(tplPath, 'utf8');
  const host = vars.host || '127.0.0.1';
  const port = Number.isInteger(vars.port) ? String(vars.port) : '8765';
  return raw.replace(/\{\{HOST\}\}/g, host).replace(/\{\{PORT\}\}/g, port);
}

export function handleTemplateCommand(name: string | undefined, overrides: CliConfigOverrides): number {
  if (!name || name === 'list') {
    console.log('Available network access templates:');
    for (const k of Object.keys(TEMPLATE_FILES)) {
      console.log(`  - ${k}`);
    }
    return 0;
  }

  let host = '127.0.0.1';
  let port = 8765;
  try {
    const cfg = loadConfig({ overrides, requireConfigFile: false });
    host = cfg.server.host;
    port = cfg.server.port;
  } catch {
    if (overrides.port !== undefined) port = Number(overrides.port);
    if (overrides.host !== undefined) host = overrides.host;
  }

  try {
    process.stdout.write(renderNamedTemplate(name, { host, port }));
    return 0;
  } catch (err) {
    console.error(err instanceof Error ? err.message : String(err));
    return 1;
  }
}
