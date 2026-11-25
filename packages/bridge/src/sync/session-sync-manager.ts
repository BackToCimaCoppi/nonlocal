import { randomUUID } from 'node:crypto';

export const DEFAULT_SYNC_MAX_EVENTS_PER_TURN = 2000;
export const DEFAULT_SYNC_MAX_TURN_BYTES = 2 * 1024 * 1024;
export const DEFAULT_SYNC_WATCH_WINDOW_MS = 5 * 60 * 1000;
export const DEFAULT_SYNC_SETTLE_WINDOW_MS = 60 * 1000;
export const DEFAULT_SYNC_LIVE_DELIVERY_SKEW_MS = 2500;
export const IGNORED_PROBE_SESSION_IDS = new Set(['capability-probe']);
export const CONTENT_SESSION_UPDATE_TYPES = new Set([
  'agent_message_chunk',
  'user_message_chunk',
  'tool_call',
  'tool_call_update',
]);
const TERMINAL_TOOL_STATUSES = new Set(['completed', 'failed', 'error', 'cancelled']);

function idKey(id: unknown): string {
  return `${typeof id}:${String(id)}`;
}

function isIgnoredSessionId(sessionId: string | null | undefined): boolean {
  return typeof sessionId === 'string' && IGNORED_PROBE_SESSION_IDS.has(sessionId);
}

function deepClone<T>(value: T): T {
  if (value === undefined) return value;
  return structuredClone(value);
}

function estimateJsonBytes(value: unknown): number {
  return Buffer.byteLength(JSON.stringify(value), 'utf8');
}

