import {
  appendFileSync,
  chmodSync,
  existsSync,
  mkdirSync,
  renameSync,
  statSync,
  unlinkSync,
} from 'node:fs';
import { dirname } from 'node:path';

export const DEFAULT_LOG_MAX_BYTES = 10 * 1024 * 1024;
export const DEFAULT_LOG_MAX_BACKUPS = 3;

export const ALLOWED_LOG_KEYS = new Set([
  'connId',
  'originConnId',
  'activeConnId',
  'method',
  'updateType',
  'clientId',
  'upstreamId',
  'sessionId',
  'workerId',
  'workerSeq',
  'draining',
  'model',
  'code',
  'errorCode',
  'durationMs',
  'bytes',
  'reason',
  'host',
  'port',
  'childPid',
  'instanceId',
  'turnId',
  'seq',
  'count',
  'truncated',
  'kind',
  'detail',
  'alreadyAbsent',
  'deletedSubagentCount',
  'message',
  'clientKey',
  'warningLevel',
  'listenAddresses',
]);

export function sanitizeLogText(
  value: unknown,
  redactSecrets: readonly string[] = [],
  maxLen: number = 240
): string {
  let text = String(value ?? '').replace(/[\r\n\t]+/g, ' ');
  for (const secret of redactSecrets) {
    if (typeof secret === 'string' && secret.length >= 4) {
      text = text.split(secret).join('[REDACTED]');
    }
  }
  text = text.replace(
    /((?:proxy-)?authorization\s*[:=]\s*["']?)(?:(bearer|basic)\s+)?([^\s"',}]+)/gi,
    (_, prefix: string, scheme?: string) => (scheme ? `${prefix}${scheme} [REDACTED]` : `${prefix}[REDACTED]`)
  );
  text = text.replace(/Bearer[ \t]+(?!\[REDACTED\])[^\s"',}]+/gi, 'Bearer [REDACTED]');
  text = text.replace(/(\b(?:access_)?token=|\bsecret=|\bapi_?key=)[^&\s"',}]+/gi, '$1[REDACTED]');
  if (text.length > maxLen) {
    return `${text.slice(0, maxLen)}...`;
  }
  return text;
}

export interface LoggerOptions {
  logFile: string;
  maxBytes?: number;
  maxBackups?: number;
  redactSecrets?: string[];
}

export class SanitizedLogger {
  readonly logFile: string;
  readonly maxBytes: number;
  readonly maxBackups: number;
  private readonly secrets: string[];

  constructor(opts: LoggerOptions) {
    if (!opts.logFile) {
      throw new TypeError('logFile is required');
    }
    this.logFile = opts.logFile;
    this.maxBytes = Math.max(256, Number(opts.maxBytes) || DEFAULT_LOG_MAX_BYTES);
    this.maxBackups = Math.max(0, Math.floor(Number(opts.maxBackups ?? DEFAULT_LOG_MAX_BACKUPS)));
    this.secrets = Array.isArray(opts.redactSecrets)
      ? opts.redactSecrets.filter((s): s is string => typeof s === 'string' && s.length >= 4)
      : [];
    mkdirSync(dirname(this.logFile), { recursive: true, mode: 0o700 });
  }

  registerSecret(secret: string | undefined | null): void {
    if (typeof secret === 'string' && secret.length >= 4 && !this.secrets.includes(secret)) {
      this.secrets.push(secret);
    }
  }

  private currentFileSize(): number {
    try {
      return statSync(this.logFile).size;
    } catch {
      return 0;
    }
  }

  private rotateFiles(): void {
    if (this.maxBackups === 0) {
      try {
        unlinkSync(this.logFile);
      } catch {
        // ignore missing
      }
      return;
    }
    const oldest = `${this.logFile}.${this.maxBackups}`;
    if (existsSync(oldest)) {
      try {
        unlinkSync(oldest);
      } catch {
        // ignore
      }
    }
    for (let i = this.maxBackups - 1; i >= 1; i--) {
      const src = `${this.logFile}.${i}`;
      const dst = `${this.logFile}.${i + 1}`;
      if (existsSync(src)) {
        renameSync(src, dst);
        try {
          chmodSync(dst, 0o600);
        } catch {
          // ignore
        }
      }
    }
    if (existsSync(this.logFile)) {
      const dst = `${this.logFile}.1`;
      renameSync(this.logFile, dst);
      try {
        chmodSync(dst, 0o600);
      } catch {
        // ignore
      }
    }
  }

  private sanitizeField(key: string, val: unknown): unknown {
    if (val === undefined || val === null) return undefined;
    if (typeof val === 'number' || typeof val === 'boolean') return val;
    if (Array.isArray(val)) {
      return val.map((item) => sanitizeLogText(item, this.secrets, 96));
    }
    const maxLen = key === 'detail' || key === 'message' ? 240 : 128;
    return sanitizeLogText(val, this.secrets, maxLen);
  }

  log(level: string, event: string, fields: Record<string, unknown> = {}): void {
    const entry: Record<string, unknown> = {
      ts: new Date().toISOString(),
      level: sanitizeLogText(level || 'info', this.secrets, 16),
      event: sanitizeLogText(event || 'unknown', this.secrets, 64),
    };

    if (fields && typeof fields === 'object') {
      for (const [key, val] of Object.entries(fields)) {
        if (!ALLOWED_LOG_KEYS.has(key)) continue;
        const safeVal = this.sanitizeField(key, val);
        if (safeVal !== undefined) {
          entry[key] = safeVal;
        }
      }
    }

    const line = JSON.stringify(entry) + '\n';
    const lineBytes = Buffer.byteLength(line, 'utf8');
    const size = this.currentFileSize();
    if (size > 0 && size + lineBytes > this.maxBytes) {
      this.rotateFiles();
    }
    appendFileSync(this.logFile, line, { encoding: 'utf8', mode: 0o600 });
    try {
      chmodSync(this.logFile, 0o600);
    } catch {
      // ignore
    }
  }
}
