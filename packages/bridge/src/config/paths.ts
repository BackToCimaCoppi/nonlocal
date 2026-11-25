import { homedir } from 'node:os';
import { join, resolve as resolvePath } from 'node:path';

export function expandHome(rawPath: string, homeDir: string = homedir()): string {
  const trimmed = rawPath.trim();
  if (trimmed === '~') return homeDir;
  if (trimmed.startsWith('~/')) return join(homeDir, trimmed.slice(2));
  return trimmed;
}

export function resolveXdgConfigDir(env: NodeJS.ProcessEnv = process.env, homeDir: string = homedir()): string {
  const xdg = typeof env.XDG_CONFIG_HOME === 'string' && env.XDG_CONFIG_HOME.trim()
    ? expandHome(env.XDG_CONFIG_HOME, homeDir)
    : join(homeDir, '.config');
  return join(resolvePath(xdg), 'nonlocal');
}

export function resolveXdgStateDir(env: NodeJS.ProcessEnv = process.env, homeDir: string = homedir()): string {
  const xdg = typeof env.XDG_STATE_HOME === 'string' && env.XDG_STATE_HOME.trim()
    ? expandHome(env.XDG_STATE_HOME, homeDir)
    : join(homeDir, '.local', 'state');
  return join(resolvePath(xdg), 'nonlocal');
}

export function resolveDefaultConfigPath(env: NodeJS.ProcessEnv = process.env, homeDir: string = homedir()): string {
  return join(resolveXdgConfigDir(env, homeDir), 'config.json');
}

export function resolveDefaultTokenPath(env: NodeJS.ProcessEnv = process.env, homeDir: string = homedir()): string {
  return join(resolveXdgConfigDir(env, homeDir), 'bearer.token');
}

export function resolveDefaultStateDir(env: NodeJS.ProcessEnv = process.env, homeDir: string = homedir()): string {
  return resolveXdgStateDir(env, homeDir);
}
