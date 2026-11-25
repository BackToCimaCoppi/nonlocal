import { spawn, type ChildProcess } from 'node:child_process';
import {
  existsSync,
  lstatSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { join, resolve as resolvePath, sep } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { pathToFileURL } from 'node:url';
import { AdapterRpcError, BaseAcpAdapter, type BaseAcpAdapterOptions } from './base-acp-adapter.js';
import type {
  DeleteUpstreamOptions,
  DeleteUpstreamResult,
  UpstreamSessionInfo,
  UsageBucket,
  UsageFetchOutcome,
  UsageGroup,
} from './types.js';
import { expandHome } from '../config/paths.js';
import type { SanitizedLogger } from '../log/logger.js';

const MAX_BFS_DEPTH = 8;
const MAX_SUBAGENTS = 100;
const MAX_CLI_BUFFER_BYTES = 512 * 1024;
const SAFE_SESSION_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const AUTH_REQUIRED_RE = /(?:please\s+(?:log\s*in|sign\s*in|authenticate)|authentication\s+required|not\s+authenticated|not\s+logged\s+in|run\s+`?agy\s+login)/i;

const DELETE_RPC_ERRORS = {
  SESSION_ACTIVE: -32021,
  DB_BUSY: -32022,
  DELETE_FAILED: -32023,
} as const;

function stripAnsi(text: string): string {
  return text.replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, '');
}

function killProcessGroup(pid: number | undefined, signal: NodeJS.Signals): void {
  if (!pid || !Number.isInteger(pid) || pid <= 0) return;
  try {
    process.kill(-pid, signal);
  } catch {
    try {
      process.kill(pid, signal);
    } catch {
      // already exited
    }
  }
}

function isContainedIn(rootRealPath: string, candidatePath: string): boolean {
  const normalizedRoot = rootRealPath.endsWith(sep) ? rootRealPath.slice(0, -1) : rootRealPath;
  return candidatePath === normalizedRoot || candidatePath.startsWith(`${normalizedRoot}${sep}`);
}

function safeRealpath(targetPath: string): string | null {
  try {
    return realpathSync(targetPath);
  } catch {
    return null;
  }
}

function hasNonEmptyWal(dbPath: string): boolean {
  try {
    const walPath = `${dbPath}-wal`;
    if (!existsSync(walPath)) return false;
    return statSync(walPath).size > 0;
  } catch {
    return false;
  }
}

function openReadOnlyDb(dbPath: string, logger?: SanitizedLogger, allowMutableRead: boolean = false): DatabaseSync {
  if (allowMutableRead) {
    const db = new DatabaseSync(dbPath, { readOnly: true });
    db.exec('PRAGMA busy_timeout = 1000;');
    return db;
  }
  const immutableUri = `${pathToFileURL(dbPath).href}?immutable=1`;
  if (!hasNonEmptyWal(dbPath)) {
    return new DatabaseSync(immutableUri, { readOnly: true });
  }
  try {
    return new DatabaseSync(dbPath, { readOnly: true });
  } catch (err) {
    logger?.log('warn', 'agy_readonly_wal_fallback', {
      reason: 'readonly_open_failed_fallback_immutable',
      detail: err instanceof Error ? err.message : 'open failed',
    });
    return new DatabaseSync(immutableUri, { readOnly: true });
  }
}

function getTableColumns(db: DatabaseSync, tableName: string, strict: boolean): Set<string> {
  try {
    const rows = db.prepare(`PRAGMA table_info(${tableName})`).all() as Array<{ name?: unknown }>;
    return new Set(rows.map((r) => String(r.name || '')));
  } catch (err) {
    if (strict) throw err;
    return new Set();
  }
}

function listTableNames(db: DatabaseSync): Set<string> {
  const rows = db
    .prepare("SELECT name FROM sqlite_master WHERE type IN ('table', 'view')")
    .all() as Array<{ name?: unknown }>;
  return new Set(rows.map((r) => String(r.name || '')));
}

function readGraphFromDb(
  db: DatabaseSync,
  strict: boolean
): { titles: Map<string, string>; childrenByParent: Map<string, Set<string>> } {
  const titles = new Map<string, string>();
  const childrenByParent = new Map<string, Set<string>>();

  const tables = listTableNames(db);
  if (tables.has('conversation_summaries')) {
    const cols = getTableColumns(db, 'conversation_summaries', strict);
    const idCol = cols.has('conversation_id') ? 'conversation_id' : cols.has('id') ? 'id' : null;
    const titleCol = cols.has('title') ? 'title' : cols.has('summary') ? 'summary' : null;
    const hasParentCol = cols.has('parent_conversation_id');
    if (idCol) {
      const selectCols = [idCol];
      if (titleCol) selectCols.push(titleCol);
      if (hasParentCol) selectCols.push('parent_conversation_id');
      const rows = db
        .prepare(`SELECT ${selectCols.join(', ')} FROM conversation_summaries`)
        .all() as Array<Record<string, unknown>>;
      for (const row of rows) {
        const cid = typeof row[idCol] === 'string' ? row[idCol].trim() : '';
        if (!cid) continue;
        if (titleCol && typeof row[titleCol] === 'string' && row[titleCol].trim()) {
          titles.set(cid, row[titleCol].trim());
        }
        if (hasParentCol && typeof row.parent_conversation_id === 'string' && row.parent_conversation_id.trim()) {
          const pid = row.parent_conversation_id.trim();
          if (!childrenByParent.has(pid)) childrenByParent.set(pid, new Set());
          childrenByParent.get(pid)!.add(cid);
        }
      }
    }
  }

  if (tables.has('conversation_parents')) {
    const parentCols = getTableColumns(db, 'conversation_parents', strict);
    if (parentCols.has('conversation_id') && parentCols.has('parent_id')) {
      const pRows = db
        .prepare('SELECT conversation_id, parent_id FROM conversation_parents')
        .all() as Array<{ conversation_id?: unknown; parent_id?: unknown }>;
      for (const row of pRows) {
        const cid = typeof row.conversation_id === 'string' ? row.conversation_id.trim() : '';
        const pid = typeof row.parent_id === 'string' ? row.parent_id.trim() : '';
        if (!cid || !pid) continue;
        if (!childrenByParent.has(pid)) childrenByParent.set(pid, new Set());
        childrenByParent.get(pid)!.add(cid);
      }
    }
  }

  return { titles, childrenByParent };
}

function collectBfsSubagents(
  sessionId: string,
  childrenByParent: Map<string, Set<string>>,
  titles: Map<string, string>
): Array<{ sessionId: string; upstreamTitle: string | null; depth: number }> {
  const visited = new Set<string>([sessionId]);
  const queue: Array<{ id: string; depth: number }> = [{ id: sessionId, depth: 0 }];
  const subagents: Array<{ sessionId: string; upstreamTitle: string | null; depth: number }> = [];

  while (queue.length > 0 && subagents.length < MAX_SUBAGENTS) {
    const current = queue.shift()!;
    if (current.depth >= MAX_BFS_DEPTH) continue;
    const children = childrenByParent.get(current.id);
    if (!children || children.size === 0) continue;
    for (const childId of Array.from(children).sort()) {
      if (visited.has(childId) || childId.startsWith('agy-p-')) continue;
      visited.add(childId);
      const nextDepth = current.depth + 1;
      subagents.push({
        sessionId: childId,
        upstreamTitle: titles.get(childId) ?? null,
        depth: nextDepth,
      });
      if (subagents.length >= MAX_SUBAGENTS) break;
      if (nextDepth < MAX_BFS_DEPTH) {
        queue.push({ id: childId, depth: nextDepth });
      }
    }
  }
  return subagents;
}

function assertSubdirContained(rootRealPath: string, dataDir: string, subdirName: string): string | null {
  const subdirPath = join(dataDir, subdirName);
  let st;
  try {
    st = lstatSync(subdirPath);
  } catch (err) {
    if ((err as NodeJS.ErrnoException)?.code === 'ENOENT') return null;
    throw err;
  }
  if (st.isSymbolicLink()) {
    throw new AdapterRpcError(DELETE_RPC_ERRORS.DELETE_FAILED, `Symlinked directory not permitted: ${subdirName}`);
  }
  const realSub = realpathSync(subdirPath);
  if (!isContainedIn(rootRealPath, realSub)) {
    throw new AdapterRpcError(DELETE_RPC_ERRORS.DELETE_FAILED, `Symlink escape detected in ${subdirName}`);
  }
  return st.isDirectory() ? subdirPath : null;
}

function safeRemoveTarget(targetPath: string, recursive: boolean = false): boolean {
  let st;
  try {
    st = lstatSync(targetPath);
  } catch (err) {
    if ((err as NodeJS.ErrnoException)?.code === 'ENOENT') return false;
    throw err;
  }
  if (st.isSymbolicLink()) {
    unlinkSync(targetPath);
    return true;
  }
  if (st.isDirectory()) {
    if (!recursive) {
      throw new AdapterRpcError(DELETE_RPC_ERRORS.DELETE_FAILED, 'Unexpected directory at target');
    }
    rmSync(targetPath, { recursive: true, force: false });
    return true;
  }
  unlinkSync(targetPath);
  return true;
}

function deleteIdsFromSummariesDb(db: DatabaseSync, targetIds: string[]): void {
  if (targetIds.length === 0) return;
  const tables = listTableNames(db);
  const placeholders = targetIds.map(() => '?').join(', ');

  if (tables.has('conversation_summaries')) {
    const cols = getTableColumns(db, 'conversation_summaries', true);
    const idCol = cols.has('conversation_id') ? 'conversation_id' : cols.has('id') ? 'id' : null;
    if (idCol) {
      db.prepare(`DELETE FROM conversation_summaries WHERE ${idCol} IN (${placeholders})`).run(...targetIds);
    }
  }

  if (tables.has('conversation_parents')) {
    const cols = getTableColumns(db, 'conversation_parents', true);
    if (cols.has('conversation_id') && cols.has('parent_id')) {
      db.prepare(
        `DELETE FROM conversation_parents WHERE conversation_id IN (${placeholders}) OR parent_id IN (${placeholders})`
      ).run(...targetIds, ...targetIds);
    } else if (cols.has('conversation_id')) {
      db.prepare(`DELETE FROM conversation_parents WHERE conversation_id IN (${placeholders})`).run(...targetIds);
    }
  }

  if (tables.has('conversations_fts')) {
    const cols = getTableColumns(db, 'conversations_fts', true);
    const ftsIdCol = cols.has('conversation_id') ? 'conversation_id' : cols.has('id') ? 'id' : null;
    if (ftsIdCol) {
      db.prepare(`DELETE FROM conversations_fts WHERE ${ftsIdCol} IN (${placeholders})`).run(...targetIds);
    }
  }
}

function atomicWriteJson(filePath: string, data: unknown): void {
  const tmpPath = `${filePath}.tmp.${process.pid}.${Date.now()}.${Math.random().toString(16).slice(2, 8)}`;
  try {
    writeFileSync(tmpPath, `${JSON.stringify(data, null, 2)}\n`, 'utf8');
    renameSync(tmpPath, filePath);
  } catch (err) {
    try {
      unlinkSync(tmpPath);
    } catch {
      // ignore
    }
    throw err;
  }
}

function isSqliteBusyError(err: unknown): boolean {
  if (!err || typeof err !== 'object') return false;
  const rec = err as { errcode?: unknown; code?: unknown; message?: unknown };
  const code = String(rec.errcode ?? rec.code ?? '');
  const msg = String(rec.message ?? '').toLowerCase();
  return (
    code === '5' ||
    code === '6' ||
    code === 'SQLITE_BUSY' ||
    code === 'SQLITE_LOCKED' ||
    msg.includes('database is locked') ||
    msg.includes('database is busy') ||
    msg.includes('database table is locked')
  );
}

function normalizeBucketWindow(rawWindow: unknown, bucketName: string, bucketId: string): string {
  const w = typeof rawWindow === 'string' ? rawWindow.trim() : '';
  const hint = `${w} ${bucketName} ${bucketId}`.toLowerCase();
  if (hint.includes('week') || hint.includes('7d')) return 'weekly';
  if (hint.includes('5h') || hint.includes('5 hour') || hint.includes('5-hour')) return '5h';
  return w || '5h';
}

function normalizeRemainingFraction(raw: unknown): number | null {
  if (typeof raw === 'number' && Number.isFinite(raw)) {
    if (raw > 1 && raw <= 100) return Math.max(0, Math.min(1, raw / 100));
    return Math.max(0, Math.min(1, raw));
  }
  if (typeof raw === 'string' && raw.trim()) {
    const num = Number(raw.trim());
    if (Number.isFinite(num)) {
      if (num > 1 && num <= 100) return Math.max(0, Math.min(1, num / 100));
      return Math.max(0, Math.min(1, num));
    }
  }
  return null;
}

export function parseUsageCliJson(stdoutText: string): { groups: UsageGroup[] } | null {
  const cleaned = stripAnsi(String(stdoutText ?? '')).trim();
  if (!cleaned) return null;
  let parsed: Record<string, unknown> | null = null;
  try {
    parsed = JSON.parse(cleaned) as Record<string, unknown>;
  } catch {
    const lines = cleaned.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    for (let i = lines.length - 1; i >= 0; i--) {
      if (lines[i].startsWith('{')) {
        try {
          parsed = JSON.parse(lines[i]) as Record<string, unknown>;
          break;
        } catch {
          // continue
        }
      }
    }
  }
  if (!parsed || typeof parsed !== 'object') return null;

  const rawGroups =
    ((parsed.command as { data?: { groups?: unknown } } | undefined)?.data?.groups ??
      (parsed.data as { groups?: unknown } | undefined)?.groups ??
      parsed.groups) as unknown;
  if (!Array.isArray(rawGroups)) return null;

  const groups: UsageGroup[] = [];
  for (const g of rawGroups) {
    if (!g || typeof g !== 'object') continue;
    const gObj = g as Record<string, unknown>;
    const name = typeof gObj.name === 'string' && gObj.name.trim() ? gObj.name.trim() : null;
    if (!name) continue;
    const rawBuckets = Array.isArray(gObj.buckets) ? gObj.buckets : [];
    const buckets: UsageBucket[] = [];
    for (let idx = 0; idx < rawBuckets.length; idx++) {
      const b = rawBuckets[idx];
      if (!b || typeof b !== 'object') continue;
      const bObj = b as Record<string, unknown>;
      const frac = normalizeRemainingFraction(
        bObj.remaining_fraction ?? bObj.remainingFraction ?? bObj.remaining ?? bObj.percentRemaining
      );
      if (frac === null) continue;
      const bId =
        typeof bObj.id === 'string' && bObj.id.trim()
          ? bObj.id.trim()
          : `${name.toLowerCase().replace(/[^a-z0-9]+/g, '_')}_${idx}`;
      const bName = typeof bObj.name === 'string' && bObj.name.trim() ? bObj.name.trim() : bId;
      const bucket: UsageBucket = {
        id: bId,
        name: bName,
        window: normalizeBucketWindow(bObj.window, bName, bId),
        remainingFraction: frac,
        ...(typeof (bObj.reset_time ?? bObj.resetTime) === 'string' &&
        String(bObj.reset_time ?? bObj.resetTime).trim()
          ? { resetTime: String(bObj.reset_time ?? bObj.resetTime).trim() }
          : {}),
      };
      buckets.push(bucket);
    }
    const groupObj: UsageGroup = {
      name,
      buckets,
      ...(typeof gObj.description === 'string' && gObj.description.trim()
        ? { description: gObj.description.trim() }
        : {}),
    };
    groups.push(groupObj);
  }
  return { groups };
}

function makeSanitizedUsageError(code: string, failedAt: string) {
  const safeMessages: Record<string, string> = {
    timeout: 'Usage query timed out',
    auth_required: 'Authentication required before querying usage',
    parse_error: 'Failed parsing structured usage output',
    cli_failed: 'Failed running upstream usage command',
  };
  return {
    code,
    message: safeMessages[code] || safeMessages.cli_failed,
    failedAt,
  };
}

export class AntigravityAdapter extends BaseAcpAdapter {
  private readonly dataDirs: string[];
  private readonly usageTimeoutMs: number;
  private readonly activeUsageChildren = new Set<ChildProcess>();
  private usageInFlight: Promise<UsageFetchOutcome> | null = null;

  constructor(opts: BaseAcpAdapterOptions) {
    const ag = opts.adapterConfig.antigravity;
    const dirs = ag.disableDataDirs
      ? []
      : Array.from(new Set(ag.dataDirs.map((d) => resolvePath(expandHome(d))).filter(Boolean)));
    const hasDisk = dirs.length > 0;

    super(opts, 'antigravity', {
      usage: true,
      sessionInfo: true,
      deleteSession: true,
      diskPresence: hasDisk,
    });

    this.dataDirs = dirs;
    this.usageTimeoutMs = Math.max(50, ag.usageTimeoutMs || 15_000);
  }

  protected override getCommandAndArgs(): { command: string; args: string[] } {
    const cmd = this.adapterConfig.command.trim() || 'agy';
    const args = this.adapterConfig.args.length > 0 ? [...this.adapterConfig.args] : ['acp'];
    return { command: cmd, args };
  }

  protected override onUpstreamMessageHook(msg: Record<string, unknown>): void {
    const result = msg.result as { _meta?: { antigravity?: { tier?: unknown } } } | undefined;
    const tier = result?._meta?.antigravity?.tier;
    if (tier && typeof tier === 'object' && !Array.isArray(tier)) {
      const tObj = tier as { name?: unknown; id?: unknown };
      if (typeof tObj.name === 'boolean' || typeof tObj.id === 'boolean') return;
      const name = typeof tObj.name === 'string' && tObj.name.trim() ? tObj.name.trim() : undefined;
      const id = typeof tObj.id === 'string' && tObj.id.trim() ? tObj.id.trim() : undefined;
      if (name || id) {
        this.host.onUsageTierObserved({ ...(name ? { name } : {}), ...(id ? { id } : {}) });
      }
    }
  }

  // Block 2: Usage CLI runner (single-flight, -pid cleanup, zero stdout/stderr leak)
  async fetchUsage(): Promise<UsageFetchOutcome> {
    if (this.usageInFlight) {
      return this.usageInFlight;
    }
    this.usageInFlight = this.runUsageOnce().finally(() => {
      this.usageInFlight = null;
    });
    return this.usageInFlight;
  }

  abortUsage(): void {
    for (const child of Array.from(this.activeUsageChildren)) {
      killProcessGroup(child.pid, 'SIGTERM');
      const pid = child.pid;
      setTimeout(() => {
        if (child.exitCode === null && child.signalCode === null) {
          killProcessGroup(pid, 'SIGKILL');
        }
      }, 50).unref?.();
    }
    this.activeUsageChildren.clear();
  }

  private runUsageOnce(): Promise<UsageFetchOutcome> {
    return new Promise((resolve) => {
      const startedAt = Date.now();
      let settled = false;
      let stdoutBuf = '';
      let stderrBuf = '';
      let child: ChildProcess;

      const agyBin = this.adapterConfig.command.trim() || 'agy';
      const fallbackCwd = existsSync(this.adapterConfig.fallbackCwd) ? this.adapterConfig.fallbackCwd : process.cwd();

      try {
        child = spawn(agyBin, ['-p', '/usage', '--output-format', 'json'], {
          cwd: fallbackCwd,
          detached: true,
          stdio: ['ignore', 'pipe', 'pipe'],
          env: this.getSpawnEnv(),
        });
      } catch {
        const failedAt = new Date().toISOString();
        this.logger.log('warn', 'usage_cli_done', { errorCode: 'cli_failed', durationMs: Date.now() - startedAt });
        resolve({ ok: false, error: makeSanitizedUsageError('cli_failed', failedAt) });
        return;
      }

      this.activeUsageChildren.add(child);
      const finish = (outcome: UsageFetchOutcome) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeoutTimer);
        this.activeUsageChildren.delete(child);
        resolve(outcome);
      };

      const terminateChild = (forceDelayMs: number = 100) => {
        if (child.exitCode !== null || child.signalCode !== null) return;
        killProcessGroup(child.pid, 'SIGTERM');
        setTimeout(() => {
          if (child.exitCode === null && child.signalCode === null) {
            killProcessGroup(child.pid, 'SIGKILL');
          }
        }, forceDelayMs).unref?.();
      };

      const timeoutTimer = setTimeout(() => {
        terminateChild(100);
        const failedAt = new Date().toISOString();
        this.logger.log('warn', 'usage_cli_done', { errorCode: 'timeout', durationMs: Date.now() - startedAt });
        finish({ ok: false, error: makeSanitizedUsageError('timeout', failedAt) });
      }, this.usageTimeoutMs);
      timeoutTimer.unref?.();

      const checkAuthPrompt = (extra: string) => {
        if (settled) return;
        const combined = stripAnsi(`${stdoutBuf}\n${stderrBuf}\n${extra}`);
        if (AUTH_REQUIRED_RE.test(combined)) {
          terminateChild(100);
          const failedAt = new Date().toISOString();
          this.logger.log('warn', 'usage_cli_done', {
            errorCode: 'auth_required',
            durationMs: Date.now() - startedAt,
          });
          finish({ ok: false, error: makeSanitizedUsageError('auth_required', failedAt) });
        }
      };

      child.stdout?.on('data', (chunk: Buffer) => {
        const str = chunk.toString('utf8');
        if (Buffer.byteLength(stdoutBuf, 'utf8') < MAX_CLI_BUFFER_BYTES) stdoutBuf += str;
        checkAuthPrompt(str);
      });

      child.stderr?.on('data', (chunk: Buffer) => {
        const str = chunk.toString('utf8');
        if (Buffer.byteLength(stderrBuf, 'utf8') < MAX_CLI_BUFFER_BYTES) stderrBuf += str;
        checkAuthPrompt(str);
      });

      child.on('error', () => {
        const failedAt = new Date().toISOString();
        this.logger.log('warn', 'usage_cli_done', { errorCode: 'cli_failed', durationMs: Date.now() - startedAt });
        finish({ ok: false, error: makeSanitizedUsageError('cli_failed', failedAt) });
      });

      child.on('close', (code) => {
        if (settled) return;
        const parsed = parseUsageCliJson(stdoutBuf);
        if (parsed && parsed.groups.length >= 0 && code === 0) {
          this.logger.log('info', 'usage_cli_done', {
            count: parsed.groups.length,
            durationMs: Date.now() - startedAt,
          });
          finish({
            ok: true,
            fetchedAt: new Date().toISOString(),
            groups: parsed.groups,
          });
          return;
        }
        const errCode = AUTH_REQUIRED_RE.test(stripAnsi(`${stdoutBuf}\n${stderrBuf}`))
          ? 'auth_required'
          : code === 0
            ? 'parse_error'
            : 'cli_failed';
        const failedAt = new Date().toISOString();
        this.logger.log('warn', 'usage_cli_done', {
          code: code ?? undefined,
          errorCode: errCode,
          durationMs: Date.now() - startedAt,
        });
        finish({ ok: false, error: makeSanitizedUsageError(errCode, failedAt) });
      });
    });
  }

  // Block 3: Read-only conversation_summaries.db reader + disk presence check
  override checkSessionDiskPresence(sessionId: string): boolean {
    if (!this.isSafeSessionId(sessionId) || this.dataDirs.length === 0) return false;
    for (const dir of this.dataDirs) {
      const candidates = [
        join(dir, 'conversations', `${sessionId}.pb`),
        join(dir, 'conversations', `${sessionId}.db`),
      ];
      if (candidates.some((p) => existsSync(p))) {
        return true;
      }
      const dbPath = join(dir, 'conversation_summaries.db');
      if (existsSync(dbPath)) {
        let db: DatabaseSync | null = null;
        try {
          db = openReadOnlyDb(dbPath, this.logger, false);
          const { titles, childrenByParent } = readGraphFromDb(db, false);
          if (titles.has(sessionId) || childrenByParent.has(sessionId)) {
            return true;
          }
          for (const kids of childrenByParent.values()) {
            if (kids.has(sessionId)) return true;
          }
        } catch {
          // ignore unreadable db
        } finally {
          try {
            db?.close();
          } catch {
            // ignore
          }
        }
      }
    }
    return false;
  }

  readSessionInfo(sessionId: string, opts: { strict?: boolean } = {}): UpstreamSessionInfo {
    const strict = Boolean(opts.strict);
    const mergedTitles = new Map<string, string>();
    const mergedChildren = new Map<string, Set<string>>();

    for (const dir of this.dataDirs) {
      const dbPath = join(dir, 'conversation_summaries.db');
      if (!existsSync(dbPath)) continue;
      let db: DatabaseSync | null = null;
      try {
        db = openReadOnlyDb(dbPath, this.logger, false);
        const { titles, childrenByParent } = readGraphFromDb(db, strict);
        for (const [k, v] of titles.entries()) {
          if (!mergedTitles.has(k)) mergedTitles.set(k, v);
        }
        for (const [pid, kids] of childrenByParent.entries()) {
          if (!mergedChildren.has(pid)) mergedChildren.set(pid, new Set());
          const bucket = mergedChildren.get(pid)!;
          for (const k of kids) bucket.add(k);
        }
      } catch (err) {
        if (strict) {
          throw new AdapterRpcError(
            DELETE_RPC_ERRORS.DELETE_FAILED,
            `Failed inspecting session metadata: ${err instanceof Error ? err.message : 'unknown'}`
          );
        }
      } finally {
        try {
          db?.close();
        } catch {
          // ignore
        }
      }
    }

    return {
      upstreamTitle: mergedTitles.get(sessionId) ?? null,
      subagents: collectBfsSubagents(sessionId, mergedChildren, mergedTitles),
    };
  }

  isSafeSessionId(sessionId: string): boolean {
    if (typeof sessionId !== 'string') return false;
    if (!SAFE_SESSION_ID_RE.test(sessionId)) return false;
    if (sessionId === '.' || sessionId === '..' || sessionId.includes('..')) return false;
    return true;
  }

  // Block 4: Multi-DB atomic cascade delete & cache cleanup
  cleanUpstreamCacheEntries(sessionIds: string[]): string[] {
    const warnings: string[] = [];
    const safeIds = sessionIds.filter((id) => this.isSafeSessionId(id));
    if (safeIds.length === 0) return warnings;
    const idSet = new Set(safeIds);

    for (const dir of this.dataDirs) {
      const realRoot = safeRealpath(dir);
      if (!realRoot) continue;
      let cacheDir: string | null = null;
      try {
        cacheDir = assertSubdirContained(realRoot, dir, 'cache');
      } catch (err) {
        warnings.push(`cache dir skipped: ${err instanceof Error ? err.message : 'invalid'}`);
        continue;
      }
      if (!cacheDir) continue;

      const metaPath = join(cacheDir, 'conversation_metadata.json');
      if (existsSync(metaPath)) {
        try {
          const st = lstatSync(metaPath);
          if (!st.isSymbolicLink() && st.isFile()) {
            const parsed = JSON.parse(readFileSync(metaPath, 'utf8')) as {
              conversations?: Record<string, unknown>;
            };
            if (parsed?.conversations && typeof parsed.conversations === 'object') {
              let changed = false;
              for (const id of safeIds) {
                if (Object.hasOwn(parsed.conversations, id)) {
                  delete parsed.conversations[id];
                  changed = true;
                }
              }
              if (changed) atomicWriteJson(metaPath, parsed);
            }
          }
        } catch {
          warnings.push('cache/conversation_metadata.json cleanup failed');
        }
      }

      const lastPath = join(cacheDir, 'last_conversations.json');
      if (existsSync(lastPath)) {
        try {
          const st = lstatSync(lastPath);
          if (!st.isSymbolicLink() && st.isFile()) {
            const parsed = JSON.parse(readFileSync(lastPath, 'utf8')) as Record<string, unknown>;
            if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
              let changed = false;
              for (const [k, v] of Object.entries(parsed)) {
                if (typeof v === 'string' && idSet.has(v)) {
                  delete parsed[k];
                  changed = true;
                }
              }
              if (changed) atomicWriteJson(lastPath, parsed);
            }
          }
        } catch {
          warnings.push('cache/last_conversations.json cleanup failed');
        }
      }
    }

    return warnings;
  }

  deleteUpstreamSession(sessionId: string, opts: DeleteUpstreamOptions): DeleteUpstreamResult {
    if (!this.isSafeSessionId(sessionId)) {
      throw new AdapterRpcError(-32602, 'Invalid params: sessionId contains forbidden path characters');
    }

    // Pre-validate containment before opening write transactions so symlink escapes never mutate DBs
    for (const dir of this.dataDirs) {
      const realRoot = safeRealpath(dir);
      if (!realRoot) continue;
      for (const sub of ['brain', 'conversations', 'annotations', 'presence', 'cache']) {
        assertSubdirContained(realRoot, dir, sub);
      }
    }

    const safeExtraSubagents = (opts.pendingSubagentIds ?? []).filter(
      (id) => this.isSafeSessionId(id) && id !== sessionId
    );
    const dbPaths = this.dataDirs
      .map((dir) => join(dir, 'conversation_summaries.db'))
      .filter((p) => existsSync(p));

    const openHandles: Array<{ db: DatabaseSync; inTx: boolean }> = [];
    let allSubagentIds: string[] = [];

    try {
      for (const dbPath of dbPaths) {
        const db = new DatabaseSync(dbPath);
        db.exec('PRAGMA busy_timeout = 1000;');
        openHandles.push({ db, inTx: false });
      }

      for (const h of openHandles) {
        h.db.exec('BEGIN IMMEDIATE');
        h.inTx = true;
      }

      const mergedTitles = new Map<string, string>();
      const mergedChildren = new Map<string, Set<string>>();
      for (const h of openHandles) {
        const { titles, childrenByParent } = readGraphFromDb(h.db, true);
        for (const [k, v] of titles.entries()) {
          if (!mergedTitles.has(k)) mergedTitles.set(k, v);
        }
        for (const [pid, kids] of childrenByParent.entries()) {
          if (!mergedChildren.has(pid)) mergedChildren.set(pid, new Set());
          const bucket = mergedChildren.get(pid)!;
          for (const k of kids) bucket.add(k);
        }
      }

      const lockedSubagents = collectBfsSubagents(sessionId, mergedChildren, mergedTitles)
        .map((s) => s.sessionId)
        .filter((id) => this.isSafeSessionId(id) && id !== sessionId);

      allSubagentIds = Array.from(new Set([...safeExtraSubagents, ...lockedSubagents]));
      const allTargets = [...allSubagentIds, sessionId];

      for (const tid of allTargets) {
        if (opts.isSessionProtected(tid)) {
          throw new AdapterRpcError(
            DELETE_RPC_ERRORS.SESSION_ACTIVE,
            'Session or subagent is active or awaiting approval'
          );
        }
      }

      const hadDbPresence = allTargets.some(
        (tid) => mergedTitles.has(tid) || mergedChildren.has(tid) || Array.from(mergedChildren.values()).some((s) => s.has(tid))
      );

      opts.onResolvedSubagents?.(allSubagentIds);

      for (const h of openHandles) {
        deleteIdsFromSummariesDb(h.db, allTargets);
      }

      for (const h of openHandles) {
        h.db.exec('COMMIT');
        h.inTx = false;
      }

      const diskExistsBefore = this.dataDirs.some((dir) =>
        allTargets.some(
          (tid) =>
            existsSync(join(dir, 'brain', tid)) ||
            existsSync(join(dir, 'conversations', `${tid}.pb`)) ||
            existsSync(join(dir, 'conversations', `${tid}.db`))
        )
      );

      // Phase 2: Core disk deletion — subagents first, main session last
      for (const tid of allTargets) {
        for (const dir of this.dataDirs) {
          const realRoot = safeRealpath(dir);
          if (!realRoot) continue;
          const brainDir = assertSubdirContained(realRoot, dir, 'brain');
          if (brainDir) {
            safeRemoveTarget(join(brainDir, tid), true);
          }
          const convDir = assertSubdirContained(realRoot, dir, 'conversations');
          if (convDir) {
            for (const f of [`${tid}.pb-wal`, `${tid}.pb-shm`, `${tid}.db-wal`, `${tid}.db-shm`, `${tid}.db`, `${tid}.pb`]) {
              safeRemoveTarget(join(convDir, f), false);
            }
          }
        }
      }

      // Phase 3: Auxiliary best-effort cleanup
      const warnings: string[] = [];
      for (const tid of allTargets) {
        for (const dir of this.dataDirs) {
          const realRoot = safeRealpath(dir);
          if (!realRoot) continue;
          for (const [sub, file] of [
            ['annotations', `${tid}.pbtxt`],
            ['presence', `${tid}.lock`],
          ] as const) {
            try {
              const subDir = assertSubdirContained(realRoot, dir, sub);
              if (subDir) safeRemoveTarget(join(subDir, file), false);
            } catch {
              warnings.push(`${sub}/${file} cleanup failed`);
            }
          }
        }
      }
      warnings.push(...this.cleanUpstreamCacheEntries(allTargets));

      const alreadyAbsent = !hadDbPresence && !diskExistsBefore;
      return {
        sessionId,
        deleted: true,
        alreadyAbsent,
        deletedSubagentIds: allSubagentIds,
        deletedSubagentCount: allSubagentIds.length,
        warnings,
      };
    } catch (err) {
      for (const h of openHandles) {
        if (h.inTx) {
          try {
            h.db.exec('ROLLBACK');
          } catch {
            // ignore
          }
          h.inTx = false;
        }
      }
      if (err instanceof AdapterRpcError) {
        throw err;
      }
      if (isSqliteBusyError(err)) {
        this.logger.log('warn', 'session_delete_db_busy', { sessionId });
        throw new AdapterRpcError(DELETE_RPC_ERRORS.DB_BUSY, 'Host conversation database is busy; please retry');
      }
      throw new AdapterRpcError(
        DELETE_RPC_ERRORS.DELETE_FAILED,
        `Failed deleting upstream session: ${err instanceof Error ? err.message : 'unknown error'}`
      );
    } finally {
      for (const h of openHandles) {
        try {
          h.db.close();
        } catch {
          // ignore
        }
      }
    }
  }
}
