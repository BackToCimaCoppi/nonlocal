import { spawn, type ChildProcessByStdio } from 'node:child_process';
import { existsSync, realpathSync, statSync } from 'node:fs';
import { resolve as resolvePath } from 'node:path';
import type { Readable, Writable } from 'node:stream';
import type {
  AdapterCapabilities,
  AdapterDispatchRequest,
  AdapterHostContext,
  AgentAdapter,
  SavedSessionSnapshot,
} from './types.js';
import type { AdapterConfig, SyncConfig } from '../config/types.js';
import { expandHome } from '../config/paths.js';
import type { SanitizedLogger } from '../log/logger.js';

const MAX_SETTIME_CHUNK_MS = 2_147_483_647;
const DEFAULT_RESTORE_STEP_TIMEOUT_MS = 10_000;
const MAX_BUFFER_FALLBACK_FLUSH_BYTES = 16 * 1024 * 1024;
const IGNORED_PROBE_SESSION_IDS = new Set(['capability-probe']);

export interface LongTimeoutHandle {
  cancel(): void;
}

export function scheduleLongTimeout(
  fn: () => void,
  delayMs: number,
  setTimeoutFn: typeof setTimeout = setTimeout,
  clearTimeoutFn: typeof clearTimeout = clearTimeout
): LongTimeoutHandle {
  let cancelled = false;
  let activeTimer: ReturnType<typeof setTimeout> | null = null;
  let remaining = Math.max(0, Math.floor(delayMs));

  const armNext = () => {
    if (cancelled) return;
    const chunk = Math.min(remaining, MAX_SETTIME_CHUNK_MS);
    remaining -= chunk;
    activeTimer = setTimeoutFn(() => {
      activeTimer = null;
      if (cancelled) return;
      if (remaining > 0) {
        armNext();
      } else {
        fn();
      }
    }, chunk);
    activeTimer?.unref?.();
  };

  armNext();
  return {
    cancel() {
      cancelled = true;
      if (activeTimer !== null) {
        clearTimeoutFn(activeTimer);
        activeTimer = null;
      }
    },
  };
}

export class AdapterRpcError extends Error {
  readonly rpcCode: number;
  readonly sessionMissingOnWake?: boolean;
  constructor(rpcCode: number, message: string, opts?: { sessionMissingOnWake?: boolean }) {
    super(message);
    this.name = 'AdapterRpcError';
    this.rpcCode = rpcCode;
    this.sessionMissingOnWake = opts?.sessionMissingOnWake;
  }
}

export function canonicalizeDirectory(rawCwd: unknown): { ok: true; cwd: string } | { ok: false; message: string } {
  if (typeof rawCwd !== 'string' || !rawCwd.trim()) {
    return { ok: false, message: 'Invalid params: cwd must be a non-empty directory path' };
  }
  const expanded = resolvePath(expandHome(rawCwd.trim()));
  try {
    const st = statSync(expanded);
    if (!st.isDirectory()) {
      return { ok: false, message: 'Invalid params: cwd is not a directory' };
    }
    return { ok: true, cwd: realpathSync(expanded) };
  } catch {
    return { ok: false, message: 'Invalid params: cwd directory does not exist' };
  }
}

export function isLoadReplayConfigNoise(msg: Record<string, unknown>): boolean {
  if (!msg || typeof msg !== 'object') return false;
  if (msg.method !== 'session/update') return false;
  const params = msg.params as { update?: Record<string, unknown> } | undefined;
  const update = params?.update;
  if (!update || typeof update !== 'object') return false;
  const uType = update.sessionUpdate ?? update.type;
  return uType === 'config_option_update' || uType === 'current_mode_update';
}

export function extractModelFamilyFromId(
  modelId: string,
  configOptions?: unknown[]
): { family: string; thoughtLevel: string } {
  const options = Array.isArray(configOptions)
    ? ((configOptions.find(
        (c) => c && typeof c === 'object' && (c as Record<string, unknown>).id === 'model'
      ) as { options?: Array<{ value?: unknown }> } | undefined)?.options ?? [])
    : [];

  let matchedFamily = '';
  for (const opt of options) {
    const val = typeof opt?.value === 'string' ? opt.value.trim() : '';
    if (!val) continue;
    if (modelId === val || modelId.startsWith(`${val}-`)) {
      if (val.length > matchedFamily.length) {
        matchedFamily = val;
      }
    }
  }
  if (matchedFamily) {
    const suffix = modelId === matchedFamily ? '' : modelId.slice(matchedFamily.length + 1);
    return { family: matchedFamily, thoughtLevel: suffix };
  }

  for (const suffix of ['xhigh', 'high', 'medium', 'low']) {
    if (modelId.endsWith(`-${suffix}`)) {
      return {
        family: modelId.slice(0, -(suffix.length + 1)),
        thoughtLevel: suffix,
      };
    }
  }
  return { family: modelId, thoughtLevel: '' };
}

