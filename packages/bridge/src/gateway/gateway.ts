import type {
  AdapterDispatchRequest,
  AdapterHostContext,
  AdapterOutboundEvent,
  AgentAdapter,
} from '../adapter/types.js';
import type { BridgeConfig } from '../config/types.js';
import { FsRpcError, RemoteFsService, canonicalizeCwdWithHome } from '../fs/remote-fs.js';
import type { SanitizedLogger } from '../log/logger.js';
import { StateStore, extractPromptText, IGNORED_PROBE_SESSION_IDS } from '../store/state-store.js';
import { TitleSummaryService } from '../store/title-summary.js';
import { SessionSyncManager } from '../sync/session-sync-manager.js';
import type { BridgeTransport, ClientConnection, ListenEndpoint } from '../transport/types.js';

const DEFAULT_USAGE_TTL_SECONDS = 180;
const DEFAULT_USAGE_CLOCK_SKEW_MS = 30_000;
const DEFAULT_SAFE_SESSION_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const GLOBAL_PASSTHROUGH_METHODS = new Set(['initialize', 'session/new', 'session/create', 'session/list']);

const NO_ID_SILENT_DROP_METHODS = new Set([
  'nonlocal/usage',
  'nonlocal/session_info',
  'nonlocal/fs_list',
  'nonlocal/fs_read_file',
  'nonlocal/delete_session',
]);

interface ConnectionState {
  connId: number;
  conn: ClientConnection;
  preempted: boolean;
  bridgeSyncEnabled: boolean;
  usageEnabled: boolean;
  isDoctorProbe: boolean;
}

function isSafeSessionIdDefault(sessionId: unknown): sessionId is string {
  if (typeof sessionId !== 'string') return false;
  if (!DEFAULT_SAFE_SESSION_ID_RE.test(sessionId)) return false;
  if (sessionId === '.' || sessionId === '..' || sessionId.includes('..')) return false;
  return true;
}