function normalizeClientTurnId(meta: unknown): string | undefined {
  if (!meta || typeof meta !== 'object') return undefined;
  const raw = (meta as Record<string, unknown>).nonlocalClientTurnId;
  if (typeof raw !== 'string') return undefined;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function patchConfigOptionsForModel(
  configOptions: unknown[],
  targetModel: string
): unknown[] {
  const modelEntry = configOptions.find(
    (c) => c && typeof c === 'object' && (c as Record<string, unknown>).id === 'model'
  ) as { options?: Array<{ value?: unknown }> } | undefined;
  const options = Array.isArray(modelEntry?.options) ? modelEntry.options : [];
  let matchedFamily = '';
  for (const opt of options) {
    const val = opt?.value;
    if (typeof val !== 'string') continue;
    if (targetModel === val || targetModel.startsWith(val + '-')) {
      if (val.length > matchedFamily.length) matchedFamily = val;
    }
  }
  if (!matchedFamily) return configOptions;

  const thoughtSuffix = targetModel === matchedFamily ? '' : targetModel.slice(matchedFamily.length + 1);
  const patched: unknown[] = [];
  for (const item of configOptions) {
    if (!item || typeof item !== 'object') {
      patched.push(item);
      continue;
    }
    const obj = item as Record<string, unknown>;
    if (obj.id === 'model') {
      patched.push({ ...obj, currentValue: matchedFamily });
      continue;
    }
    if (obj.id === 'thought_level') {
      if (!thoughtSuffix) continue;
      const next: Record<string, unknown> = { ...obj, currentValue: thoughtSuffix };
      if (
        Array.isArray(obj.options) &&
        !obj.options.some((o) => o && typeof o === 'object' && (o as Record<string, unknown>).value === thoughtSuffix)
      ) {
        next.options = [...obj.options, { value: thoughtSuffix, name: thoughtSuffix }];
      }
      patched.push(next);
      continue;
    }
    patched.push(item);
  }
  return patched;
}

export interface TurnEventRecord {
  seq: number;
  method: 'session/update';
  params: unknown;
}

export interface PendingPermissionRecord {
  requestId: string | number;
  params: unknown;
}

interface InternalTurnState {
  turnId: string;
  clientTurnId?: string;
  status: 'active' | 'completed' | 'error';
  lastSeq: number;
  truncated: boolean;
  events: TurnEventRecord[];
  eventBytes: number;
  pendingPermissions: PendingPermissionRecord[];
  unresolvedToolCallIds: Set<string>;
  hasUnresolvedToolCalls: boolean;
  stopReason?: string;
  error?: { code: number; message: string };
  originConnId: number;
}

interface InternalSessionState {
  sessionId: string;
  cwd?: string;
  modes?: Record<string, unknown>;
  models?: Record<string, unknown>;
  configOptions?: unknown[];
  availableCommands?: unknown[];
  latestTurn?: InternalTurnState;
  lastActivityMs: number;
  watchBaselineMs: number;
  postPromptLiveDeliveredAt: number;
  postPromptUnconfirmedConnId: number | null;
  watchUntilMs: number;
}

export interface SessionSyncOptions {
  maxEventsPerTurn?: number;
  maxTurnBytes?: number;
  watchWindowMs?: number;
  settleWindowMs?: number;
  isSessionAllowed?: ((sessionId: string) => boolean) | null;
}

export class SessionSyncManager {
  private readonly safeMaxEvents: number;
  private readonly safeMaxBytes: number;
  private readonly safeWatchWindowMs: number;
  private readonly safeSettleWindowMs: number;
  private readonly isSessionAllowed: ((sessionId: string) => boolean) | null;
  private readonly instanceId: string;

  private readonly materializedSessionIds = new Set<string>();
  private readonly staleSessionIds = new Set<string>();
  private readonly sessions = new Map<string, InternalSessionState>();
  private readonly pendingRequestMeta = new Map<
    string,
    { method: string; sessionId: string | null; cwd?: string; internal?: boolean; configId?: unknown; value?: unknown; modeId?: string; modelId?: string }
  >();
  private readonly pendingTurnByUpstreamId = new Map<string, { sessionId: string; turnId: string }>();
  private readonly pendingPermissionToSession = new Map<string, string>();

  constructor(opts: SessionSyncOptions = {}) {
    this.safeMaxEvents = Math.max(1, Math.floor(Number(opts.maxEventsPerTurn) || DEFAULT_SYNC_MAX_EVENTS_PER_TURN));
    this.safeMaxBytes = Math.max(128, Math.floor(Number(opts.maxTurnBytes) || DEFAULT_SYNC_MAX_TURN_BYTES));
    this.safeWatchWindowMs = Math.max(50, Math.floor(Number(opts.watchWindowMs) || DEFAULT_SYNC_WATCH_WINDOW_MS));
    this.safeSettleWindowMs = Math.max(50, Math.floor(Number(opts.settleWindowMs) || DEFAULT_SYNC_SETTLE_WINDOW_MS));
    this.isSessionAllowed = opts.isSessionAllowed ?? null;
    this.instanceId = randomUUID();
  }

  getInstanceId(): string {
    return this.instanceId;
  }

  private canExposeSession(sessionId: string | null | undefined): sessionId is string {
    if (!sessionId || isIgnoredSessionId(sessionId)) return false;
    return typeof this.isSessionAllowed === 'function' ? Boolean(this.isSessionAllowed(sessionId)) : true;
  }

  private getOrCreateSession(sessionId: string, now: number = Date.now()): InternalSessionState {
    let sess = this.sessions.get(sessionId);
    if (!sess) {
      sess = {
        sessionId,
        lastActivityMs: 0,
        watchBaselineMs: now,
        postPromptLiveDeliveredAt: 0,
        postPromptUnconfirmedConnId: null,
        watchUntilMs: 0,
      };
      this.sessions.set(sessionId, sess);
    }
    return sess;
  }

  private convergeWatchState(sess: InternalSessionState | undefined, now: number = Date.now()): void {
    if (!sess) return;
    if (sess.watchUntilMs > 0 && sess.watchUntilMs <= now) {
      sess.watchUntilMs = 0;
    }
    if (
      sess.latestTurn &&
      sess.latestTurn.status !== 'active' &&
      sess.latestTurn.hasUnresolvedToolCalls === true &&
      sess.watchUntilMs <= now
    ) {
      sess.latestTurn.hasUnresolvedToolCalls = false;
      sess.latestTurn.unresolvedToolCallIds.clear();
    }
  }

  private clearPendingPermissionsForSession(sessionId: string): void {
    for (const [permKey, ownerSid] of this.pendingPermissionToSession.entries()) {
      if (ownerSid === sessionId) {
        this.pendingPermissionToSession.delete(permKey);
      }
    }
    const sess = this.sessions.get(sessionId);
    if (sess?.latestTurn) {
      sess.latestTurn.pendingPermissions = [];
    }
  }

  private buildTurnCompletedPayload(sessionId: string, turn: InternalTurnState) {
    const payload: Record<string, unknown> = {
      instanceId: this.instanceId,
      sessionId,
      turnId: turn.turnId,
      status: turn.status,
    };
    if (turn.clientTurnId !== undefined) payload.clientTurnId = turn.clientTurnId;
    if (turn.stopReason !== undefined) payload.stopReason = turn.stopReason;
    if (turn.error !== undefined) payload.error = deepClone(turn.error);
    return payload;
  }

  private serializeTurnSnapshot(turn: InternalTurnState | undefined) {
    if (!turn) return undefined;
    const snap: Record<string, unknown> = {
      turnId: turn.turnId,
      status: turn.status,
      lastSeq: turn.lastSeq,
      truncated: turn.truncated,
      events: deepClone(turn.events),
      pendingPermissions: deepClone(turn.pendingPermissions),
    };
    if (turn.clientTurnId !== undefined) snap.clientTurnId = turn.clientTurnId;
    if (turn.stopReason !== undefined) snap.stopReason = turn.stopReason;
    if (turn.error !== undefined) snap.error = deepClone(turn.error);
    if (turn.hasUnresolvedToolCalls === true) snap.hasUnresolvedToolCalls = true;
    return snap;
  }

  observeClientRequest(
    upstreamId: string | number,
    msg: Record<string, unknown>,
    connId: number,
    meta: { internal?: boolean; cwd?: string } = {}
  ): void {
    if (!msg || typeof msg !== 'object' || typeof msg.method !== 'string') return;
    const params = (msg.params && typeof msg.params === 'object' ? msg.params : {}) as Record<string, unknown>;
    const sessionId = typeof params.sessionId === 'string' ? params.sessionId : null;
    if (isIgnoredSessionId(sessionId)) return;
    const key = idKey(upstreamId);
    const now = Date.now();

    if (meta.internal) {
      this.pendingRequestMeta.set(key, {
        method: msg.method,
        sessionId,
        cwd: meta.cwd,
        internal: true,
      });
      return;
    }

    if (
      msg.method === 'session/new' ||
      msg.method === 'session/create' ||
      msg.method === 'session/load' ||
      msg.method === 'session/resume'
    ) {
      this.pendingRequestMeta.set(key, {
        method: msg.method,
        sessionId,
        cwd: meta.cwd,
      });
      return;
    }

    if (msg.method === 'session/prompt' && sessionId) {
      this.clearPendingPermissionsForSession(sessionId);
      this.staleSessionIds.delete(sessionId);
      const sess = this.getOrCreateSession(sessionId, now);
      if (meta.cwd) sess.cwd = meta.cwd;
      sess.lastActivityMs = now;
      sess.watchBaselineMs = Math.max(sess.watchBaselineMs || 0, now);
      sess.postPromptLiveDeliveredAt = 0;
      sess.postPromptUnconfirmedConnId = null;
      sess.watchUntilMs = 0;
      const clientTurnId = normalizeClientTurnId(params._meta);
      const turn: InternalTurnState = {
        turnId: randomUUID(),
        clientTurnId,
        status: 'active',
        lastSeq: 0,
        truncated: false,
        events: [],
        eventBytes: 0,
        pendingPermissions: [],
        unresolvedToolCallIds: new Set<string>(),
        hasUnresolvedToolCalls: false,
        originConnId: connId,
      };
      sess.latestTurn = turn;
      this.pendingTurnByUpstreamId.set(key, { sessionId, turnId: turn.turnId });
      return;
    }

    if (msg.method === 'session/set_config_option' && sessionId) {
      this.pendingRequestMeta.set(key, {
        method: msg.method,
        sessionId,
        configId: params.configId,
        value: deepClone(params.value),
      });
      return;
    }

    if (msg.method === 'session/set_mode' && sessionId) {
      this.pendingRequestMeta.set(key, {
        method: msg.method,
        sessionId,
        modeId: typeof params.modeId === 'string' ? params.modeId : undefined,
      });
      return;
    }

    if (msg.method === 'session/set_model' && sessionId) {
      this.pendingRequestMeta.set(key, {
        method: msg.method,
        sessionId,
        modelId: typeof params.modelId === 'string' ? params.modelId : undefined,
      });
    }
  }

  observeClientResponse(msg: Record<string, unknown>): void {
    if (!msg || typeof msg !== 'object' || typeof msg.method === 'string') return;
    if (msg.id === undefined || msg.id === null) return;
    const permKey = idKey(msg.id);
    const sessionId = this.pendingPermissionToSession.get(permKey);
    if (!sessionId) return;
    this.pendingPermissionToSession.delete(permKey);

    const sess = this.sessions.get(sessionId);
    if (!sess?.latestTurn) return;
    sess.latestTurn.pendingPermissions = sess.latestTurn.pendingPermissions.filter(
      (entry) => idKey(entry.requestId) !== permKey
    );
  }

  private syncCurrentModelIdFromConfigOptions(sess: InternalSessionState): void {
    if (!Array.isArray(sess.configOptions)) return;
    const avail = Array.isArray(sess.models?.availableModels)
      ? (sess.models.availableModels as Array<{ modelId?: string }>)
      : [];
    if (avail.length === 0) return;

    const modelOpt = sess.configOptions.find(
      (c) => c && typeof c === 'object' && (c as Record<string, unknown>).id === 'model'
    ) as { currentValue?: unknown } | undefined;
    const modelVal = typeof modelOpt?.currentValue === 'string' ? modelOpt.currentValue.trim() : '';
    if (!modelVal) return;

    const thoughtOpt = sess.configOptions.find(
      (c) => c && typeof c === 'object' && (c as Record<string, unknown>).id === 'thought_level'
    ) as { currentValue?: unknown } | undefined;
    const thoughtVal = typeof thoughtOpt?.currentValue === 'string' ? thoughtOpt.currentValue.trim() : '';

    let resolved: string | null = null;
    if (thoughtVal && !modelVal.endsWith(`-${thoughtVal}`)) {
      const combined = `${modelVal}-${thoughtVal}`;
      if (avail.some((m) => m?.modelId === combined)) {
        resolved = combined;
      }
    }
    if (!resolved && avail.some((m) => m?.modelId === modelVal)) {
      resolved = modelVal;
    }
    if (resolved) {
      sess.models = { ...(sess.models || {}), currentModelId: resolved };
    }
  }

  private applyConfigOptionFallback(sess: InternalSessionState, configId: unknown, value: unknown): void {
    if (!Array.isArray(sess.configOptions) || typeof configId !== 'string') return;
    sess.configOptions = sess.configOptions.map((item) => {
      if (item && typeof item === 'object' && (item as Record<string, unknown>).id === configId) {
        return { ...(item as Record<string, unknown>), currentValue: deepClone(value) };
      }
      return item;
    });
    if (configId === 'mode' && typeof value === 'string' && sess.modes && typeof sess.modes === 'object') {
      sess.modes = { ...sess.modes, currentModeId: value };
    }
    this.syncCurrentModelIdFromConfigOptions(sess);
  }

  private appendTurnEvent(turn: InternalTurnState, msg: Record<string, unknown>): number {
    const seq = ++turn.lastSeq;
    const eventRecord: TurnEventRecord = {
      seq,
      method: 'session/update',
      params: deepClone(msg.params),
    };
    const eventSize = estimateJsonBytes(eventRecord);
    turn.events.push(eventRecord);
    turn.eventBytes += eventSize;

    while (
      turn.events.length > 0 &&
      (turn.events.length > this.safeMaxEvents || turn.eventBytes > this.safeMaxBytes)
    ) {
      turn.truncated = true;
      const evicted = turn.events.shift()!;
      turn.eventBytes = Math.max(0, turn.eventBytes - estimateJsonBytes(evicted));
    }
    return seq;
  }

  private trackToolCallState(turn: InternalTurnState, update: Record<string, unknown> | undefined): void {
    const updateType = update?.sessionUpdate;
    if (updateType !== 'tool_call' && updateType !== 'tool_call_update') return;
    const toolCallId =
      typeof update?.toolCallId === 'string' && update.toolCallId.length > 0 ? update.toolCallId : null;
    if (!toolCallId) return;
    const status = typeof update?.status === 'string' ? update.status : '';
    if (TERMINAL_TOOL_STATUSES.has(status)) {
      turn.unresolvedToolCallIds.delete(toolCallId);
    } else if (updateType === 'tool_call' || status === 'pending' || status === 'in_progress') {
      turn.unresolvedToolCallIds.add(toolCallId);
    }
  }

  observeSessionList(
    sessionItems: unknown,
    now: number = Date.now(),
    scope: { scopeSessionIds?: ReadonlySet<string> } = {}
  ): Array<Record<string, unknown>> {
    if (!Array.isArray(sessionItems)) return [];
    const staleNotifications: Array<Record<string, unknown>> = [];
    const seenIds = new Set<string>();
    const scopeIds = scope.scopeSessionIds ?? null;

    for (const rawItem of sessionItems) {
      const item = rawItem as Record<string, unknown> | undefined;
      const sid = typeof item?.sessionId === 'string' ? item.sessionId : null;
      if (!this.canExposeSession(sid)) continue;
      seenIds.add(sid);
      const sess = this.sessions.get(sid);
      if (!sess) continue;
      if (scopeIds && !scopeIds.has(sid)) continue;

      this.convergeWatchState(sess, now);

      const updatedMs = typeof item?.updatedAt === 'string' ? Date.parse(item.updatedAt) : NaN;
      if (!Number.isFinite(updatedMs)) {
        if (sess.watchUntilMs > now) {
          sess.watchUntilMs = 0;
        }
        continue;
      }

      if (sess.latestTurn?.status === 'active') {
        continue;
      }

      const baselineSecMs = Math.floor((sess.watchBaselineMs || 0) / 1000) * 1000;
      const isWatched = sess.watchUntilMs > now;
      const minAdvanceMs = isWatched ? 1000 : 2001;

      if (updatedMs >= baselineSecMs + minAdvanceMs) {
        const isCoveredByLiveDelivery =
          sess.postPromptLiveDeliveredAt > 0 &&
          updatedMs <= sess.postPromptLiveDeliveredAt + DEFAULT_SYNC_LIVE_DELIVERY_SKEW_MS;
        if (isCoveredByLiveDelivery) {
          sess.watchBaselineMs = Math.max(sess.watchBaselineMs || 0, updatedMs);
          sess.lastActivityMs = Math.max(sess.lastActivityMs || 0, updatedMs);
          if (isWatched) {
            sess.watchUntilMs = Math.max(sess.watchUntilMs, now + this.safeSettleWindowMs);
          }
          continue;
        }
        sess.watchBaselineMs = Math.max(sess.watchBaselineMs || 0, updatedMs);
        sess.lastActivityMs = Math.max(sess.lastActivityMs || 0, updatedMs);
        this.materializedSessionIds.delete(sid);
        this.staleSessionIds.add(sid);
        if (sess.latestTurn) {
          sess.latestTurn = undefined;
        }
        if (isWatched) {
          sess.watchUntilMs = Math.max(sess.watchUntilMs, now + this.safeSettleWindowMs);
        }
        staleNotifications.push({
          instanceId: this.instanceId,
          sessionId: sid,
          updatedAt: item!.updatedAt,
          reason: 'background_updated',
        });
      }
    }

    for (const sess of this.sessions.values()) {
      this.convergeWatchState(sess, now);
      if (sess.watchUntilMs <= 0) continue;
      if (scopeIds && !scopeIds.has(sess.sessionId)) continue;
      if (!seenIds.has(sess.sessionId)) {
        sess.watchUntilMs = 0;
      }
    }

    return staleNotifications;
  }

  hasWatchedSessions(now: number = Date.now(), cwdFilter: string | null = null): boolean {
    for (const sess of this.sessions.values()) {
      if (cwdFilter && sess.cwd && sess.cwd !== cwdFilter) continue;
      this.convergeWatchState(sess, now);
      if (sess.watchUntilMs > now && this.canExposeSession(sess.sessionId)) return true;
    }
    return false;
  }

  isSessionWatched(sessionId: string, now: number = Date.now()): boolean {
    const sess = this.sessions.get(sessionId);
    if (!sess) return false;
    this.convergeWatchState(sess, now);
    return sess.watchUntilMs > now && this.canExposeSession(sessionId);
  }

  private buildConfigSnapshot(sessionId: string, sess: InternalSessionState) {
    const snapshot: {
      sessionId: string;
      modes?: Record<string, unknown>;
      models?: Record<string, unknown>;
      configOptions?: unknown[];
      availableCommands?: unknown[];
    } = {
      sessionId,
      modes: deepClone(sess.modes),
      models: deepClone(sess.models),
      configOptions: deepClone(sess.configOptions),
    };
    if (sess.availableCommands !== undefined) {
      snapshot.availableCommands = deepClone(sess.availableCommands);
    }
    return snapshot;
  }

  observeUpstreamMessage(
    msg: Record<string, unknown>,
    entry: { method?: string; cwd?: string } | null = null,
    meta: { cwd?: string; suppressConfigUpdate?: boolean; suppressNotification?: boolean } = {}
  ): {
    staleSessions?: Array<Record<string, unknown>>;
    configSnapshot?: ReturnType<SessionSyncManager['buildConfigSnapshot']>;
    turnCompleted?: Record<string, unknown>;
    needsWatch?: boolean;
    seq?: number;
    originConnId?: number;
    turnId?: string;
    pendingPermissionAdded?: boolean;
  } | null {
    if (!msg || typeof msg !== 'object') return null;
    const now = Date.now();

    const isResponse =
      typeof msg.method !== 'string' && msg.id !== undefined && msg.id !== null;

    if (isResponse) {
      const key = idKey(msg.id);
      const reqMeta = this.pendingRequestMeta.get(key);
      this.pendingRequestMeta.delete(key);
      const turnMeta = this.pendingTurnByUpstreamId.get(key);
      this.pendingTurnByUpstreamId.delete(key);

      const method = entry?.method ?? reqMeta?.method;
      const resolvedCwd = meta.cwd ?? entry?.cwd ?? reqMeta?.cwd;

      if (
        method === 'session/new' ||
        method === 'session/create' ||
        method === 'session/load' ||
        method === 'session/resume'
      ) {
        const result = (msg.result && typeof msg.result === 'object' ? msg.result : null) as
          | Record<string, unknown>
          | null;
        if (
          !msg.error &&
          result &&
          typeof result.sessionId === 'string' &&
          result.sessionId.length > 0 &&
          !isIgnoredSessionId(result.sessionId)
        ) {
          const sid = result.sessionId;
          const isNewMethod = method === 'session/new' || method === 'session/create';
          if (!isNewMethod && !this.canExposeSession(sid)) {
            return null;
          }
          this.materializedSessionIds.add(sid);
          this.staleSessionIds.delete(sid);
          const sess = this.getOrCreateSession(sid, now);
          if (resolvedCwd) sess.cwd = resolvedCwd;
          sess.postPromptLiveDeliveredAt = 0;
          sess.watchBaselineMs = Math.max(sess.watchBaselineMs || 0, now);
          if (!meta.suppressConfigUpdate) {
            if (result.modes !== undefined) sess.modes = deepClone(result.modes as Record<string, unknown>);
            if (result.models !== undefined) sess.models = deepClone(result.models as Record<string, unknown>);
            if (Array.isArray(result.configOptions)) sess.configOptions = deepClone(result.configOptions);
          }
        }
        return null;
      }

      if (method === 'session/list' && !msg.error) {
        const result = msg.result as { sessions?: unknown } | undefined;
        if (Array.isArray(result?.sessions)) {
          const staleSessions = this.observeSessionList(result.sessions, now);
          return staleSessions.length > 0 ? { staleSessions } : null;
        }
        return null;
      }

      if (method === 'session/set_config_option' && !msg.error && reqMeta?.sessionId) {
        if (!this.canExposeSession(reqMeta.sessionId)) return null;
        const sess = this.getOrCreateSession(reqMeta.sessionId, now);
        if (!meta.suppressConfigUpdate) {
          const result = msg.result as { configOptions?: unknown } | undefined;
          if (Array.isArray(result?.configOptions)) {
            sess.configOptions = deepClone(result.configOptions);
            this.syncCurrentModelIdFromConfigOptions(sess);
          } else {
            this.applyConfigOptionFallback(sess, reqMeta.configId, reqMeta.value);
          }
          return { configSnapshot: this.buildConfigSnapshot(reqMeta.sessionId, sess) };
        }
        return null;
      }

      if (method === 'session/set_mode' && !msg.error && reqMeta?.sessionId) {
        if (!this.canExposeSession(reqMeta.sessionId)) return null;
        const sess = this.getOrCreateSession(reqMeta.sessionId, now);
        if (!meta.suppressConfigUpdate) {
          const result = msg.result as { modes?: Record<string, unknown> } | undefined;
          if (result?.modes !== undefined) {
            sess.modes = deepClone(result.modes);
          } else if (reqMeta.modeId) {
            sess.modes = { ...(sess.modes || {}), currentModeId: reqMeta.modeId };
          }
          return { configSnapshot: this.buildConfigSnapshot(reqMeta.sessionId, sess) };
        }
        return null;
      }

      if (method === 'session/set_model' && !msg.error && reqMeta?.sessionId) {
        if (!this.canExposeSession(reqMeta.sessionId)) return null;
        const sess = this.getOrCreateSession(reqMeta.sessionId, now);
        if (!meta.suppressConfigUpdate) {
          const result = msg.result as { models?: Record<string, unknown>; configOptions?: unknown } | undefined;
          if (result?.models !== undefined) {
            sess.models = deepClone(result.models);
          } else if (reqMeta.modelId) {
            sess.models = { ...(sess.models || {}), currentModelId: reqMeta.modelId };
          }
          if (Array.isArray(result?.configOptions)) {
            sess.configOptions = deepClone(result.configOptions);
          } else if (reqMeta.modelId && Array.isArray(sess.configOptions)) {
            sess.configOptions = patchConfigOptionsForModel(sess.configOptions, reqMeta.modelId);
          }
          return { configSnapshot: this.buildConfigSnapshot(reqMeta.sessionId, sess) };
        }
        return null;
      }

      if (turnMeta && (!method || method === 'session/prompt')) {
        const sess = this.sessions.get(turnMeta.sessionId);
        if (!sess?.latestTurn || sess.latestTurn.turnId !== turnMeta.turnId) {
          return null;
        }
        this.clearPendingPermissionsForSession(turnMeta.sessionId);
        sess.lastActivityMs = now;
        sess.watchBaselineMs = Math.max(sess.watchBaselineMs || 0, now);
        sess.postPromptLiveDeliveredAt = 0;
        if (msg.error) {
          const errObj = msg.error as { code?: unknown; message?: unknown };
          sess.latestTurn.status = 'error';
          sess.latestTurn.hasUnresolvedToolCalls = false;
          sess.latestTurn.error = {
            code: Number.isFinite(Number(errObj.code)) ? Number(errObj.code) : -32000,
            message: String(errObj.message ?? 'Prompt failed'),
          };
        } else {
          const result = msg.result as { stopReason?: unknown } | undefined;
          sess.latestTurn.status = 'completed';
          sess.latestTurn.stopReason =
            typeof result?.stopReason === 'string' ? result.stopReason : 'end_turn';
          const hasUnresolved = sess.latestTurn.unresolvedToolCallIds.size > 0;
          sess.latestTurn.hasUnresolvedToolCalls = hasUnresolved;
          if (hasUnresolved) {
            sess.watchUntilMs = now + this.safeWatchWindowMs;
          }
        }
        return {
          turnCompleted: this.buildTurnCompletedPayload(sess.sessionId, sess.latestTurn),
          needsWatch: sess.watchUntilMs > now,
        };
      }

      return null;
    }

    const params = (msg.params && typeof msg.params === 'object' ? msg.params : {}) as Record<string, unknown>;
    const sessionId = typeof params.sessionId === 'string' ? params.sessionId : null;
    if (!this.canExposeSession(sessionId)) return null;

    if (msg.method === 'session/update') {
      if (meta.suppressNotification) return null;
      const update = (params.update && typeof params.update === 'object' ? params.update : undefined) as
        | Record<string, unknown>
        | undefined;
      const updateType = (update?.sessionUpdate ?? update?.type) as string | undefined;
      const existing = this.sessions.get(sessionId);

      if (!meta.suppressConfigUpdate) {
        if (updateType === 'config_option_update' && Array.isArray(update?.configOptions)) {
          const sess = existing || this.getOrCreateSession(sessionId, now);
          sess.configOptions = deepClone(update.configOptions);
          this.syncCurrentModelIdFromConfigOptions(sess);
        } else if (updateType === 'current_mode_update') {
          const modeId =
            typeof update?.currentModeId === 'string'
              ? update.currentModeId
              : typeof update?.modeId === 'string'
                ? update.modeId
                : null;
          if (modeId) {
            const sess = existing || this.getOrCreateSession(sessionId, now);
            sess.modes = { ...(sess.modes || {}), currentModeId: modeId };
          }
        } else if (updateType === 'available_commands_update' && Array.isArray(update?.availableCommands)) {
          const sess = existing || this.getOrCreateSession(sessionId, now);
          sess.availableCommands = deepClone(update.availableCommands);
        }
      }

      const activeSess = this.sessions.get(sessionId);
      let configSnapshot: ReturnType<SessionSyncManager['buildConfigSnapshot']> | undefined;
      if (
        !meta.suppressConfigUpdate &&
        (updateType === 'config_option_update' ||
          updateType === 'current_mode_update' ||
          updateType === 'available_commands_update')
      ) {
        const snapSess = this.sessions.get(sessionId);
        if (snapSess) {
          configSnapshot = this.buildConfigSnapshot(sessionId, snapSess);
        }
      }
      if (activeSess?.latestTurn?.status === 'active') {
        activeSess.lastActivityMs = now;
        activeSess.watchBaselineMs = Math.max(activeSess.watchBaselineMs || 0, now);
        this.trackToolCallState(activeSess.latestTurn, update);
        const seq = this.appendTurnEvent(activeSess.latestTurn, msg);
        return {
          seq,
          originConnId: activeSess.latestTurn.originConnId,
          turnId: activeSess.latestTurn.turnId,
          ...(configSnapshot ? { configSnapshot } : {}),
        };
      }
      return configSnapshot ? { configSnapshot } : null;
    }

    if (typeof msg.method === 'string' && msg.id !== undefined && msg.id !== null) {
      const activeSess = this.sessions.get(sessionId);
      if (activeSess?.latestTurn?.status === 'active') {
        const permKey = idKey(msg.id);
        this.pendingPermissionToSession.set(permKey, sessionId);
        activeSess.latestTurn.pendingPermissions = activeSess.latestTurn.pendingPermissions.filter(
          (entry) => idKey(entry.requestId) !== permKey
        );
        activeSess.latestTurn.pendingPermissions.push({
          requestId: msg.id as string | number,
          params: deepClone(msg.params),
        });
        return {
          originConnId: activeSess.latestTurn.originConnId,
          turnId: activeSess.latestTurn.turnId,
          pendingPermissionAdded: true,
        };
      }
    }

    return null;
  }

  markSessionMaterialized(sessionId: string, cwd?: string): void {
    if (!this.canExposeSession(sessionId)) return;
    const now = Date.now();
    this.materializedSessionIds.add(sessionId);
    this.staleSessionIds.delete(sessionId);
    const sess = this.getOrCreateSession(sessionId, now);
    if (cwd) sess.cwd = cwd;
  }

  private isContentUpdateType(updateType: string | null | undefined): boolean {
    if (updateType === null || updateType === undefined) return true;
    return CONTENT_SESSION_UPDATE_TYPES.has(updateType);
  }

  private transitionUnconfirmedPostPromptToStale(sess: InternalSessionState): void {
    sess.postPromptUnconfirmedConnId = null;
    sess.postPromptLiveDeliveredAt = 0;
    this.materializedSessionIds.delete(sess.sessionId);
    this.staleSessionIds.add(sess.sessionId);
    if (sess.latestTurn && sess.latestTurn.status !== 'active') {
      sess.latestTurn = undefined;
    }
  }

  recordLiveSessionUpdate(
    sessionId: string,
    now: number = Date.now(),
    opts: { connId?: number | null; updateType?: string | null } = {}
  ): void {
    if (!this.canExposeSession(sessionId)) return;
    if (!this.isContentUpdateType(opts.updateType)) return;
    const sess = this.sessions.get(sessionId);
    if (!sess) return;
    sess.watchBaselineMs = Math.max(sess.watchBaselineMs || 0, now);
    sess.lastActivityMs = Math.max(sess.lastActivityMs || 0, now);
    if (sess.latestTurn?.status !== 'active') {
      sess.postPromptLiveDeliveredAt = now;
      if (sess.watchUntilMs > 0) {
        sess.watchUntilMs = Math.max(sess.watchUntilMs, now + this.safeSettleWindowMs);
      }
      if (this.materializedSessionIds.has(sessionId)) {
        this.staleSessionIds.delete(sessionId);
      }
      if (opts.connId !== null && opts.connId !== undefined) {
        sess.postPromptUnconfirmedConnId = opts.connId;
      }
    }
  }

  recordOfflineSessionUpdate(
    sessionId: string,
    now: number = Date.now(),
    opts: { updateType?: string | null } = {}
  ): void {
    if (!this.canExposeSession(sessionId)) return;
    if (!this.isContentUpdateType(opts.updateType)) return;
    const sess = this.sessions.get(sessionId);
    if (!sess || sess.latestTurn?.status === 'active') return;
    sess.postPromptLiveDeliveredAt = 0;
    sess.postPromptUnconfirmedConnId = null;
    sess.watchBaselineMs = Math.max(sess.watchBaselineMs || 0, now);
    sess.lastActivityMs = Math.max(sess.lastActivityMs || 0, now);
    this.materializedSessionIds.delete(sessionId);
    this.staleSessionIds.add(sessionId);
    if (sess.latestTurn) {
      sess.latestTurn = undefined;
    }
  }

  handleConnectionClosed(
    connId: number | null | undefined,
    opts: { code?: number; preempted?: boolean } = {}
  ): void {
    if (connId === null || connId === undefined) return;
    const isAbnormalOrPreempted = Boolean(opts.preempted) || (opts.code ?? 1006) !== 1000;
    for (const sess of this.sessions.values()) {
      if (sess.postPromptUnconfirmedConnId !== connId) continue;
      if (sess.latestTurn?.status === 'active') continue;
      if (isAbnormalOrPreempted) {
        this.transitionUnconfirmedPostPromptToStale(sess);
      } else {
        sess.postPromptUnconfirmedConnId = null;
      }
    }
  }

  confirmSessionLoaded(sessionId: string, connId: number | null = null): void {
    if (typeof sessionId !== 'string' || !sessionId.trim()) return;
    const sess = this.sessions.get(sessionId);
    if (!sess) return;
    if (connId === null || sess.postPromptUnconfirmedConnId === connId || sess.postPromptUnconfirmedConnId !== null) {
      sess.postPromptUnconfirmedConnId = null;
    }
  }

  restoreSessionSnapshot(
    sessionId: string,
    snapshot: {
      modes?: Record<string, unknown>;
      models?: Record<string, unknown>;
      configOptions?: unknown[];
      availableCommands?: unknown[];
    } | null | undefined
  ): void {
    if (!this.canExposeSession(sessionId) || !snapshot) return;
    const sess = this.getOrCreateSession(sessionId, Date.now());
    if (snapshot.modes !== undefined && snapshot.modes !== null) {
      sess.modes = deepClone(snapshot.modes);
    }
    if (snapshot.models !== undefined && snapshot.models !== null) {
      sess.models = deepClone(snapshot.models);
    }
    if (Array.isArray(snapshot.configOptions)) {
      sess.configOptions = deepClone(snapshot.configOptions);
    }
    if (Array.isArray(snapshot.availableCommands)) {
      sess.availableCommands = deepClone(snapshot.availableCommands);
    }
  }

  markSessionsExited(
    affectedSessionIds: ReadonlySet<string> | readonly string[],
    errorInfo: { code: number; message: string } = { code: -32000, message: 'ACP child process exited unexpectedly' }
  ): Array<Record<string, unknown>> {
    const affectedSet = affectedSessionIds instanceof Set ? affectedSessionIds : new Set(affectedSessionIds);
    const completions: Array<Record<string, unknown>> = [];

    for (const [key, reqMeta] of this.pendingRequestMeta.entries()) {
      if (reqMeta.sessionId && affectedSet.has(reqMeta.sessionId)) {
        this.pendingRequestMeta.delete(key);
      }
    }
    for (const [key, turnMeta] of this.pendingTurnByUpstreamId.entries()) {
      if (affectedSet.has(turnMeta.sessionId)) {
        this.pendingTurnByUpstreamId.delete(key);
      }
    }

    for (const sid of affectedSet) {
      const sess = this.sessions.get(sid);
      if (!sess) continue;
      this.clearPendingPermissionsForSession(sid);
      const hadActiveTurn = sess.latestTurn?.status === 'active';
      if (hadActiveTurn && sess.latestTurn) {
        sess.latestTurn.status = 'error';
        sess.latestTurn.hasUnresolvedToolCalls = false;
        sess.latestTurn.error = {
          code: Number.isFinite(Number(errorInfo.code)) ? Number(errorInfo.code) : -32000,
          message: String(errorInfo.message ?? 'ACP child process exited unexpectedly'),
        };
        completions.push(this.buildTurnCompletedPayload(sid, sess.latestTurn));
      }
      if (sess.postPromptUnconfirmedConnId !== null && !hadActiveTurn) {
        this.transitionUnconfirmedPostPromptToStale(sess);
      } else {
        this.materializedSessionIds.delete(sid);
      }
      sess.watchUntilMs = 0;
    }

    return completions;
  }

  buildSyncSnapshot(now: number = Date.now()) {
    const serializedSessions: Array<Record<string, unknown>> = [];
    for (const sess of this.sessions.values()) {
      if (!this.canExposeSession(sess.sessionId)) continue;
      this.convergeWatchState(sess, now);
      const entry: Record<string, unknown> = { sessionId: sess.sessionId };
      if (Number.isFinite(sess.lastActivityMs) && sess.lastActivityMs > 0) {
        entry.lastActivityAt = new Date(sess.lastActivityMs).toISOString();
      }
      if (sess.modes !== undefined) entry.modes = deepClone(sess.modes);
      if (sess.configOptions !== undefined) entry.configOptions = deepClone(sess.configOptions);
      if (Array.isArray(sess.availableCommands)) {
        entry.availableCommands = deepClone(sess.availableCommands);
      }
      if (sess.latestTurn) {
        entry.latestTurn = this.serializeTurnSnapshot(sess.latestTurn);
      }
      serializedSessions.push(entry);
    }

    return {
      instanceId: this.instanceId,
      materializedSessionIds: Array.from(this.materializedSessionIds).filter((sid) => this.canExposeSession(sid)),
      staleSessionIds: Array.from(this.staleSessionIds).filter((sid) => this.canExposeSession(sid)),
      sessions: serializedSessions,
    };
  }

  deleteSession(sessionId: string): void {
    if (typeof sessionId !== 'string' || !sessionId.trim()) return;
    this.clearPendingPermissionsForSession(sessionId);
    this.materializedSessionIds.delete(sessionId);
    this.staleSessionIds.delete(sessionId);
    this.sessions.delete(sessionId);
    for (const [key, meta] of this.pendingRequestMeta.entries()) {
      if (meta?.sessionId === sessionId) this.pendingRequestMeta.delete(key);
    }
    for (const [key, meta] of this.pendingTurnByUpstreamId.entries()) {
      if (meta?.sessionId === sessionId) this.pendingTurnByUpstreamId.delete(key);
    }
  }

  isSessionActiveOrPending(sessionId: string): boolean {
    if (typeof sessionId !== 'string' || !sessionId.trim()) return false;
    const sess = this.sessions.get(sessionId);
    if (sess?.latestTurn?.status === 'active') return true;
    if (Array.isArray(sess?.latestTurn?.pendingPermissions) && sess.latestTurn.pendingPermissions.length > 0) {
      return true;
    }
    for (const meta of this.pendingTurnByUpstreamId.values()) {
      if (meta?.sessionId === sessionId) return true;
    }
    for (const ownerSid of this.pendingPermissionToSession.values()) {
      if (ownerSid === sessionId) return true;
    }
    return false;
  }
}