export function resolveTargetSelection(
  result: Record<string, unknown>,
  defaultModel: string,
  defaultThoughtLevel: string
): {
  modelId: string | null;
  modelConfigValue: string | null;
  thoughtConfigValue: string | null;
  changed: boolean;
} {
  const targetModelRaw = String(defaultModel || '').trim();
  const targetThoughtRaw = String(defaultThoughtLevel || '').trim();
  if (!targetModelRaw && !targetThoughtRaw) {
    return { modelId: null, modelConfigValue: null, thoughtConfigValue: null, changed: false };
  }

  const modelsObj = (result.models && typeof result.models === 'object'
    ? result.models
    : null) as { availableModels?: Array<{ modelId?: unknown }>; currentModelId?: unknown } | null;
  const availModels = Array.isArray(modelsObj?.availableModels)
    ? modelsObj!.availableModels
        .map((m) => (typeof m?.modelId === 'string' ? m.modelId.trim() : ''))
        .filter(Boolean)
    : [];
  const configOptions = Array.isArray(result.configOptions) ? result.configOptions : [];
  const modelOpt = configOptions.find(
    (c) => c && typeof c === 'object' && (c as Record<string, unknown>).id === 'model'
  ) as { currentValue?: unknown; options?: Array<{ value?: unknown }> } | undefined;
  const thoughtOpt = configOptions.find(
    (c) => c && typeof c === 'object' && (c as Record<string, unknown>).id === 'thought_level'
  ) as { currentValue?: unknown; options?: Array<{ value?: unknown }> } | undefined;

  const modelValues = Array.isArray(modelOpt?.options)
    ? modelOpt!.options
        .map((o) => (typeof o?.value === 'string' ? o.value.trim() : ''))
        .filter(Boolean)
    : [];
  const thoughtValues = Array.isArray(thoughtOpt?.options)
    ? thoughtOpt!.options
        .map((o) => (typeof o?.value === 'string' ? o.value.trim() : ''))
        .filter(Boolean)
    : [];

  let resolvedModelId: string | null = null;
  let resolvedModelCfg: string | null = null;
  let resolvedThoughtCfg: string | null = null;

  if (targetModelRaw) {
    if (availModels.length > 0) {
      if (availModels.includes(targetModelRaw)) {
        resolvedModelId = targetModelRaw;
      } else if (targetThoughtRaw && availModels.includes(`${targetModelRaw}-${targetThoughtRaw}`)) {
        resolvedModelId = `${targetModelRaw}-${targetThoughtRaw}`;
      } else {
        const extracted = extractModelFamilyFromId(targetModelRaw, configOptions);
        if (targetThoughtRaw && availModels.includes(`${extracted.family}-${targetThoughtRaw}`)) {
          resolvedModelId = `${extracted.family}-${targetThoughtRaw}`;
        } else if (availModels.includes(extracted.family)) {
          resolvedModelId = extracted.family;
        }
      }
      if (!resolvedModelId) {
        return { modelId: null, modelConfigValue: null, thoughtConfigValue: null, changed: false };
      }
    }

    const fromModelId = resolvedModelId
      ? extractModelFamilyFromId(resolvedModelId, configOptions)
      : extractModelFamilyFromId(targetModelRaw, configOptions);

    if (modelOpt) {
      if (modelValues.length === 0 || modelValues.includes(fromModelId.family)) {
        resolvedModelCfg = fromModelId.family;
      } else if (modelValues.includes(targetModelRaw)) {
        resolvedModelCfg = targetModelRaw;
      } else if (!resolvedModelId) {
        return { modelId: null, modelConfigValue: null, thoughtConfigValue: null, changed: false };
      }
    }

    const desiredThought = targetThoughtRaw || fromModelId.thoughtLevel;
    if (desiredThought && thoughtOpt) {
      if (thoughtValues.length === 0 || thoughtValues.includes(desiredThought)) {
        resolvedThoughtCfg = desiredThought;
      }
    }
  } else if (targetThoughtRaw && thoughtOpt) {
    if (thoughtValues.length === 0 || thoughtValues.includes(targetThoughtRaw)) {
      resolvedThoughtCfg = targetThoughtRaw;
      const curCfgModel = typeof modelOpt?.currentValue === 'string' ? modelOpt.currentValue.trim() : '';
      if (curCfgModel && availModels.includes(`${curCfgModel}-${targetThoughtRaw}`)) {
        resolvedModelId = `${curCfgModel}-${targetThoughtRaw}`;
      }
    } else {
      return { modelId: null, modelConfigValue: null, thoughtConfigValue: null, changed: false };
    }
  }

  const currentModelId = typeof modelsObj?.currentModelId === 'string' ? modelsObj.currentModelId : '';
  const currentCfgModel = typeof modelOpt?.currentValue === 'string' ? modelOpt.currentValue : '';
  const currentCfgThought = typeof thoughtOpt?.currentValue === 'string' ? thoughtOpt.currentValue : '';

  const modelMismatch =
    (resolvedModelId !== null && resolvedModelId !== currentModelId) ||
    (resolvedModelCfg !== null && resolvedModelCfg !== currentCfgModel);
  const thoughtMismatch = resolvedThoughtCfg !== null && resolvedThoughtCfg !== currentCfgThought;

  return {
    modelId: resolvedModelId,
    modelConfigValue: resolvedModelCfg,
    thoughtConfigValue: resolvedThoughtCfg,
    changed: modelMismatch || thoughtMismatch,
  };
}

export function patchConfigOptionsSelection(
  configOptions: unknown[],
  modelConfigValue: string | null,
  thoughtConfigValue: string | null
): unknown[] {
  const mapped: unknown[] = [];
  for (const item of configOptions) {
    if (!item || typeof item !== 'object') {
      mapped.push(item);
      continue;
    }
    const obj = item as Record<string, unknown>;
    if (obj.id === 'model' && modelConfigValue) {
      mapped.push({ ...obj, currentValue: modelConfigValue });
      continue;
    }
    if (obj.id === 'thought_level') {
      if (!thoughtConfigValue) {
        if (modelConfigValue) continue; // prune obsolete thought_level for non-thinking target model
        mapped.push(item);
        continue;
      }
      mapped.push({ ...obj, currentValue: thoughtConfigValue });
      continue;
    }
    mapped.push(item);
  }
  return mapped;
}

