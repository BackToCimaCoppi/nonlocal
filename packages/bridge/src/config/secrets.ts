import { randomBytes } from 'node:crypto';
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join, resolve as resolvePath } from 'node:path';

export const MIN_TOKEN_BYTES = 32;

export function isInsideGitRepo(targetPath: string): boolean {
  let current = resolvePath(targetPath);
  if (existsSync(current)) {
    try {
      const st = lstatSync(current);
      if (!st.isDirectory()) {
        current = dirname(current);
      }
    } catch {
      current = dirname(current);
    }
  } else {
    current = dirname(current);
  }

  while (true) {
    const gitMarker = join(current, '.git');
    if (existsSync(gitMarker)) {
      return true;
    }
    const parent = dirname(current);
    if (parent === current) {
      return false;
    }
    current = parent;
  }
}

export function assertPrivateFileTarget(targetPath: string, label: string): void {
  if (isInsideGitRepo(targetPath)) {
    throw new Error(`${label} must not be stored inside a Git repository: ${targetPath}`);
  }
}

export function readValidatedSecretFile(
  filePath: string,
  label: string,
  minBytes: number = 1
): { value: string; mode: number; length: number } {
  assertPrivateFileTarget(filePath, label);

  if (!existsSync(filePath)) {
    throw new Error(`${label} file does not exist: ${filePath}`);
  }
  const st = statSync(filePath);
  if (!st.isFile()) {
    throw new Error(`${label} path is not a regular file: ${filePath}`);
  }
  if ((st.mode & 0o077) !== 0) {
    throw new Error(
      `${label} permissions are too open (${(st.mode & 0o777).toString(8)}); run chmod 600 ${filePath}`
    );
  }

  const raw = readFileSync(filePath, 'utf8');
  const trimmed = raw.trim();
  const byteLen = Buffer.byteLength(trimmed, 'utf8');
  if (byteLen < minBytes) {
    throw new Error(`${label} is shorter than ${minBytes} bytes (${byteLen} bytes)`);
  }

  return {
    value: trimmed,
    mode: st.mode & 0o777,
    length: byteLen,
  };
}

export function generateBearerToken(): string {
  return randomBytes(32).toString('hex');
}

export function atomicWritePrivateFile(filePath: string, content: string, mode: number = 0o600): void {
  const resolved = resolvePath(filePath);
  const dir = dirname(resolved);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  try {
    chmodSync(dir, 0o700);
  } catch {
    // Ignore if dir permissions cannot be changed (e.g. /tmp root)
  }

  const tmpPath = join(dir, `.tmp.${process.pid}.${Date.now()}.${randomBytes(4).toString('hex')}`);
  try {
    writeFileSync(tmpPath, content, { encoding: 'utf8', mode });
    chmodSync(tmpPath, mode);
    renameSync(tmpPath, resolved);
    chmodSync(resolved, mode);
  } catch (err) {
    try {
      unlinkSync(tmpPath);
    } catch {
      // ignore cleanup failure
    }
    throw err;
  }
}
