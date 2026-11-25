import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';

export function makeTempDir(prefix = 'nonlocal-test-') {
  return mkdtempSync(join(tmpdir(), prefix));
}

export function rmTempDir(dirPath) {
  try {
    rmSync(dirPath, { recursive: true, force: true });
  } catch {
    // ignore cleanup error
  }
}

export function createTestToken(lenBytes = 32) {
  // Produces hex string of 2*lenBytes chars (e.g. 64 hex chars for 32 bytes)
  return randomBytes(Math.ceil(lenBytes / 2)).toString('hex').slice(0, lenBytes);
}

export function writePrivateTokenFile(dirPath, name = 'bearer.token', token = createTestToken(64)) {
  mkdirSync(dirPath, { recursive: true, mode: 0o700 });
  const tokenPath = join(dirPath, name);
  writeFileSync(tokenPath, `${token}\n`, { encoding: 'utf8', mode: 0o600 });
  chmodSync(tokenPath, 0o600);
  return { tokenPath, token };
}

export async function getFreePort(host = '127.0.0.1') {
  return await new Promise((resolve, reject) => {
    const srv = createServer();
    srv.unref();
    srv.once('error', reject);
    srv.listen(0, host, () => {
      const addr = srv.address();
      const port = typeof addr === 'object' && addr ? addr.port : 0;
      srv.close(() => resolve(port));
    });
  });
}

export function makeCleanEnv(extra = {}) {
  const out = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (
      k.startsWith('AGY_ACP_') ||
      k.startsWith('NONLOCAL_') ||
      k.startsWith('AGMENTE_') ||
      k === 'XDG_CONFIG_HOME' ||
      k === 'XDG_STATE_HOME'
    ) {
      continue;
    }
    if (v !== undefined) out[k] = v;
  }
  return { ...out, ...extra };
}