function killProcessGroupTree(pid: number | undefined, signal: NodeJS.Signals): void {
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

interface PendingUpstreamRequest {
  kind: 'user' | 'internal';
  clientReqId?: string | number;
  connId?: number;
  method: string;
  sessionId?: string;
  canonicalCwd: string;
  isExplicitLoad?: boolean;
  isDoctorProbe?: boolean;
  overrideDefaultModel?: string;
  overrideDefaultThoughtLevel?: string;
  resolveInternal?: (msg: Record<string, unknown>) => void;
  onUserSettled?: (err: Error | null) => void;
}

interface WorkerEntry {
  workerId: number;
  canonicalCwd: string;
  isFallback: boolean;
  child: ChildProcessByStdio<Writable, Readable, Readable>;
  initialized: boolean;
  initPromise: Promise<void> | null;
  draining: boolean;
  exiting: boolean;
  hasNonProbeActivity: boolean;
  loadedSessions: Set<string>;
  watchedSessions: Set<string>;
  nextInternalSeq: number;
  nextServerSeq: number;
  stdoutBuffer: Buffer;
  pending: Map<string, PendingUpstreamRequest>;
  idleTimer: LongTimeoutHandle | null;
  watchTimer: ReturnType<typeof setTimeout> | null;
  watchInFlight: boolean;
  activeLoadListeners: Set<(isUpdate: boolean, msg: Record<string, unknown>) => void>;
}

export interface BaseAcpAdapterOptions {
  adapterConfig: AdapterConfig;
  syncConfig: SyncConfig;
  logger: SanitizedLogger;
}

export class BaseAcpAdapter implements AgentAdapter {
  readonly type: 'antigravity' | 'generic-acp';
  readonly capabilities: AdapterCapabilities;

  protected readonly adapterConfig: AdapterConfig;
  protected readonly syncConfig: SyncConfig;
  protected readonly logger: SanitizedLogger;
  protected host!: AdapterHostContext;

  private readonly workers = new Map<string, WorkerEntry>();
  private readonly allWorkers = new Set<WorkerEntry>();
  private readonly pendingServerRequests = new Map<
    string,
    { worker: WorkerEntry; upstreamId: string | number; sessionId?: string }
  >();
  private readonly watchedSessionCwds = new Map<string, string>();
  private readonly loadSuppressWorkers = new Map<
    number,
    { sessionId: string | null; isWake: boolean }
  >();

  private stopped = false;
  private nextWorkerId = 0;

  constructor(
    opts: BaseAcpAdapterOptions,
    type: 'antigravity' | 'generic-acp' = opts.adapterConfig.type,
    capabilities: AdapterCapabilities = {
      usage: false,
      sessionInfo: false,
      deleteSession: false,
      diskPresence: false,
    }
  ) {
    this.adapterConfig = opts.adapterConfig;
    this.syncConfig = opts.syncConfig;
    this.logger = opts.logger;
    this.type = type;
    this.capabilities = capabilities;
  }

  async start(host: AdapterHostContext): Promise<void> {
    this.host = host;
    this.stopped = false;
  }

  async stop(): Promise<void> {
    this.stopped = true;
    const allWorkers = Array.from(this.allWorkers);
    this.workers.clear();
    await Promise.all(allWorkers.map((w) => this.terminateWorker(w, 'adapter_stop')));
    this.allWorkers.clear();
    this.pendingServerRequests.clear();
  }

  isHealthy(): boolean {
    for (const w of this.workers.values()) {
      if (!w.exiting && !w.draining && w.child.exitCode === null && w.child.signalCode === null) {
        return true;
      }
    }
    return false;
  }

  validateSessionCwd(rawCwd: unknown): { ok: true; cwd: string } | { ok: false; message: string } {
    return canonicalizeDirectory(rawCwd);
  }

  hasLoadedSession(sessionId: string, canonicalCwd: string): boolean {
    const resolved = canonicalizeDirectory(canonicalCwd);
    const key = resolved.ok ? resolved.cwd : canonicalCwd;
    const worker = this.workers.get(key);
    return Boolean(worker && !worker.draining && !worker.exiting && worker.loadedSessions.has(sessionId));
  }

  protected getCommandAndArgs(): { command: string; args: string[] } {
    return {
      command: this.adapterConfig.command,
      args: [...this.adapterConfig.args],
    };
  }

  protected getSpawnEnv(): NodeJS.ProcessEnv {
    return { ...process.env };
  }

  protected onUpstreamMessageHook(_msg: Record<string, unknown>, _worker: WorkerEntry): void {
    // Base ACP adapter has no provider-specific hooks
  }

  private getFallbackCwdCanonical(): string {
    const check = canonicalizeDirectory(this.adapterConfig.fallbackCwd);
    if (check.ok) return check.cwd;
    return existsSync(this.adapterConfig.fallbackCwd) ? this.adapterConfig.fallbackCwd : process.cwd();
  }

  private isWorkerBusy(worker: WorkerEntry): boolean {
    if (worker.pending.size > 0 || worker.watchInFlight) return true;
    for (const sid of worker.loadedSessions) {
      if (this.host.isSessionBusy(sid)) return true;
    }
    return false;
  }

  private resetIdleTimer(worker: WorkerEntry): void {
    worker.idleTimer?.cancel();
    worker.idleTimer = null;
    const timeoutMs = this.adapterConfig.childIdleTimeoutMs;
    if (this.stopped || worker.exiting || worker.draining || !timeoutMs || timeoutMs <= 0) {
      return;
    }
    worker.idleTimer = scheduleLongTimeout(() => {
      worker.idleTimer = null;
      if (this.stopped || worker.exiting || worker.draining) return;
      if (this.isWorkerBusy(worker) || worker.watchedSessions.size > 0) {
        this.resetIdleTimer(worker);
        return;
      }
      worker.draining = true;
      this.logger.log('info', 'worker_idle_draining', {
        workerId: worker.workerId,
        childPid: worker.child.pid,
      });
      void this.terminateWorker(worker, 'idle_timeout');
    }, timeoutMs);
  }

  private async terminateWorker(worker: WorkerEntry, reason: string): Promise<void> {
    if (worker.exiting && worker.child.exitCode !== null) return;
    worker.draining = true;
    worker.exiting = true;
    worker.idleTimer?.cancel();
    worker.idleTimer = null;
    if (worker.watchTimer) {
      clearTimeout(worker.watchTimer);
      worker.watchTimer = null;
    }

    if (this.workers.get(worker.canonicalCwd) === worker) {
      this.workers.delete(worker.canonicalCwd);
    }

    if (worker.child.exitCode !== null || worker.child.signalCode !== null) {
      return;
    }

    await new Promise<void>((resolve) => {
      let settled = false;
      const done = () => {
        if (settled) return;
        settled = true;
        clearTimeout(killTimer);
        clearTimeout(capTimer);
        resolve();
      };

      worker.child.once('close', done);
      killProcessGroupTree(worker.child.pid, 'SIGTERM');

      const grace = Math.max(50, this.adapterConfig.childStopGraceMs || 1500);
      const killTimer = setTimeout(() => {
        if (worker.child.exitCode === null && worker.child.signalCode === null) {
          this.logger.log('warn', 'worker_force_sigkill', {
            workerId: worker.workerId,
            childPid: worker.child.pid,
            reason,
          });
          killProcessGroupTree(worker.child.pid, 'SIGKILL');
        }
      }, grace);
      killTimer.unref?.();

      const capTimer = setTimeout(done, grace + 1500);
      capTimer.unref?.();
    });
  }

  private spawnWorker(canonicalCwd: string, isFallback: boolean): WorkerEntry {
    const { command, args } = this.getCommandAndArgs();
    if (!command || !command.trim()) {
      throw new AdapterRpcError(
        -32603,
        `Adapter "${this.type}" command is not configured (set adapter.command in config.json)`
      );
    }

    const child = spawn(command, args, {
      cwd: canonicalCwd,
      detached: true,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: this.getSpawnEnv(),
    });

    const worker: WorkerEntry = {
      workerId: ++this.nextWorkerId,
      canonicalCwd,
      isFallback,
      child,
      initialized: false,
      initPromise: null,
      draining: false,
      exiting: false,
      hasNonProbeActivity: false,
      loadedSessions: new Set(),
      watchedSessions: new Set(),
      nextInternalSeq: 0,
      nextServerSeq: 0,
      stdoutBuffer: Buffer.alloc(0),
      pending: new Map(),
      idleTimer: null,
      watchTimer: null,
      watchInFlight: false,
      activeLoadListeners: new Set(),
    };

    for (const [sid, watchCwd] of this.watchedSessionCwds.entries()) {
      if (watchCwd === canonicalCwd) {
        worker.watchedSessions.add(sid);
      }
    }

    this.allWorkers.add(worker);
    this.workers.set(canonicalCwd, worker);
    this.logger.log('info', 'worker_spawned', {
      workerId: worker.workerId,
      childPid: child.pid,
      kind: isFallback ? 'fallback' : 'cwd',
    });

    child.stdout.on('data', (chunk: Buffer) => {
      this.handleWorkerStdoutChunk(worker, chunk);
    });

    child.stderr.on('data', (chunk: Buffer) => {
      const msg = chunk.toString('utf8').trim();
      if (msg) {
        this.logger.log('warn', 'worker_stderr', {
          workerId: worker.workerId,
          message: msg,
        });
      }
    });

    child.on('error', (err) => {
      this.logger.log('error', 'worker_spawn_error', {
        workerId: worker.workerId,
        message: err.message,
      });
      this.cleanupWorkerOnExit(worker, null, null, err);
    });

    child.on('close', (code, signal) => {
      this.flushWorkerStdoutRemainder(worker);
      this.cleanupWorkerOnExit(worker, code, signal, null);
    });

    this.resetIdleTimer(worker);
    if (worker.watchedSessions.size > 0) {
      this.scheduleWorkerWatch(worker);
    }
    return worker;
  }

  private getOrCreateWorker(canonicalCwd: string, isFallback: boolean = false): WorkerEntry {
    const existing = this.workers.get(canonicalCwd);
    if (existing && !existing.draining && !existing.exiting && existing.child.exitCode === null) {
      return existing;
    }
    if (existing) {
      this.workers.delete(canonicalCwd);
    }
    return this.spawnWorker(canonicalCwd, isFallback);
  }

  private handleWorkerStdoutChunk(worker: WorkerEntry, chunk: Buffer): void {
    if (!chunk || chunk.length === 0) return;
    worker.stdoutBuffer = Buffer.concat([worker.stdoutBuffer, chunk]);
    let nlIdx = worker.stdoutBuffer.indexOf(0x0a);
    while (nlIdx !== -1) {
      const rawLine = worker.stdoutBuffer.subarray(0, nlIdx);
      worker.stdoutBuffer = worker.stdoutBuffer.subarray(nlIdx + 1);
      const trimmed =
        rawLine.length > 0 && rawLine[rawLine.length - 1] === 0x0d
          ? rawLine.subarray(0, rawLine.length - 1)
          : rawLine;
      if (trimmed.length > 0) {
        this.processWorkerJsonLine(worker, trimmed.toString('utf8'));
      }
      nlIdx = worker.stdoutBuffer.indexOf(0x0a);
    }
    if (worker.stdoutBuffer.length > MAX_BUFFER_FALLBACK_FLUSH_BYTES) {
      worker.stdoutBuffer = Buffer.alloc(0);
    }
  }

  private flushWorkerStdoutRemainder(worker: WorkerEntry): void {
    if (worker.stdoutBuffer.length === 0) return;
    const text = worker.stdoutBuffer.toString('utf8').trim();
    worker.stdoutBuffer = Buffer.alloc(0);
    if (text.startsWith('{')) {
      this.processWorkerJsonLine(worker, text);
    }
  }

  private cleanupWorkerOnExit(
    worker: WorkerEntry,
    code: number | null,
    signal: NodeJS.Signals | null,
    err: Error | null
  ): void {
    if (this.workers.get(worker.canonicalCwd) === worker) {
      this.workers.delete(worker.canonicalCwd);
    }
    this.allWorkers.delete(worker);
    worker.idleTimer?.cancel();
    worker.idleTimer = null;
    if (worker.watchTimer) {
      clearTimeout(worker.watchTimer);
      worker.watchTimer = null;
    }

    for (const [rwId, entry] of this.pendingServerRequests.entries()) {
      if (entry.worker === worker) {
        this.pendingServerRequests.delete(rwId);
      }
    }

    const wasDraining = worker.draining;
    const affectedSessions = Array.from(worker.loadedSessions);
    worker.loadedSessions.clear();

    const pendingEntries = Array.from(worker.pending.entries());
    worker.pending.clear();
    for (const [, p] of pendingEntries) {
      if (p.kind === 'internal') {
        p.resolveInternal?.({
          jsonrpc: '2.0',
          id: p.clientReqId ?? null,
          error: {
            code: -32603,
            message: err
              ? `Worker failed: ${err.message}`
              : `Worker exited unexpectedly (code=${String(code)}, signal=${String(signal)})`,
          },
        });
      } else if (wasDraining && p.onUserSettled) {
        p.onUserSettled(new Error('WORKER_DRAINING'));
      } else if (!this.stopped) {
        this.host.onAdapterMessage({
          kind: 'response',
          connId: p.connId,
          clientReqId: p.clientReqId,
          method: p.method,
          sessionId: p.sessionId,
          canonicalCwd: worker.canonicalCwd,
          isDoctorProbe: p.isDoctorProbe,
          message: {
            jsonrpc: '2.0',
            id: p.clientReqId,
            error: {
              code: -32603,
              message: err
                ? `Adapter worker error: ${err.message}`
                : `Adapter worker exited unexpectedly (code=${String(code)})`,
            },
          },
        });
        p.onUserSettled?.(null);
      } else {
        p.onUserSettled?.(null);
      }
    }

    if (!this.stopped && affectedSessions.length > 0 && !wasDraining) {
      this.host.onWorkerExited(affectedSessions);
    }
    this.logger.log('info', 'worker_exited', {
      workerId: worker.workerId,
      code: code ?? undefined,
      draining: wasDraining,
    });
  }

  private writeToWorker(worker: WorkerEntry, payload: Record<string, unknown>): boolean {
    if (worker.exiting || worker.child.exitCode !== null || !worker.child.stdin.writable) {
      return false;
    }
    try {
      worker.child.stdin.write(`${JSON.stringify(payload)}\n`);
      return true;
    } catch {
      return false;
    }
  }

  private sendInternalRpc(
    worker: WorkerEntry,
    method: string,
    params: Record<string, unknown>,
    timeoutMs: number = DEFAULT_RESTORE_STEP_TIMEOUT_MS
  ): Promise<Record<string, unknown>> {
    return new Promise((resolve) => {
      const reqId = `__int_${worker.workerId}_${++worker.nextInternalSeq}`;
      const timer = setTimeout(() => {
        if (worker.pending.delete(reqId)) {
          resolve({
            jsonrpc: '2.0',
            id: reqId,
            error: { code: -32603, message: `Internal RPC "${method}" timed out` },
          });
        }
      }, timeoutMs);
      timer.unref?.();

      worker.pending.set(reqId, {
        kind: 'internal',
        method,
        canonicalCwd: worker.canonicalCwd,
        sessionId: typeof params.sessionId === 'string' ? params.sessionId : undefined,
        resolveInternal: (msg) => {
          clearTimeout(timer);
          resolve(msg);
        },
      });

      const ok = this.writeToWorker(worker, { jsonrpc: '2.0', id: reqId, method, params });
      if (!ok) {
        clearTimeout(timer);
        worker.pending.delete(reqId);
        resolve({
          jsonrpc: '2.0',
          id: reqId,
          error: { code: -32603, message: `Failed writing "${method}" to worker stdin` },
        });
      }
    });
  }

  private async ensureWorkerInitialized(worker: WorkerEntry): Promise<void> {
    if (worker.initialized) return;
    if (worker.initPromise) {
      await worker.initPromise;
      return;
    }
    const cachedInit = this.host.getCachedInitializeMsg();
    if (!cachedInit) {
      // No client initialize seen yet: still mark initialized cleanly so automated wake/load tests can run
      worker.initialized = true;
      return;
    }

    worker.initPromise = (async () => {
      const params =
        cachedInit.params && typeof cachedInit.params === 'object'
          ? (cachedInit.params as Record<string, unknown>)
          : { protocolVersion: 1 };
      const res = await this.sendInternalRpc(worker, 'initialize', params);
      if (res.error) {
        const msg = String((res.error as { message?: unknown }).message ?? '');
        if (!/already\s*initialized/i.test(msg)) {
          throw new AdapterRpcError(
            Number((res.error as { code?: unknown }).code ?? -32603),
            msg || 'Upstream initialize failed'
          );
        }
      }
      worker.initialized = true;
    })().finally(() => {
      worker.initPromise = null;
    });

    await worker.initPromise;
  }

  private async waitForLoadSettle(worker: WorkerEntry, sid: string | null): Promise<void> {
    const quietMs = Math.max(0, this.syncConfig.loadSettleQuietMs ?? 120);
    const maxWaitMs = Math.max(quietMs, this.syncConfig.loadSettleMaxWaitMs ?? 1200);
    if (quietMs === 0 || maxWaitMs === 0) return;

    await new Promise<void>((resolve) => {
      let done = false;
      let quietTimer: ReturnType<typeof setTimeout> | null = null;
      let maxTimer: ReturnType<typeof setTimeout> | null = null;

      const finish = () => {
        if (done) return;
        done = true;
        if (quietTimer) clearTimeout(quietTimer);
        if (maxTimer) clearTimeout(maxTimer);
        worker.activeLoadListeners.delete(listener);
        resolve();
      };

      const armQuiet = () => {
        if (quietTimer) clearTimeout(quietTimer);
        quietTimer = setTimeout(finish, quietMs);
        quietTimer.unref?.();
      };

      const listener = (isUpdate: boolean, msg: Record<string, unknown>) => {
        if (!isUpdate) return;
        const params = msg.params as { sessionId?: unknown } | undefined;
        if (sid && typeof params?.sessionId === 'string' && params.sessionId !== sid) return;
        armQuiet();
      };

      worker.activeLoadListeners.add(listener);
      maxTimer = setTimeout(finish, maxWaitMs);
      maxTimer.unref?.();
      armQuiet();
    });
  }

  private async applySavedConfigRestore(
    worker: WorkerEntry,
    sessionId: string,
    snapshot: SavedSessionSnapshot | null
  ): Promise<SavedSessionSnapshot | null> {
    if (!snapshot) return null;

    // Step 1: session/set_model
    const modelId =
      typeof snapshot.models?.currentModelId === 'string' && snapshot.models.currentModelId.trim()
        ? snapshot.models.currentModelId.trim()
        : null;
    if (modelId) {
      await this.sendInternalRpc(worker, 'session/set_model', { sessionId, modelId });
    }

    // Step 2: session/set_config_option (model -> thought_level -> other keys)
    if (Array.isArray(snapshot.configOptions)) {
      const ordered = [...snapshot.configOptions]
        .filter(
          (item): item is { id: string; currentValue: unknown } =>
            Boolean(
              item &&
                typeof item === 'object' &&
                typeof (item as { id?: unknown }).id === 'string' &&
                (item as { currentValue?: unknown }).currentValue !== undefined
            )
        )
        .sort((a, b) => {
          const rank = (id: string) => (id === 'model' ? 0 : id === 'thought_level' ? 1 : 2);
          return rank(a.id) - rank(b.id);
        });

      for (const opt of ordered) {
        await this.sendInternalRpc(worker, 'session/set_config_option', {
          sessionId,
          configId: opt.id,
          value: opt.currentValue,
        });
      }
    }

    // Step 3: session/set_mode
    const modeId =
      typeof snapshot.modes?.currentModeId === 'string' && snapshot.modes.currentModeId.trim()
        ? snapshot.modes.currentModeId.trim()
        : null;
    if (modeId) {
      await this.sendInternalRpc(worker, 'session/set_mode', { sessionId, modeId });
    }

    return snapshot;
  }

  private async applyDefaultModelLockIfConfigured(
    worker: WorkerEntry,
    result: Record<string, unknown>,
    overrideModel?: string,
    overrideThought?: string
  ): Promise<Record<string, unknown>> {
    const defaultModel = overrideModel !== undefined ? overrideModel : this.adapterConfig.defaultModel;
    const defaultThought = overrideThought !== undefined ? overrideThought : this.adapterConfig.defaultThoughtLevel;
    const sid = typeof result.sessionId === 'string' ? result.sessionId : null;
    if (!sid || (!defaultModel && !defaultThought)) {
      const cloned = { ...result };
      delete cloned._meta;
      return cloned;
    }

    const selection = resolveTargetSelection(result, defaultModel, defaultThought);
    const nextResult: Record<string, unknown> = structuredClone(result);
    delete nextResult._meta;

    if (!selection.changed) {
      return nextResult;
    }

    if (selection.modelId) {
      await this.sendInternalRpc(worker, 'session/set_model', {
        sessionId: sid,
        modelId: selection.modelId,
      });
      if (nextResult.models && typeof nextResult.models === 'object') {
        nextResult.models = {
          ...(nextResult.models as Record<string, unknown>),
          currentModelId: selection.modelId,
        };
      }
    }

    if (selection.modelConfigValue) {
      await this.sendInternalRpc(worker, 'session/set_config_option', {
        sessionId: sid,
        configId: 'model',
        value: selection.modelConfigValue,
      });
    }

    if (selection.thoughtConfigValue) {
      await this.sendInternalRpc(worker, 'session/set_config_option', {
        sessionId: sid,
        configId: 'thought_level',
        value: selection.thoughtConfigValue,
      });
    }

    if (Array.isArray(nextResult.configOptions)) {
      nextResult.configOptions = patchConfigOptionsSelection(
        nextResult.configOptions,
        selection.modelConfigValue,
        selection.thoughtConfigValue
      );
    }

    return nextResult;
  }

  private processWorkerJsonLine(worker: WorkerEntry, line: string): void {
    let msg: Record<string, unknown>;
    try {
      const parsed = JSON.parse(line);
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return;
      msg = parsed as Record<string, unknown>;
    } catch {
      return;
    }

    try {
      this.onUpstreamMessageHook(msg, worker);
    } catch {
      // isolate provider hook errors
    }

    // Check internal load/wake listeners
    if (msg.method === 'session/update') {
      for (const listener of worker.activeLoadListeners) {
        listener(true, msg);
      }
    }

    const hasMethod = typeof msg.method === 'string' && msg.method.length > 0;
    const hasId = msg.id !== undefined && msg.id !== null;

    // 1. Server-initiated JSON-RPC request -> rewrite id and track reverse map
    if (hasMethod && hasId) {
      const params = (msg.params && typeof msg.params === 'object' ? msg.params : {}) as Record<string, unknown>;
      const sid = typeof params.sessionId === 'string' ? params.sessionId : undefined;
      const rewrittenId = `w${worker.workerId}_s${++worker.nextServerSeq}_${String(msg.id)}`;
      this.pendingServerRequests.set(rewrittenId, {
        worker,
        upstreamId: msg.id as string | number,
        sessionId: sid,
      });
      this.host.onAdapterMessage({
        kind: 'server_request',
        sessionId: sid,
        canonicalCwd: worker.canonicalCwd,
        message: { ...msg, id: rewrittenId },
      });
      return;
    }

    // 2. Notification
    if (hasMethod && !hasId) {
      const params = (msg.params && typeof msg.params === 'object' ? msg.params : {}) as Record<string, unknown>;
      const sid = typeof params.sessionId === 'string' ? params.sessionId : undefined;
      const update = (params.update && typeof params.update === 'object'
        ? params.update
        : undefined) as Record<string, unknown> | undefined;
      const updateType = update?.sessionUpdate ?? update?.type;

      if (sid && updateType === 'available_commands_update' && Array.isArray(update?.availableCommands)) {
        this.host.onSessionCommandsCaptured?.(sid, structuredClone(update.availableCommands));
      }

      const loadState = this.loadSuppressWorkers.get(worker.workerId);
      const isWakeSuppression = Boolean(
        loadState &&
          loadState.isWake &&
          (!loadState.sessionId || !sid || sid === loadState.sessionId)
      );
      const isConfigNoise = Boolean(loadState && isLoadReplayConfigNoise(msg));

      this.host.onAdapterMessage({
        kind: 'notification',
        sessionId: sid,
        canonicalCwd: worker.canonicalCwd,
        replayInFlight: Boolean(loadState),
        suppressConfigUpdate: isWakeSuppression || isConfigNoise,
        suppressNotification: isWakeSuppression || isConfigNoise,
        message: msg,
      });
      return;
    }

    // 3. Response
    if (!hasMethod && hasId) {
      const key = String(msg.id);
      const entry = worker.pending.get(key);
      if (!entry) return;
      worker.pending.delete(key);
      this.resetIdleTimer(worker);

      if (entry.kind === 'internal') {
        entry.resolveInternal?.(msg);
        return;
      }

      void this.handleUserRpcResponse(worker, entry, msg);
    }
  }

  private async handleUserRpcResponse(
    worker: WorkerEntry,
    entry: PendingUpstreamRequest,
    rawMsg: Record<string, unknown>
  ): Promise<void> {
    let outboundMsg = rawMsg;
    const result = (outboundMsg.result && typeof outboundMsg.result === 'object'
      ? outboundMsg.result
      : null) as Record<string, unknown> | null;

    let restoredSnapshot: SavedSessionSnapshot | null = null;

    if (entry.method === 'initialize') {
      if (!outboundMsg.error || /already\s*initialized/i.test(String((outboundMsg.error as { message?: unknown })?.message ?? ''))) {
        worker.initialized = true;
      }
      if (
        outboundMsg.error &&
        /already\s*initialized/i.test(String((outboundMsg.error as { message?: unknown })?.message ?? ''))
      ) {
        outboundMsg = { jsonrpc: '2.0', id: outboundMsg.id, result: {} };
      }
    }

    if ((entry.method === 'session/new' || entry.method === 'session/create') && !outboundMsg.error && result) {
      const sid = typeof result.sessionId === 'string' ? result.sessionId : null;
      if (sid && !IGNORED_PROBE_SESSION_IDS.has(sid)) {
        worker.loadedSessions.add(sid);
      }
      const patched = await this.applyDefaultModelLockIfConfigured(
        worker,
        result,
        entry.overrideDefaultModel,
        entry.overrideDefaultThoughtLevel
      );
      outboundMsg = { ...outboundMsg, result: patched };
    } else if (entry.method === 'session/load' || entry.method === 'session/resume') {
      const sid =
        (result && typeof result.sessionId === 'string' ? result.sessionId : null) ||
        entry.sessionId ||
        null;
      if (!outboundMsg.error && sid && !IGNORED_PROBE_SESSION_IDS.has(sid)) {
        worker.loadedSessions.add(sid);
        await this.waitForLoadSettle(worker, sid);
        const saved = this.host.getSessionSnapshot(sid);
        if (saved) {
          restoredSnapshot = await this.applySavedConfigRestore(worker, sid, saved);
        }
      }
      this.loadSuppressWorkers.delete(worker.workerId);
    }

    this.host.onAdapterMessage({
      kind: 'response',
      connId: entry.connId,
      clientReqId: entry.clientReqId,
      method: entry.method,
      sessionId: entry.sessionId,
      canonicalCwd: worker.canonicalCwd,
      isExplicitLoad: entry.isExplicitLoad,
      isDoctorProbe: entry.isDoctorProbe,
      explicitLoadSettled: Boolean(entry.isExplicitLoad),
      restoredSnapshot: restoredSnapshot
        ? {
            models: restoredSnapshot.models,
            configOptions: restoredSnapshot.configOptions,
            modes: restoredSnapshot.modes,
            availableCommands: restoredSnapshot.availableCommands,
          }
        : undefined,
      message: outboundMsg,
    });
    entry.onUserSettled?.(null);
  }

  private async runTransparentWake(worker: WorkerEntry, sessionId: string): Promise<void> {
    this.loadSuppressWorkers.set(worker.workerId, { sessionId, isWake: true });
    try {
      const loadRes = await this.sendInternalRpc(worker, 'session/load', {
        sessionId,
        cwd: worker.canonicalCwd,
      });

      if (loadRes.error) {
        const missingOnDisk = Boolean(this.capabilities.diskPresence && !this.checkSessionDiskPresence?.(sessionId));
        const errObj = loadRes.error as { code?: unknown; message?: unknown };
        throw new AdapterRpcError(
          Number.isFinite(Number(errObj.code)) ? Number(errObj.code) : -32602,
          String(errObj.message ?? 'Failed waking session'),
          { sessionMissingOnWake: missingOnDisk }
        );
      }

      worker.loadedSessions.add(sessionId);
      await this.waitForLoadSettle(worker, sessionId);

      const saved = this.host.getSessionSnapshot(sessionId);
      const restored = await this.applySavedConfigRestore(worker, sessionId, saved);
      this.host.onSessionWakeRestored?.(sessionId, worker.canonicalCwd, {
        models: restored?.models,
        configOptions: restored?.configOptions,
        modes: restored?.modes,
        availableCommands: restored?.availableCommands,
      });
    } finally {
      this.loadSuppressWorkers.delete(worker.workerId);
    }
  }

  async dispatchClientMessage(req: AdapterDispatchRequest): Promise<void> {
    await this.dispatchWithRetry(req, 0);
  }

  private async dispatchWithRetry(req: AdapterDispatchRequest, retryCount: number): Promise<void> {
    const targetCwd = req.canonicalCwd || this.getFallbackCwdCanonical();
    const isFallback = !req.canonicalCwd || targetCwd === this.getFallbackCwdCanonical();

    let worker: WorkerEntry;
    try {
      worker = this.getOrCreateWorker(targetCwd, isFallback);
    } catch (err) {
      if (req.clientReqId !== undefined) {
        const rpcCode = err instanceof AdapterRpcError ? err.rpcCode : -32603;
        this.host.onAdapterMessage({
          kind: 'response',
          connId: req.connId,
          clientReqId: req.clientReqId,
          method: req.method,
          sessionId: req.sessionId,
          canonicalCwd: targetCwd,
          isDoctorProbe: req.isDoctorProbe,
          message: {
            jsonrpc: '2.0',
            id: req.clientReqId,
            error: { code: rpcCode, message: err instanceof Error ? err.message : 'Spawn failed' },
          },
        });
      }
      return;
    }

    if (!req.isDoctorProbe && req.sessionId !== 'capability-probe') {
      worker.hasNonProbeActivity = true;
    }

    try {
      if (req.method !== 'initialize') {
        await this.ensureWorkerInitialized(worker);
      }

      if (worker.draining || worker.exiting || worker.child.exitCode !== null) {
        throw new Error('WORKER_DRAINING');
      }

      const isExplicitLoad = req.method === 'session/load' || req.method === 'session/resume';
      const isGlobal =
        req.method === 'initialize' ||
        req.method === 'session/new' ||
        req.method === 'session/create' ||
        req.method === 'session/list' ||
        IGNORED_PROBE_SESSION_IDS.has(req.sessionId ?? '');

      if (!isGlobal && !isExplicitLoad && req.sessionId && !worker.loadedSessions.has(req.sessionId)) {
        await this.runTransparentWake(worker, req.sessionId);
      }

      if (isExplicitLoad) {
        this.loadSuppressWorkers.set(worker.workerId, {
          sessionId: req.sessionId ?? null,
          isWake: false,
        });
      }

      if (worker.draining || worker.exiting || worker.child.exitCode !== null) {
        throw new Error('WORKER_DRAINING');
      }

      const wireId =
        req.clientReqId !== undefined ? req.clientReqId : `__notif_${++worker.nextInternalSeq}`;

      await new Promise<void>((resolve, reject) => {
        if (req.clientReqId === undefined) {
          const sent = this.writeToWorker(worker, req.rawMessage);
          if (!sent) reject(new Error('WORKER_DRAINING'));
          else resolve();
          return;
        }

        const key = String(wireId);
        worker.pending.set(key, {
          kind: 'user',
          clientReqId: req.clientReqId,
          connId: req.connId,
          method: req.method,
          sessionId: req.sessionId,
          canonicalCwd: worker.canonicalCwd,
          isExplicitLoad: req.isExplicitLoad,
          isDoctorProbe: req.isDoctorProbe,
          onUserSettled: (err) => {
            if (err) reject(err);
            else resolve();
          },
        });

        const origParams =
          req.rawMessage.params && typeof req.rawMessage.params === 'object'
            ? (req.rawMessage.params as Record<string, unknown>)
            : {};
        let forwardParams: Record<string, unknown> = origParams;
        if (req.method === 'session/new' || req.method === 'session/create') {
          const nextParams: Record<string, unknown> = { ...origParams, cwd: worker.canonicalCwd };
          const metaObj =
            nextParams._meta && typeof nextParams._meta === 'object' && !Array.isArray(nextParams._meta)
              ? { ...(nextParams._meta as Record<string, unknown>) }
              : null;
          if (metaObj) {
            const clientModel =
              typeof metaObj.nonlocalDefaultModel === 'string' ? metaObj.nonlocalDefaultModel.trim() : '';
            const clientThought =
              typeof metaObj.nonlocalDefaultThoughtLevel === 'string'
                ? metaObj.nonlocalDefaultThoughtLevel.trim()
                : '';
            if (clientModel) {
              const pEntry = worker.pending.get(key);
              if (pEntry) {
                pEntry.overrideDefaultModel = clientModel;
                pEntry.overrideDefaultThoughtLevel = clientThought;
              }
            }
            delete metaObj.nonlocalDefaultModel;
            delete metaObj.nonlocalDefaultThoughtLevel;
            if (Object.keys(metaObj).length === 0) {
              delete nextParams._meta;
            } else {
              nextParams._meta = metaObj;
            }
          }
          forwardParams = nextParams;
        }
        const payload = { ...req.rawMessage, params: forwardParams, id: wireId };
        const sent = this.writeToWorker(worker, payload);
        if (!sent) {
          worker.pending.delete(key);
          reject(new Error('WORKER_DRAINING'));
        }
        this.resetIdleTimer(worker);
      });
    } catch (err) {
      if (req.method === 'session/load' || req.method === 'session/resume') {
        this.loadSuppressWorkers.delete(worker.workerId);
      }
      if (err instanceof Error && err.message === 'WORKER_DRAINING' && retryCount < 1 && !this.stopped) {
        this.logger.log('info', 'worker_draining_retry', {
          method: req.method,
          sessionId: req.sessionId,
        });
        await this.dispatchWithRetry(req, retryCount + 1);
        return;
      }
      if (req.clientReqId !== undefined) {
        const rpcCode = err instanceof AdapterRpcError ? err.rpcCode : -32603;
        this.host.onAdapterMessage({
          kind: 'response',
          connId: req.connId,
          clientReqId: req.clientReqId,
          method: req.method,
          sessionId: req.sessionId,
          canonicalCwd: targetCwd,
          isDoctorProbe: req.isDoctorProbe,
          message: {
            jsonrpc: '2.0',
            id: req.clientReqId,
            error: {
              code: rpcCode,
              message: err instanceof Error ? err.message : 'Adapter request failed',
            },
          },
        });
      }
      if (err instanceof AdapterRpcError && err.sessionMissingOnWake && req.sessionId) {
        this.host.onSessionMissingOnWake?.(req.sessionId);
      }
    }
  }

  respondToServerRequest(rewrittenId: string | number, rawResponse: Record<string, unknown>): boolean {
    const key = String(rewrittenId);
    const entry = this.pendingServerRequests.get(key);
    if (!entry) return false;
    this.pendingServerRequests.delete(key);
    return this.writeToWorker(entry.worker, { ...rawResponse, id: entry.upstreamId });
  }

  async closeSessionBestEffort(sessionId: string, timeoutMs: number = 150): Promise<void> {
    for (const worker of this.workers.values()) {
      if (!worker.loadedSessions.has(sessionId)) continue;
      worker.loadedSessions.delete(sessionId);
      if (!worker.exiting && !worker.draining && worker.child.exitCode === null) {
        await this.sendInternalRpc(worker, 'session/close', { sessionId }, timeoutMs).catch(() => {});
      }
    }
  }

  async reclaimIdleFallbackIfProbeOnly(): Promise<void> {
    const fallbackCwd = this.getFallbackCwdCanonical();
    const worker = this.workers.get(fallbackCwd);
    if (!worker || !worker.isFallback) return;
    if (worker.hasNonProbeActivity || worker.loadedSessions.size > 0 || worker.pending.size > 0) {
      return;
    }
    this.logger.log('info', 'reclaim_probe_fallback_worker', {
      workerId: worker.workerId,
      childPid: worker.child.pid,
    });
    await this.terminateWorker(worker, 'doctor_probe_cleanup');
  }

  syncSessionWatch(sessionId: string, watchActive: boolean): void {
    const snap = this.host?.getSessionSnapshot(sessionId);
    const cwd = snap?.cwd || this.getFallbackCwdCanonical();
    if (watchActive) {
      this.watchedSessionCwds.set(sessionId, cwd);
      const worker = this.workers.get(cwd);
      if (worker && !worker.exiting && !worker.draining) {
        worker.watchedSessions.add(sessionId);
        this.scheduleWorkerWatch(worker);
      }
    } else {
      this.watchedSessionCwds.delete(sessionId);
      for (const worker of this.workers.values()) {
        worker.watchedSessions.delete(sessionId);
        if (worker.watchedSessions.size === 0 && worker.watchTimer) {
          clearTimeout(worker.watchTimer);
          worker.watchTimer = null;
        }
      }
    }
  }

  private scheduleWorkerWatch(worker: WorkerEntry): void {
    if (this.stopped || worker.exiting || worker.draining || worker.watchTimer || worker.watchedSessions.size === 0) {
      return;
    }
    const intervalMs = Math.max(20, this.syncConfig.watchIntervalMs || 2500);
    worker.watchTimer = setTimeout(async () => {
      worker.watchTimer = null;
      if (this.stopped || worker.exiting || worker.draining || worker.watchedSessions.size === 0) {
        return;
      }
      worker.watchInFlight = true;
      try {
        await this.ensureWorkerInitialized(worker);
        const res = await this.sendInternalRpc(worker, 'session/list', { cwd: worker.canonicalCwd });
        const result = (res.result && typeof res.result === 'object' ? res.result : null) as
          | { sessions?: unknown; nextCursor?: unknown }
          | null;
        if (!res.error && Array.isArray(result?.sessions)) {
          this.host.onBackgroundSessionList({
            sessions: result.sessions as Record<string, unknown>[],
            requestedCwd: worker.canonicalCwd,
            isWatch: true,
            hasCursor: false,
            hasNextCursor: typeof result.nextCursor === 'string' && result.nextCursor.trim().length > 0,
            scopeSessionIds: new Set(worker.watchedSessions),
          });
        }
      } catch {
        // ignore watch poll errors
      } finally {
        worker.watchInFlight = false;
        this.resetIdleTimer(worker);
        if (!this.stopped && !worker.exiting && !worker.draining && worker.watchedSessions.size > 0) {
          this.scheduleWorkerWatch(worker);
        }
      }
    }, intervalMs);
    worker.watchTimer.unref?.();
  }

  // Optional capability hook declared cleanly for subclasses
  checkSessionDiskPresence?(sessionId: string): boolean;
}