function isSqliteBusyErrorLike(err: unknown): boolean {
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

function getRpcErrorCode(err: unknown, fallback: number = -32603): number {
  if (err && typeof err === 'object' && typeof (err as { rpcCode?: unknown }).rpcCode === 'number') {
    return (err as { rpcCode: number }).rpcCode;
  }
  return fallback;
}

function isBlankFreshRow(
  row: { upstreamTitle: string | null; customTitle: string | null; aiTitle: string | null; fallbackTitle: string | null; createdAt: string | null } | undefined,
  nowMs: number = Date.now()
): boolean {
  if (!row) return false;
  const createdMs = row.createdAt ? Date.parse(row.createdAt) : NaN;
  return (
    !row.upstreamTitle &&
    !row.customTitle &&
    !row.aiTitle &&
    !row.fallbackTitle &&
    Number.isFinite(createdMs) &&
    nowMs - createdMs < 60_000
  );
}

export interface GatewayOptions {
  config: BridgeConfig;
  transport: BridgeTransport;
  adapter: AgentAdapter;
  store: StateStore;
  logger: SanitizedLogger;
  fsService?: RemoteFsService;
  titleSummaryService?: TitleSummaryService;
  syncManager?: SessionSyncManager;
}

export class NonlocalGateway {
  private readonly config: BridgeConfig;
  private readonly transport: BridgeTransport;
  private readonly adapter: AgentAdapter;
  readonly store: StateStore;
  readonly logger: SanitizedLogger;
  readonly fsService: RemoteFsService;
  readonly titleSummary: TitleSummaryService;
  readonly sync: SessionSyncManager;

  private activeConn: ConnectionState | null = null;
  private nextConnId = 0;
  private nextGwReqSeq = 0;
  private shuttingDown = false;
  private shutdownPromise: Promise<void> | null = null;
  private cachedInitializeMsg: Record<string, unknown> | null = null;

  private readonly gwPending = new Map<
    string,
    {
      origClientId: unknown;
      connId: number;
      method: string;
      hasCursor: boolean;
      requestedCwd: string | null;
      isDoctorProbe: boolean;
    }
  >();
  private readonly sessionQueues = new Map<string, Promise<unknown>>();
  private readonly deletedSessionIds = new Set<string>();
  private readonly deletingSessionIds = new Set<string>();
  private readonly pendingDeleteSubagents = new Map<string, string[]>();
  private readonly noDiskMissCounts = new Map<string, number>();

  private usageInFlight: Promise<void> | null = null;
  private usageLastFailureAt = 0;

  constructor(opts: GatewayOptions) {
    this.config = opts.config;
    this.transport = opts.transport;
    this.adapter = opts.adapter;
    this.store = opts.store;
    this.logger = opts.logger;
    this.fsService = opts.fsService ?? new RemoteFsService();
    this.titleSummary = opts.titleSummaryService ?? new TitleSummaryService(opts.config.titleSummary, opts.logger);
    this.sync =
      opts.syncManager ??
      new SessionSyncManager({
        maxEventsPerTurn: opts.config.sync.maxEventsPerTurn,
        maxTurnBytes: opts.config.sync.maxTurnBytes,
        watchWindowMs: opts.config.sync.watchWindowMs,
        settleWindowMs: opts.config.sync.settleWindowMs,
        isSessionAllowed: (sid) => !this.deletedSessionIds.has(sid) && this.store.has(sid),
      });
  }

  getInstanceId(): string {
    return this.sync.getInstanceId();
  }

  getHealthState(): { childAlive: boolean; activeClient: boolean } {
    return {
      childAlive: this.adapter.isHealthy(),
      activeClient: Boolean(this.activeConn && !this.activeConn.preempted && this.activeConn.conn.isOpen()),
    };
  }

  async start(): Promise<{ host: string; port: number; listenAddresses: ListenEndpoint[] }> {
    const hostCtx: AdapterHostContext = {
      getSessionSnapshot: (sessionId) => {
        const rec = this.store.get(sessionId);
        if (!rec) return null;
        return {
          sessionId,
          cwd: rec.cwd,
          modes: rec.modes,
          models: rec.models,
          configOptions: rec.configOptions,
          availableCommands: rec.availableCommands,
        };
      },
      isSessionOwned: (sessionId) => !this.deletedSessionIds.has(sessionId) && this.store.has(sessionId),
      isSessionDeleted: (sessionId) => this.deletedSessionIds.has(sessionId),
      isSessionBusy: (sessionId) => this.isSessionActivelyBusy(sessionId),
      getCachedInitializeMsg: () => (this.cachedInitializeMsg ? structuredClone(this.cachedInitializeMsg) : null),
      onAdapterMessage: (event) => this.handleAdapterEvent(event),
      onSessionCommandsCaptured: (sessionId, commands) => {
        if (this.store.has(sessionId)) {
          this.store.updateSession(sessionId, { availableCommands: commands });
          this.sync.restoreSessionSnapshot(sessionId, { availableCommands: commands });
        }
      },
      onSessionWakeRestored: (sessionId, canonicalCwd, restored) => {
        if (this.store.has(sessionId)) {
          this.store.updateSession(sessionId, {
            ...(restored.models !== undefined ? { models: restored.models } : {}),
            ...(restored.configOptions !== undefined ? { configOptions: restored.configOptions } : {}),
            ...(restored.modes !== undefined ? { modes: restored.modes } : {}),
            ...(Array.isArray(restored.availableCommands) ? { availableCommands: restored.availableCommands } : {}),
          });
        }
        this.sync.markSessionMaterialized(sessionId, canonicalCwd);
        this.sync.restoreSessionSnapshot(sessionId, restored);
      },
      onUsageTierObserved: (tier) => this.handleUsageTierObserved(tier),
      onBackgroundSessionList: (payload) => this.handleBackgroundSessionList(payload),
      onSessionMissingOnWake: (sessionId) => {
        this.evictDeletedSession(sessionId, 'disk_missing_on_wake');
      },
      onWorkerExited: (affectedSessionIds) => this.handleWorkerExited(affectedSessionIds),
    };

    await this.adapter.start(hostCtx);
    this.transport.onConnection((conn) => this.handleTransportConnection(conn));
    return await this.transport.start();
  }

  async stop(reason: string = 'shutdown'): Promise<void> {
    if (this.shutdownPromise) return this.shutdownPromise;
    this.shuttingDown = true;
    this.shutdownPromise = (async () => {
      this.logger.log('info', 'bridge_stopping', { reason });
      if (this.activeConn && this.activeConn.conn.isOpen()) {
        this.activeConn.conn.close(1001, 'bridge_shutting_down');
        this.activeConn = null;
      }
      await this.transport.stop();
      this.adapter.abortUsage?.();
      await this.adapter.stop();
      this.store.close();
      this.logger.log('info', 'bridge_stopped', { reason });
    })();
    return this.shutdownPromise;
  }

  private isSessionActivelyBusy(sessionId: string): boolean {
    if (this.deletingSessionIds.has(sessionId)) return true;
    return this.sync.isSessionActiveOrPending(sessionId);
  }

  private enqueueSessionTask<T>(sessionId: string, fn: () => Promise<T>): Promise<T> {
    const prev = this.sessionQueues.get(sessionId) || Promise.resolve();
    const run = prev.catch(() => {}).then(fn);
    const tail = run.finally(() => {
      if (this.sessionQueues.get(sessionId) === tail) {
        this.sessionQueues.delete(sessionId);
      }
    });
    this.sessionQueues.set(sessionId, tail);
    return run;
  }

  private sendJsonRpcError(connState: ConnectionState, id: unknown, code: number, message: string): void {
    if (connState.preempted || this.activeConn !== connState || !connState.conn.isOpen()) return;
    connState.conn.sendText(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } }));
  }

  private emitSessionInfoUpdate(sessionId: string, displayTitle: string | null): void {
    if (!this.activeConn || this.activeConn.preempted || !this.activeConn.conn.isOpen()) return;
    this.activeConn.conn.sendText(
      JSON.stringify({
        jsonrpc: '2.0',
        method: 'session/update',
        params: {
          sessionId,
          update: {
            sessionUpdate: 'session_info_update',
            title: displayTitle ?? null,
          },
        },
      })
    );
  }

  private sendSessionDeletedNotification(sessionId: string): void {
    if (this.shuttingDown) return;
    if (!this.activeConn || this.activeConn.preempted || !this.activeConn.bridgeSyncEnabled || !this.activeConn.conn.isOpen()) {
      return;
    }
    this.activeConn.conn.sendText(
      JSON.stringify({
        jsonrpc: '2.0',
        method: 'nonlocal/session_deleted',
        params: {
          instanceId: this.sync.getInstanceId(),
          sessionId,
        },
      })
    );
  }

  private sendSessionStaleNotifications(staleList: Array<Record<string, unknown>>): void {
    if (!Array.isArray(staleList) || staleList.length === 0) return;
    if (!this.activeConn || this.activeConn.preempted || !this.activeConn.bridgeSyncEnabled || !this.activeConn.conn.isOpen()) {
      return;
    }
    for (const payload of staleList) {
      this.logger.log('info', 'nonlocal_session_stale', {
        connId: this.activeConn.connId,
        method: 'nonlocal/session_stale',
        sessionId: payload.sessionId,
        instanceId: payload.instanceId,
        reason: payload.reason || 'background_updated',
      });
      this.activeConn.conn.sendText(
        JSON.stringify({
          jsonrpc: '2.0',
          method: 'nonlocal/session_stale',
          params: payload,
        })
      );
    }
  }

  private sendTurnCompletedNotifications(completions: Array<Record<string, unknown>>): void {
    if (!Array.isArray(completions) || completions.length === 0) return;
    if (!this.activeConn || this.activeConn.preempted || !this.activeConn.bridgeSyncEnabled || !this.activeConn.conn.isOpen()) {
      return;
    }
    for (const payload of completions) {
      this.logger.log('info', 'nonlocal_turn_completed', {
        connId: this.activeConn.connId,
        method: 'nonlocal/turn_completed',
        sessionId: payload.sessionId,
        instanceId: payload.instanceId,
        turnId: payload.turnId,
        reason: payload.status,
      });
      this.activeConn.conn.sendText(
        JSON.stringify({
          jsonrpc: '2.0',
          method: 'nonlocal/turn_completed',
          params: payload,
        })
      );
    }
  }

  private sanitizeSessionResultPayload(
    msg: Record<string, unknown>,
    sid: string | null,
    canonicalCwd: string | null = null
  ): Record<string, unknown> {
    if (!msg || typeof msg !== 'object' || msg.error || !msg.result || typeof msg.result !== 'object') {
      return msg;
    }
    const cleanResult = { ...(msg.result as Record<string, unknown>) };
    const displayTitle =
      typeof sid === 'string' && this.store.has(sid) ? this.store.getDisplayTitle(sid) : null;
    cleanResult.title = displayTitle;
    if (canonicalCwd) {
      cleanResult.cwd = canonicalCwd;
    }
    delete cleanResult.prompt;
    delete cleanResult.rawTitle;
    return { ...msg, result: cleanResult };
  }

  private evictDeletedSession(sessionId: string, reason: string = 'external_deleted'): boolean {
    if (!sessionId || IGNORED_PROBE_SESSION_IDS.has(sessionId)) return false;
    const deleted = this.store.deleteSession(sessionId);
    this.noDiskMissCounts.delete(sessionId);
    this.sync.deleteSession(sessionId);
    this.adapter.syncSessionWatch?.(sessionId, false);
    if (deleted) {
      this.logger.log('info', 'session_evicted', { sessionId, reason });
      this.sendSessionDeletedNotification(sessionId);
    }
    return deleted;
  }

  private reconcileExternalDeletions(
    rawSessions: Record<string, unknown>[],
    opts: {
      isWatch?: boolean;
      requestedCwd?: string | null;
      hasCursor?: boolean;
      hasNextCursor?: boolean;
    } = {}
  ): void {
    if (opts.hasCursor || opts.hasNextCursor) return;
    const presentSet = new Set<string>();
    for (const item of rawSessions) {
      if (item && typeof item.sessionId === 'string' && item.sessionId.trim()) {
        presentSet.add(item.sessionId.trim());
      }
    }

    const nowMs = Date.now();
    const hasDiskMode = this.adapter.capabilities.diskPresence;
    const canonicalReqCwd = opts.requestedCwd ? canonicalizeCwdWithHome(opts.requestedCwd, null) : null;

    for (const row of this.store.getRawSessionsForReconcile()) {
      const sid = row.sessionId;
      if (IGNORED_PROBE_SESSION_IDS.has(sid)) continue;
      if (presentSet.has(sid)) {
        this.store.markSeenInUpstreamList(sid);
        this.noDiskMissCounts.delete(sid);
        continue;
      }
      if (this.isSessionActivelyBusy(sid)) {
        continue;
      }

      if (hasDiskMode) {
        if (this.adapter.checkSessionDiskPresence?.(sid)) {
          this.store.markSeenOnDisk(sid);
          continue;
        }
        if (isBlankFreshRow(row, nowMs)) {
          continue;
        }
        this.evictDeletedSession(sid, 'disk_missing');
      } else {
        if (opts.isWatch) continue;
        if (canonicalReqCwd && row.cwd && canonicalReqCwd !== row.cwd) continue;
        if (!row.seenInUpstreamList && !row.seenOnDisk) continue;
        const nextMiss = (this.noDiskMissCounts.get(sid) || 0) + 1;
        if (nextMiss >= 2) {
          this.evictDeletedSession(sid, 'nodisk_two_misses');
        } else {
          this.noDiskMissCounts.set(sid, nextMiss);
        }
      }
    }
  }

  private handleBackgroundSessionList(payload: {
    sessions: Record<string, unknown>[];
    requestedCwd?: string | null;
    isWatch: boolean;
    hasCursor: boolean;
    hasNextCursor: boolean;
    scopeSessionIds?: ReadonlySet<string>;
  }): void {
    const filtered = payload.sessions.filter(
      (item) => !(typeof item?.sessionId === 'string' && this.deletedSessionIds.has(item.sessionId))
    );
    this.reconcileExternalDeletions(filtered, {
      isWatch: payload.isWatch,
      requestedCwd: payload.requestedCwd,
      hasCursor: payload.hasCursor,
      hasNextCursor: payload.hasNextCursor,
    });
    const merged = this.store
      .mergeListItems(filtered)
      .filter((item) => !(typeof item?.sessionId === 'string' && this.deletedSessionIds.has(String(item.sessionId))));
    const staleList = this.sync.observeSessionList(merged, Date.now(), {
      scopeSessionIds: payload.scopeSessionIds,
    });
    this.sendSessionStaleNotifications(staleList);
  }

  private handleWorkerExited(affectedSessionIds: readonly string[]): void {
    const completions = this.sync.markSessionsExited(affectedSessionIds);
    this.sendTurnCompletedNotifications(completions);
    for (const sid of affectedSessionIds) {
      this.adapter.syncSessionWatch?.(sid, false);
    }
  }

  private handlePromptTitleTrigger(sessionId: string, promptParams: unknown): void {
    if (!sessionId || IGNORED_PROBE_SESSION_IDS.has(sessionId) || !this.store.has(sessionId)) return;
    const promptText = extractPromptText(promptParams);
    if (!promptText) return;
    this.store.recordPromptFallbackTitle(sessionId, promptText);
    const claim = this.store.claimSummaryAttempt(sessionId);
    if (!claim.claimed) return;
    if (!this.titleSummary.enabled) {
      this.store.recordSummaryResult(sessionId, { status: 'skipped_disabled', aiTitle: null });
      return;
    }
    void this.titleSummary
      .summarizeTitle({ sessionId, promptText })
      .then((res) => {
        if (this.shuttingDown || !this.store.has(sessionId)) return;
        const outcome = this.store.recordSummaryResult(sessionId, {
          status: res.status,
          aiTitle: res.title,
        });
        if (outcome.shouldPushUpdate && !this.shuttingDown && this.store.has(sessionId)) {
          this.emitSessionInfoUpdate(sessionId, outcome.displayTitle);
        }
      })
      .catch(() => {
        if (!this.shuttingDown && this.store.has(sessionId)) {
          this.store.recordSummaryResult(sessionId, { status: 'fetch_error', aiTitle: null });
        }
      });
  }

  // --- Usage management ---
  private buildUsagePayload(snap: Record<string, unknown> | null, refreshing: boolean): Record<string, unknown> {
    const nowMs = Date.now();
    const fetchedAt = typeof snap?.fetchedAt === 'string' && snap.fetchedAt ? snap.fetchedAt : null;
    const fetchedMs = fetchedAt ? Date.parse(fetchedAt) : NaN;
    const ageSeconds =
      fetchedAt && Number.isFinite(fetchedMs) ? Math.max(0, Math.floor((nowMs - fetchedMs) / 1000)) : null;
    const payload: Record<string, unknown> = {
      fetchedAt,
      ageSeconds,
      ttlSeconds: DEFAULT_USAGE_TTL_SECONDS,
      refreshing: Boolean(refreshing),
      groups: Array.isArray(snap?.groups) ? snap.groups : [],
    };
    if (snap?.tier && typeof snap.tier === 'object') {
      payload.tier = snap.tier;
    }
    if (snap?.lastError && typeof snap.lastError === 'object') {
      payload.lastError = snap.lastError;
    }
    return payload;
  }

  private pushUsageUpdated(payload: Record<string, unknown>): void {
    if (this.shuttingDown) return;
    if (!this.activeConn || this.activeConn.preempted || !this.activeConn.usageEnabled || !this.activeConn.conn.isOpen()) {
      return;
    }
    this.activeConn.conn.sendText(
      JSON.stringify({
        jsonrpc: '2.0',
        method: 'nonlocal/usage_updated',
        params: payload,
      })
    );
  }

  private handleUsageTierObserved(tier: { name?: string; id?: string }): void {
    if (!tier || (!tier.name && !tier.id)) return;
    try {
      const existing = this.store.getUsageSnapshot() || {};
      const prevTier = existing.tier as { name?: string; id?: string } | undefined;
      if (prevTier && prevTier.name === tier.name && prevTier.id === tier.id) {
        return;
      }
      const nextSnap: Record<string, unknown> = {
        ...existing,
        tier,
      };
      this.store.saveUsageSnapshot(nextSnap);
      this.pushUsageUpdated(this.buildUsagePayload(nextSnap, Boolean(this.usageInFlight)));
    } catch {
      // isolate tier capture failures
    }
  }

  private isUsageSnapshotFresh(snap: Record<string, unknown> | null, nowMs: number = Date.now()): boolean {
    if (!snap || typeof snap.fetchedAt !== 'string' || !snap.fetchedAt) return false;
    const fetchedMs = Date.parse(snap.fetchedAt);
    if (!Number.isFinite(fetchedMs)) return false;
    if (fetchedMs > nowMs + DEFAULT_USAGE_CLOCK_SKEW_MS) return false;
    const ageSec = Math.max(0, Math.floor((nowMs - fetchedMs) / 1000));
    return ageSec < DEFAULT_USAGE_TTL_SECONDS;
  }

  private triggerUsageRefresh(): boolean {
    if (this.shuttingDown || !this.adapter.fetchUsage) return false;
    if (this.usageInFlight) return true;
    const nowMs = Date.now();
    const cooldown = this.config.adapter.antigravity.usageCooldownMs;
    if (this.usageLastFailureAt > 0 && nowMs - this.usageLastFailureAt < cooldown) {
      return false;
    }
    this.usageInFlight = (async () => {
      try {
        const outcome = await this.adapter.fetchUsage!();
        if (this.shuttingDown) return;
        const current = this.store.getUsageSnapshot() || {};
        let nextSnap: Record<string, unknown>;
        if (outcome.ok) {
          this.usageLastFailureAt = 0;
          nextSnap = {
            fetchedAt: outcome.fetchedAt,
            groups: outcome.groups ?? [],
            ...(current.tier ? { tier: current.tier } : {}),
          };
        } else {
          this.usageLastFailureAt = Date.now();
          nextSnap = {
            ...(current.fetchedAt ? { fetchedAt: current.fetchedAt } : {}),
            groups: Array.isArray(current.groups) ? current.groups : [],
            ...(current.tier ? { tier: current.tier } : {}),
            lastError: outcome.error,
          };
        }
        this.store.saveUsageSnapshot(nextSnap);
        this.pushUsageUpdated(this.buildUsagePayload(nextSnap, false));
      } catch {
        // isolate unexpected error
      } finally {
        this.usageInFlight = null;
      }
    })();
    return true;
  }

  // --- Adapter event handler ---
  private handleAdapterEvent(event: AdapterOutboundEvent): void {
    if (event.kind === 'response') {
      this.handleAdapterResponse(event);
      return;
    }

    if (event.kind === 'server_request') {
      this.sync.observeUpstreamMessage(event.message, null, { cwd: event.canonicalCwd });
      if (this.activeConn && !this.activeConn.preempted && this.activeConn.conn.isOpen()) {
        this.activeConn.conn.sendText(JSON.stringify(event.message));
      }
      return;
    }

    // Notification
    let outboundMsg = event.message;
    const notifParams = (outboundMsg.params && typeof outboundMsg.params === 'object'
      ? outboundMsg.params
      : {}) as Record<string, unknown>;
    const notifSid = typeof notifParams.sessionId === 'string' ? notifParams.sessionId : null;
    const notifUpdate = (notifParams.update && typeof notifParams.update === 'object'
      ? notifParams.update
      : undefined) as Record<string, unknown> | undefined;
    const updateType = (notifUpdate?.sessionUpdate ?? notifUpdate?.type ?? null) as string | null;

    if (outboundMsg.method === 'session/update' && updateType === 'session_info_update') {
      const upstreamTitle = notifUpdate?.title;
      let displayTitle: string | null = null;
      if (notifSid && this.store.has(notifSid)) {
        if (typeof upstreamTitle === 'string' && upstreamTitle.trim()) {
          this.store.updateSession(notifSid, { upstreamTitle });
        }
        displayTitle = this.store.getDisplayTitle(notifSid);
      }
      const cleanUpdate: Record<string, unknown> = { ...(notifUpdate || {}), title: displayTitle };
      delete cleanUpdate.prompt;
      delete cleanUpdate.rawTitle;
      outboundMsg = {
        ...outboundMsg,
        params: {
          ...notifParams,
          update: cleanUpdate,
        },
      };
    }

    if (event.suppressConfigUpdate) {
      this.sync.observeUpstreamMessage(outboundMsg, null, {
        cwd: event.canonicalCwd,
        suppressConfigUpdate: true,
        suppressNotification: event.suppressNotification,
      });
      if (event.suppressNotification) return;
    }

    const syncOutcome = event.suppressConfigUpdate
      ? null
      : this.sync.observeUpstreamMessage(outboundMsg, null, {
          cwd: event.canonicalCwd,
          suppressNotification: event.suppressNotification,
        });

    if (syncOutcome?.configSnapshot) {
      this.store.updateSession(syncOutcome.configSnapshot.sessionId, syncOutcome.configSnapshot);
    }

    const active = this.activeConn;
    const isOpen = Boolean(active && !active.preempted && active.conn.isOpen());
    const suppressedHandshakeWindow =
      isOpen &&
      !active!.bridgeSyncEnabled &&
      syncOutcome?.originConnId !== undefined &&
      syncOutcome.originConnId !== active!.connId;

    const liveUpdateSessionId =
      outboundMsg.method === 'session/update' && notifSid && !event.replayInFlight ? notifSid : null;

    if (isOpen && !suppressedHandshakeWindow) {
      if (
        active!.bridgeSyncEnabled &&
        typeof syncOutcome?.seq === 'number' &&
        outboundMsg.method === 'session/update'
      ) {
        const enriched = {
          ...outboundMsg,
          params: {
            ...notifParams,
            _meta: {
              ...(notifParams._meta && typeof notifParams._meta === 'object'
                ? (notifParams._meta as Record<string, unknown>)
                : {}),
              nonlocalSeq: syncOutcome.seq,
              ...(typeof syncOutcome.turnId === 'string' && syncOutcome.turnId.length > 0
                ? { nonlocalTurnId: syncOutcome.turnId }
                : {}),
            },
          },
        };
        active!.conn.sendText(JSON.stringify(enriched));
      } else {
        active!.conn.sendText(JSON.stringify(outboundMsg));
      }
      if (liveUpdateSessionId) {
        this.sync.recordLiveSessionUpdate(liveUpdateSessionId, Date.now(), {
          connId: active!.connId,
          updateType,
        });
      }
    } else if (liveUpdateSessionId) {
      this.sync.recordOfflineSessionUpdate(liveUpdateSessionId, Date.now(), { updateType });
    }
  }

  private handleAdapterResponse(event: AdapterOutboundEvent): void {
    const msg = event.message;
    const method = event.method;
    const reqSid = event.sessionId ?? null;

    // Short-circuit responses for evicted sessions BEFORE any state write
    if (
      reqSid &&
      method !== 'session/new' &&
      method !== 'session/create' &&
      !IGNORED_PROBE_SESSION_IDS.has(reqSid) &&
      (this.deletedSessionIds.has(reqSid) || !this.store.has(reqSid))
    ) {
      this.logger.log('info', 'rpc_resp_dropped', {
        reason: 'evicted_or_stale_shortcircuit',
        originConnId: event.connId ?? null,
        method,
        sessionId: reqSid,
      });
      return;
    }

    let outboundMsg = msg;
    const result = (msg.result && typeof msg.result === 'object' ? msg.result : null) as
      | Record<string, unknown>
      | null;

    if (
      (method === 'session/new' || method === 'session/create') &&
      !msg.error &&
      result &&
      typeof result.sessionId === 'string' &&
      result.sessionId.length > 0 &&
      !IGNORED_PROBE_SESSION_IDS.has(result.sessionId)
    ) {
      const sid = result.sessionId;
      const resolvedCwd = canonicalizeCwdWithHome(result.cwd, event.canonicalCwd ?? null);
      this.store.recordCreated({
        sessionId: sid,
        cwd: resolvedCwd,
        title: result.title,
        updatedAt: typeof result.updatedAt === 'string' ? result.updatedAt : undefined,
        modes: result.modes,
        models: result.models,
        configOptions: result.configOptions,
      });
      outboundMsg = this.sanitizeSessionResultPayload(msg, sid, resolvedCwd);
    } else if (
      (method === 'session/load' || method === 'session/resume') &&
      !msg.error &&
      result &&
      typeof result.sessionId === 'string' &&
      result.sessionId.length > 0 &&
      !IGNORED_PROBE_SESSION_IDS.has(result.sessionId)
    ) {
      const sid = result.sessionId;
      if (this.store.has(sid)) {
        if (event.restoredSnapshot) {
          this.store.updateSession(sid, {
            title: result.title,
            updatedAt: typeof result.updatedAt === 'string' ? result.updatedAt : undefined,
            ...(event.restoredSnapshot.models !== undefined ? { models: event.restoredSnapshot.models } : {}),
            ...(event.restoredSnapshot.configOptions !== undefined ? { configOptions: event.restoredSnapshot.configOptions } : {}),
            ...(event.restoredSnapshot.modes !== undefined ? { modes: event.restoredSnapshot.modes } : {}),
            ...(Array.isArray(event.restoredSnapshot.availableCommands)
              ? { availableCommands: event.restoredSnapshot.availableCommands }
              : {}),
          });
        } else {
          this.store.updateSession(sid, {
            title: result.title,
            updatedAt: typeof result.updatedAt === 'string' ? result.updatedAt : undefined,
            modes: result.modes,
            models: result.models,
            configOptions: result.configOptions,
          });
        }
      }
      outboundMsg = this.sanitizeSessionResultPayload(msg, sid);
    } else if (method === 'session/list' && !msg.error && result && Array.isArray(result.sessions)) {
      const pendingMeta =
        typeof event.clientReqId === 'string' ? this.gwPending.get(event.clientReqId) : undefined;
      const rawSessions = result.sessions as Record<string, unknown>[];
      const hasNextCursor = typeof result.nextCursor === 'string' && result.nextCursor.trim().length > 0;
      const filteredRaw = rawSessions.filter(
        (item) => !(typeof item?.sessionId === 'string' && this.deletedSessionIds.has(item.sessionId))
      );
      this.reconcileExternalDeletions(filteredRaw, {
        isWatch: false,
        requestedCwd: pendingMeta?.requestedCwd ?? event.canonicalCwd ?? null,
        hasCursor: Boolean(pendingMeta?.hasCursor),
        hasNextCursor,
      });
      const merged = this.store
        .mergeListItems(filteredRaw)
        .filter((item) => !(typeof item?.sessionId === 'string' && this.deletedSessionIds.has(String(item.sessionId))));
      outboundMsg = {
        ...msg,
        result: { ...result, sessions: merged },
      };
    }

    const pendingEntry =
      typeof event.clientReqId === 'string' ? this.gwPending.get(event.clientReqId) : undefined;
    if (typeof event.clientReqId === 'string') {
      this.gwPending.delete(event.clientReqId);
    }

    const syncId = typeof event.clientReqId === 'string' ? event.clientReqId : outboundMsg.id;
    const syncOutcome = this.sync.observeUpstreamMessage(
      syncId !== undefined ? { ...outboundMsg, id: syncId } : outboundMsg,
      { method, cwd: event.canonicalCwd },
      {
        cwd: event.canonicalCwd,
        suppressConfigUpdate: event.suppressConfigUpdate,
      }
    );

    if (event.restoredSnapshot && result && typeof result.sessionId === 'string') {
      this.sync.restoreSessionSnapshot(result.sessionId, event.restoredSnapshot);
    }

    if (syncOutcome?.configSnapshot) {
      this.store.updateSession(syncOutcome.configSnapshot.sessionId, syncOutcome.configSnapshot);
    } else if (method === 'session/prompt' && !outboundMsg.error && reqSid) {
      this.store.updateSession(reqSid, { updatedAt: new Date().toISOString() });
    }

    if (syncOutcome?.needsWatch && reqSid) {
      this.adapter.syncSessionWatch?.(reqSid, true);
    }

    const active = this.activeConn;
    const isStaleConn =
      !active || active.preempted || active.connId !== event.connId || !active.conn.isOpen();

    if (isStaleConn) {
      this.logger.log('info', 'rpc_resp_dropped', {
        reason: 'stale_or_preempted_conn',
        originConnId: event.connId ?? null,
        activeConnId: active?.connId ?? null,
        method,
        clientId: pendingEntry?.origClientId ?? event.clientReqId ?? null,
      });
      if (syncOutcome?.turnCompleted) {
        this.sendTurnCompletedNotifications([syncOutcome.turnCompleted]);
      }
      if (syncOutcome?.staleSessions) {
        this.sendSessionStaleNotifications(syncOutcome.staleSessions);
      }
      return;
    }

    const clientResp: Record<string, unknown> = {
      ...outboundMsg,
      id: pendingEntry ? pendingEntry.origClientId : (event.clientReqId ?? outboundMsg.id),
    };
    active!.conn.sendText(JSON.stringify(clientResp));

    const isLoadMethod = method === 'session/load' || method === 'session/resume';
    if (isLoadMethod && !clientResp.error) {
      const confirmedSid =
        (typeof (clientResp.result as Record<string, unknown> | undefined)?.sessionId === 'string'
          ? ((clientResp.result as Record<string, unknown>).sessionId as string)
          : null) || reqSid;
      if (confirmedSid) {
        this.sync.confirmSessionLoaded(confirmedSid, event.connId ?? null);
      }
    } else if (
      isLoadMethod &&
      clientResp.error &&
      reqSid &&
      this.adapter.capabilities.diskPresence &&
      this.store.has(reqSid) &&
      !this.adapter.checkSessionDiskPresence?.(reqSid)
    ) {
      const rows = this.store.getRawSessionsForReconcile();
      const row = rows.find((r) => r.sessionId === reqSid);
      if (!isBlankFreshRow(row)) {
        this.evictDeletedSession(reqSid, 'disk_missing_on_load');
      }
    }

    if (syncOutcome?.staleSessions) {
      this.sendSessionStaleNotifications(syncOutcome.staleSessions);
    }
  }

  // --- Client WS message handling ---
  private handleTransportConnection(conn: ClientConnection): void {
    const connId = ++this.nextConnId;
    const connState: ConnectionState = {
      connId,
      conn,
      preempted: false,
      bridgeSyncEnabled: false,
      usageEnabled: false,
      isDoctorProbe: false,
    };

    if (this.activeConn) {
      const prev = this.activeConn;
      prev.preempted = true;
      this.sync.handleConnectionClosed(prev.connId, { code: 4001, preempted: true });
      this.activeConn = connState;
      this.logger.log('info', 'ws_preempted', {
        originConnId: prev.connId,
        activeConnId: connId,
        code: 4001,
      });
      prev.conn.close(4001, 'preempted_by_new_connection');
    } else {
      this.activeConn = connState;
    }

    this.logger.log('info', 'ws_connected', { connId });

    conn.onMessage((text) => {
      if (connState.preempted || this.activeConn !== connState) return;
      this.handleClientMessage(connState, text);
    });

    conn.onError((err) => {
      this.logger.log('warn', 'ws_error', {
        connId,
        message: err?.message ?? String(err),
      });
    });

    conn.onClose((code, reason) => {
      this.sync.handleConnectionClosed(connId, { code, preempted: connState.preempted });
      if (this.activeConn === connState) {
        this.activeConn = null;
      }
      if (connState.isDoctorProbe) {
        void this.adapter.reclaimIdleFallbackIfProbeOnly?.();
      }
      this.logger.log('info', 'ws_closed', {
        connId,
        code,
        reason: connState.preempted ? 'preempted' : reason || 'closed',
      });
    });
  }

  private handleClientMessage(connState: ConnectionState, text: string): void {
    let msg: unknown;
    try {
      msg = JSON.parse(text);
    } catch {
      this.logger.log('warn', 'ws_invalid_json', {
        connId: connState.connId,
        bytes: Buffer.byteLength(text, 'utf8'),
      });
      connState.conn.sendText(
        JSON.stringify({
          jsonrpc: '2.0',
          id: null,
          error: { code: -32700, message: 'Parse error' },
        })
      );
      return;
    }

    if (!msg || typeof msg !== 'object' || Array.isArray(msg)) {
      connState.conn.sendText(
        JSON.stringify({
          jsonrpc: '2.0',
          id: null,
          error: { code: -32600, message: 'Invalid Request' },
        })
      );
      return;
    }

    const obj = msg as Record<string, unknown>;
    const hasMethod = typeof obj.method === 'string' && obj.method.length > 0;
    const hasId = obj.id !== undefined && obj.id !== null;
    const params = (obj.params && typeof obj.params === 'object' && !Array.isArray(obj.params)
      ? obj.params
      : {}) as Record<string, unknown>;
    const reqSessionId = typeof params.sessionId === 'string' && params.sessionId.length > 0 ? params.sessionId : null;
    const isProbeSession = IGNORED_PROBE_SESSION_IDS.has(reqSessionId ?? '');

    if (hasMethod && obj.method === 'nonlocal/sync') {
      if (!hasId) return;
      connState.bridgeSyncEnabled = true;
      const snapshot = this.sync.buildSyncSnapshot();
      for (const s of snapshot.sessions) {
        if (!s || typeof s !== 'object') continue;
        if ('title' in s) {
          s.title = this.store.has(String(s.sessionId)) ? this.store.getDisplayTitle(String(s.sessionId)) : null;
        }
        delete s.prompt;
        delete s.models;
        delete s.watchBaselineMs;
      }
      this.logger.log('info', 'nonlocal_sync', {
        connId: connState.connId,
        method: 'nonlocal/sync',
        clientId: obj.id,
        instanceId: snapshot.instanceId,
        count: snapshot.sessions.length,
      });
      connState.conn.sendText(JSON.stringify({ jsonrpc: '2.0', id: obj.id, result: snapshot }));
      return;
    }

    if (hasMethod && obj.method === 'nonlocal/rename_session') {
      if (
        typeof reqSessionId !== 'string' ||
        !reqSessionId.trim() ||
        isProbeSession ||
        this.deletedSessionIds.has(reqSessionId) ||
        !this.store.has(reqSessionId)
      ) {
        if (hasId) {
          this.sendJsonRpcError(connState, obj.id, -32602, 'Invalid params: session not accessible on this endpoint');
        }
        return;
      }
      const rawTitle = params.title;
      if (rawTitle !== undefined && rawTitle !== null && typeof rawTitle !== 'string') {
        if (hasId) {
          this.sendJsonRpcError(connState, obj.id, -32602, 'Invalid params: title must be string or null');
        }
        return;
      }
      const renamed = this.store.renameSession(reqSessionId, (rawTitle as string | null | undefined) ?? null)!;
      this.logger.log('info', 'nonlocal_rename_session', {
        connId: connState.connId,
        method: 'nonlocal/rename_session',
        sessionId: reqSessionId,
        reason: renamed.customTitle ? 'set_custom' : 'cleared_custom',
      });
      if (hasId) {
        connState.conn.sendText(
          JSON.stringify({
            jsonrpc: '2.0',
            id: obj.id,
            result: {
              sessionId: renamed.sessionId,
              title: renamed.title,
            },
          })
        );
      }
      this.emitSessionInfoUpdate(renamed.sessionId, renamed.title);
      return;
    }

    if (hasMethod && NO_ID_SILENT_DROP_METHODS.has(obj.method as string) && !hasId) {
      return;
    }

    if (hasMethod && obj.method === 'nonlocal/usage') {
      if (!this.adapter.capabilities.usage || !this.adapter.fetchUsage) {
        this.sendJsonRpcError(connState, obj.id, -32601, 'Method not found');
        return;
      }
      connState.usageEnabled = true;
      try {
        const snap = this.store.getUsageSnapshot();
        let refreshing = Boolean(this.usageInFlight);
        if (!this.isUsageSnapshotFresh(snap)) {
          refreshing = this.triggerUsageRefresh() || Boolean(this.usageInFlight);
        }
        const payload = this.buildUsagePayload(snap, refreshing);
        if (!connState.preempted && this.activeConn === connState && connState.conn.isOpen()) {
          connState.conn.sendText(JSON.stringify({ jsonrpc: '2.0', id: obj.id, result: payload }));
        }
      } catch {
        if (!connState.preempted && this.activeConn === connState && connState.conn.isOpen()) {
          this.sendJsonRpcError(connState, obj.id, -32603, 'Usage query failed');
        }
      }
      return;
    }

    if (hasMethod && obj.method === 'nonlocal/session_info') {
      if (!this.adapter.capabilities.sessionInfo || !this.adapter.readSessionInfo) {
        this.sendJsonRpcError(connState, obj.id, -32601, 'Method not found');
        return;
      }
      try {
        const safeCheck = this.adapter.isSafeSessionId ?? isSafeSessionIdDefault;
        if (
          typeof reqSessionId !== 'string' ||
          !reqSessionId.trim() ||
          isProbeSession ||
          !safeCheck(reqSessionId) ||
          this.deletedSessionIds.has(reqSessionId) ||
          !this.store.has(reqSessionId)
        ) {
          this.sendJsonRpcError(connState, obj.id, -32602, 'Invalid params: session not accessible on this endpoint');
          return;
        }
        const infoRow = this.store.getSessionInfoRow(reqSessionId);
        const diskInfo = this.adapter.readSessionInfo(reqSessionId);
        const resolvedUpstreamTitle = infoRow?.upstreamTitle || diskInfo.upstreamTitle || null;
        if (!connState.preempted && this.activeConn === connState && connState.conn.isOpen()) {
          connState.conn.sendText(
            JSON.stringify({
              jsonrpc: '2.0',
              id: obj.id,
              result: {
                sessionId: reqSessionId,
                displayTitle: infoRow?.displayTitle ?? null,
                upstreamTitle: resolvedUpstreamTitle,
                cwd: infoRow?.cwd ?? null,
                subagents: diskInfo.subagents,
              },
            })
          );
        }
      } catch {
        if (!connState.preempted && this.activeConn === connState && connState.conn.isOpen()) {
          this.sendJsonRpcError(connState, obj.id, -32603, 'Session info query failed');
        }
      }
      return;
    }

    if (hasMethod && obj.method === 'nonlocal/fs_list') {
      void (async () => {
        try {
          const result = await this.fsService.list(params);
          this.logger.log('info', 'nonlocal_fs_list', {
            connId: connState.connId,
            method: 'nonlocal/fs_list',
            count: result.entries.length,
            truncated: result.truncated,
          });
          if (!connState.preempted && this.activeConn === connState && connState.conn.isOpen()) {
            connState.conn.sendText(JSON.stringify({ jsonrpc: '2.0', id: obj.id, result }));
          }
        } catch (err) {
          const code = err instanceof FsRpcError ? err.rpcCode : -32603;
          const message = err instanceof FsRpcError ? err.message : 'Directory listing failed';
          this.logger.log('warn', 'nonlocal_fs_list', {
            connId: connState.connId,
            method: 'nonlocal/fs_list',
            errorCode: code,
          });
          if (!connState.preempted && this.activeConn === connState && connState.conn.isOpen()) {
            this.sendJsonRpcError(connState, obj.id, code, message);
          }
        }
      })();
      return;
    }

    if (hasMethod && obj.method === 'nonlocal/fs_read_file') {
      void (async () => {
        try {
          const result = await this.fsService.readFile(params);
          this.logger.log('info', 'nonlocal_fs_read_file', {
            connId: connState.connId,
            method: 'nonlocal/fs_read_file',
            kind: result.kind,
            bytes: result.bytesRead,
            truncated: result.truncated,
          });
          if (!connState.preempted && this.activeConn === connState && connState.conn.isOpen()) {
            connState.conn.sendText(JSON.stringify({ jsonrpc: '2.0', id: obj.id, result }));
          }
        } catch (err) {
          const code = err instanceof FsRpcError ? err.rpcCode : -32603;
          const message = err instanceof FsRpcError ? err.message : 'File read failed';
          this.logger.log('warn', 'nonlocal_fs_read_file', {
            connId: connState.connId,
            method: 'nonlocal/fs_read_file',
            errorCode: code,
          });
          if (!connState.preempted && this.activeConn === connState && connState.conn.isOpen()) {
            this.sendJsonRpcError(connState, obj.id, code, message);
          }
        }
      })();
      return;
    }

    if (hasMethod && obj.method === 'nonlocal/delete_session') {
      if (!this.adapter.capabilities.deleteSession || !this.adapter.deleteUpstreamSession) {
        this.sendJsonRpcError(connState, obj.id, -32601, 'Method not found');
        return;
      }
      if (!this.adapter.capabilities.diskPresence) {
        this.logger.log('warn', 'session_delete_rejected', {
          connId: connState.connId,
          reason: 'storage_unconfigured',
        });
        this.sendJsonRpcError(connState, obj.id, -32024, 'Upstream session storage directories are not configured');
        return;
      }
      const safeCheck = this.adapter.isSafeSessionId ?? isSafeSessionIdDefault;
      if (typeof reqSessionId !== 'string' || !reqSessionId.trim() || isProbeSession || !safeCheck(reqSessionId)) {
        this.logger.log('warn', 'session_delete_rejected', {
          connId: connState.connId,
          reason: 'invalid_session_id',
        });
        this.sendJsonRpcError(connState, obj.id, -32602, 'Invalid params: sessionId must be a valid non-probe session identifier');
        return;
      }

      if (this.isSessionActivelyBusy(reqSessionId)) {
        this.logger.log('warn', 'session_delete_rejected', {
          connId: connState.connId,
          sessionId: reqSessionId,
          reason: 'session_active',
        });
        this.sendJsonRpcError(connState, obj.id, -32021, 'Session or subagent is active or awaiting approval');
        return;
      }

      void this.enqueueSessionTask(reqSessionId, async () => {
        const sendOk = (result: unknown) => {
          if (!connState.preempted && this.activeConn === connState && connState.conn.isOpen()) {
            connState.conn.sendText(JSON.stringify({ jsonrpc: '2.0', id: obj.id, result }));
          }
        };
        const sendErr = (code: number, message: string) => {
          this.sendJsonRpcError(connState, obj.id, code, message);
        };

        if (!this.store.has(reqSessionId)) {
          if (
            this.deletedSessionIds.has(reqSessionId) ||
            !this.adapter.checkSessionDiskPresence?.(reqSessionId)
          ) {
            const warnings = this.adapter.cleanUpstreamCacheEntries?.([reqSessionId]) ?? [];
            this.logger.log('info', 'session_deleted', {
              connId: connState.connId,
              sessionId: reqSessionId,
              alreadyAbsent: true,
            });
            sendOk({
              sessionId: reqSessionId,
              deleted: true,
              alreadyAbsent: true,
              deletedSubagentIds: [],
              deletedSubagentCount: 0,
              warnings,
            });
            return;
          }
          this.logger.log('warn', 'session_delete_rejected', {
            connId: connState.connId,
            sessionId: reqSessionId,
            reason: 'external_session_rejected',
          });
          sendErr(-32602, 'Invalid params: session not accessible on this endpoint');
          return;
        }

        let preSubagentIds: string[] = [];
        try {
          const preInfo = this.adapter.readSessionInfo?.(reqSessionId, { strict: true }) ?? {
            upstreamTitle: null,
            subagents: [],
          };
          const staged = this.pendingDeleteSubagents.get(reqSessionId) || [];
          const merged = new Set<string>([
            ...staged,
            ...preInfo.subagents.map((s) => s.sessionId).filter((id) => safeCheck(id)),
          ]);
          merged.delete(reqSessionId);
          preSubagentIds = Array.from(merged);
        } catch (err) {
          if (isSqliteBusyErrorLike(err)) {
            this.logger.log('warn', 'session_delete_db_busy', { connId: connState.connId, sessionId: reqSessionId });
            sendErr(-32022, 'Host conversation database is busy; please retry');
          } else {
            sendErr(-32023, `Failed to inspect upstream session graph: ${err instanceof Error ? err.message : 'unknown error'}`);
          }
          return;
        }

        const preCheckIds = [reqSessionId, ...preSubagentIds];
        for (const id of preCheckIds) {
          if (this.isSessionActivelyBusy(id)) {
            this.logger.log('warn', 'session_delete_blocked_active', { connId: connState.connId, sessionId: reqSessionId });
            sendErr(-32021, 'Session or subagent is active or awaiting approval');
            return;
          }
        }

        const guardedIds = new Set(preCheckIds);
        for (const id of guardedIds) this.deletingSessionIds.add(id);

        try {
          await this.adapter.closeSessionBestEffort(reqSessionId, 2000);

          const deleteResult = this.adapter.deleteUpstreamSession!(reqSessionId, {
            isSessionProtected: (id) => this.sync.isSessionActiveOrPending(id),
            pendingSubagentIds: preSubagentIds,
            onResolvedSubagents: (subIds) => {
              const stagedList = Array.from(new Set([...preSubagentIds, ...subIds]));
              this.pendingDeleteSubagents.set(reqSessionId, stagedList);
              for (const sid of stagedList) {
                guardedIds.add(sid);
                this.deletingSessionIds.add(sid);
              }
            },
          });

          this.pendingDeleteSubagents.delete(reqSessionId);
          const evictedIds = [...deleteResult.deletedSubagentIds, reqSessionId];
          for (const id of evictedIds) {
            this.deletedSessionIds.add(id);
          }
          for (const subId of deleteResult.deletedSubagentIds) {
            this.evictDeletedSession(subId, 'user_deleted_subagent');
          }
          const mainEvicted = this.evictDeletedSession(reqSessionId, 'user_deleted');
          if (!mainEvicted) {
            this.sendSessionDeletedNotification(reqSessionId);
          }

          this.logger.log('info', 'session_deleted', {
            connId: connState.connId,
            sessionId: reqSessionId,
            deletedSubagentCount: deleteResult.deletedSubagentCount,
            alreadyAbsent: false,
          });
          sendOk(deleteResult);
        } catch (err) {
          const code = getRpcErrorCode(err, -32023);
          const message = err instanceof Error ? err.message : 'Failed to delete session';
          this.logger.log('warn', 'session_delete_rejected', {
            connId: connState.connId,
            sessionId: reqSessionId,
            errorCode: code,
          });
          sendErr(code, message);
        } finally {
          for (const id of guardedIds) this.deletingSessionIds.delete(id);
        }
      });
      return;
    }

    // Deleted tombstone interception
    if (
      hasMethod &&
      reqSessionId &&
      !isProbeSession &&
      this.deletedSessionIds.has(reqSessionId) &&
      ((obj.method as string).startsWith('session/') || !GLOBAL_PASSTHROUGH_METHODS.has(obj.method as string))
    ) {
      this.logger.log('warn', 'deleted_session_blocked', {
        connId: connState.connId,
        method: obj.method,
        sessionId: reqSessionId,
      });
      if (hasId) {
        this.sendJsonRpcError(connState, obj.id, -32602, 'Invalid params: session has been deleted');
      }
      if (obj.method === 'session/load' || obj.method === 'session/resume') {
        this.sendSessionDeletedNotification(reqSessionId);
      }
      return;
    }

    // Closed owned-session allowlist
    if (hasMethod && !isProbeSession) {
      const methodStr = obj.method as string;
      const isGlobalAllowed = GLOBAL_PASSTHROUGH_METHODS.has(methodStr);
      const isSessionScoped = methodStr.startsWith('session/') || reqSessionId !== null;
      if (!isGlobalAllowed && isSessionScoped && (!reqSessionId || !this.store.has(reqSessionId))) {
        this.logger.log('warn', 'allowlist_blocked', {
          connId: connState.connId,
          method: methodStr,
          ...(reqSessionId ? { sessionId: reqSessionId } : {}),
          reason: !reqSessionId ? 'missing_session_id' : 'external_session_rejected',
        });
        if (hasId) {
          this.sendJsonRpcError(connState, obj.id, -32602, 'Invalid params: session not accessible on this endpoint');
        }
        if (
          reqSessionId &&
          (methodStr === 'session/load' || methodStr === 'session/resume') &&
          this.adapter.capabilities.diskPresence &&
          !this.adapter.checkSessionDiskPresence?.(reqSessionId)
        ) {
          this.sendSessionDeletedNotification(reqSessionId);
        }
        return;
      }
    }

    // Client response to server-initiated request (e.g. session/request_permission)
    if (!hasMethod && hasId) {
      const handled = this.adapter.respondToServerRequest(obj.id as string | number, obj);
      if (handled) {
        this.sync.observeClientResponse(obj);
        return;
      }
    }

    if (!hasMethod) {
      connState.conn.sendText(
        JSON.stringify({
          jsonrpc: '2.0',
          id: null,
          error: { code: -32600, message: 'Invalid Request' },
        })
      );
      return;
    }

    const methodStr = obj.method as string;

    // Cache initialize payload synchronously (ignore doctor probe overwrite)
    let isDoctorProbeReq = false;
    if (methodStr === 'initialize') {
      const clientInfo = params.clientInfo as { name?: unknown } | undefined;
      if (clientInfo?.name === 'nonlocal-bridge-doctor') {
        connState.isDoctorProbe = true;
        isDoctorProbeReq = true;
      } else {
        this.cachedInitializeMsg = {
          method: 'initialize',
          params: structuredClone(params),
        };
      }
    }

    const allocGwReqId = (extra: { hasCursor?: boolean; requestedCwd?: string | null; isDoctorProbe?: boolean } = {}) => {
      if (!hasId) return undefined;
      const gwReqId = `gw_${++this.nextGwReqSeq}`;
      this.gwPending.set(gwReqId, {
        origClientId: obj.id,
        connId: connState.connId,
        method: methodStr,
        hasCursor: Boolean(extra.hasCursor),
        requestedCwd: extra.requestedCwd ?? null,
        isDoctorProbe: Boolean(extra.isDoctorProbe),
      });
      return gwReqId;
    };

    if (methodStr === 'session/new' || methodStr === 'session/create') {
      const cwdCheck = this.adapter.validateSessionCwd(params.cwd);
      if (!cwdCheck.ok) {
        this.logger.log('warn', 'invalid_project_cwd', {
          connId: connState.connId,
          method: methodStr,
          reason: 'invalid_or_missing_cwd',
        });
        if (hasId) {
          this.sendJsonRpcError(connState, obj.id, -32602, cwdCheck.message);
        }
        return;
      }
      const gwReqId = allocGwReqId();
      if (gwReqId) {
        this.sync.observeClientRequest(gwReqId, obj, connState.connId, { cwd: cwdCheck.cwd });
      }
      const dispatchReq: AdapterDispatchRequest = {
        connId: connState.connId,
        clientReqId: gwReqId,
        method: methodStr,
        canonicalCwd: cwdCheck.cwd,
        rawMessage: obj,
      };
      void this.adapter.dispatchClientMessage(dispatchReq);
      return;
    }

    if (
      methodStr === 'initialize' ||
      methodStr === 'session/list' ||
      isProbeSession ||
      (!methodStr.startsWith('session/') && !reqSessionId)
    ) {
      const hasCursor = typeof params.cursor === 'string' && params.cursor.trim().length > 0;
      const requestedCwd = typeof params.cwd === 'string' && params.cwd.trim().length > 0 ? params.cwd : null;
      const gwReqId = allocGwReqId({ hasCursor, requestedCwd, isDoctorProbe: isDoctorProbeReq });
      if (gwReqId) {
        this.sync.observeClientRequest(gwReqId, obj, connState.connId);
      }
      const dispatchReq: AdapterDispatchRequest = {
        connId: connState.connId,
        clientReqId: gwReqId,
        method: methodStr,
        sessionId: reqSessionId ?? undefined,
        rawMessage: obj,
        isDoctorProbe: isDoctorProbeReq,
      };
      void this.adapter.dispatchClientMessage(dispatchReq);
      return;
    }

    // Session-scoped requests
    let sessionTargetCwd = canonicalizeCwdWithHome(params.cwd, this.config.adapter.fallbackCwd) || this.config.adapter.fallbackCwd;
    if (reqSessionId && this.store.has(reqSessionId)) {
      const saved = this.store.get(reqSessionId)!;
      const cwdCheck = this.adapter.validateSessionCwd(saved.cwd);
      if (!cwdCheck.ok) {
        if (hasId) {
          this.sendJsonRpcError(connState, obj.id, -32602, cwdCheck.message);
        }
        return;
      }
      sessionTargetCwd = cwdCheck.cwd;
    }

    // Dormant owned session/cancel does not wake or spawn worker
    if (methodStr === 'session/cancel' && reqSessionId && this.store.has(reqSessionId)) {
      if (!this.adapter.hasLoadedSession(reqSessionId, sessionTargetCwd)) {
        this.logger.log('info', 'dormant_cancel_dropped', {
          connId: connState.connId,
          method: methodStr,
          sessionId: reqSessionId,
          reason: 'child_dormant',
        });
        if (hasId) {
          connState.conn.sendText(JSON.stringify({ jsonrpc: '2.0', id: obj.id, result: {} }));
        }
        return;
      }
    }

    const isExplicitLoad = methodStr === 'session/load' || methodStr === 'session/resume';
    const runSessionRequest = async () => {
      if (
        reqSessionId &&
        !isProbeSession &&
        (this.deletedSessionIds.has(reqSessionId) || this.deletingSessionIds.has(reqSessionId))
      ) {
        if (hasId) {
          this.sendJsonRpcError(connState, obj.id, -32602, 'Invalid params: session has been deleted');
        }
        return;
      }
      if (hasId && methodStr === 'session/prompt' && reqSessionId && this.store.has(reqSessionId)) {
        this.store.updateSession(reqSessionId, { updatedAt: new Date().toISOString() });
        this.handlePromptTitleTrigger(reqSessionId, params);
      }
      const gwReqId = allocGwReqId();
      if (gwReqId) {
        this.sync.observeClientRequest(gwReqId, obj, connState.connId, {
          cwd: sessionTargetCwd,
        });
      }
      await this.adapter.dispatchClientMessage({
        connId: connState.connId,
        clientReqId: gwReqId,
        method: methodStr,
        sessionId: reqSessionId ?? undefined,
        canonicalCwd: sessionTargetCwd,
        rawMessage: obj,
        isExplicitLoad,
      });
    };

    if (reqSessionId && methodStr !== 'session/cancel') {
      void this.enqueueSessionTask(reqSessionId, runSessionRequest);
    } else {
      void runSessionRequest();
    }
  }
}
