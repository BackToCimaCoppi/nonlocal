export interface AdapterCapabilities {
  readonly usage: boolean;
  readonly sessionInfo: boolean;
  readonly deleteSession: boolean;
  readonly diskPresence: boolean;
}

export interface SavedSessionSnapshot {
  readonly sessionId: string;
  readonly cwd: string;
  readonly modes?: Record<string, unknown>;
  readonly models?: Record<string, unknown>;
  readonly configOptions?: unknown[];
  readonly availableCommands?: unknown[];
}

export interface AdapterDispatchRequest {
  readonly connId: number;
  readonly clientReqId?: string | number;
  readonly method: string;
  readonly sessionId?: string;
  readonly canonicalCwd?: string;
  readonly rawMessage: Record<string, unknown>;
  readonly isExplicitLoad?: boolean;
  readonly isDoctorProbe?: boolean;
}

export interface AdapterOutboundEvent {
  readonly kind: 'response' | 'notification' | 'server_request';
  readonly connId?: number;
  readonly clientReqId?: string | number;
  readonly method?: string;
  readonly sessionId?: string;
  readonly canonicalCwd?: string;
  readonly isSessionActivity?: boolean;
  readonly isExplicitLoad?: boolean;
  readonly isDoctorProbe?: boolean;
  readonly message: Record<string, unknown>;
  readonly suppressConfigUpdate?: boolean;
  readonly suppressNotification?: boolean;
  readonly replayInFlight?: boolean;
  readonly explicitLoadSettled?: boolean;
  readonly capturedCommands?: unknown[];
  readonly restoredSnapshot?: {
    models?: Record<string, unknown>;
    configOptions?: unknown[];
    modes?: Record<string, unknown>;
    availableCommands?: unknown[];
  };
}

export interface DeleteUpstreamOptions {
  readonly isSessionProtected: (sessionId: string) => boolean;
  readonly pendingSubagentIds?: readonly string[];
  readonly onResolvedSubagents?: (subIds: string[]) => void;
}

export interface DeleteUpstreamResult {
  readonly sessionId: string;
  readonly deleted: true;
  readonly alreadyAbsent: boolean;
  readonly deletedSubagentIds: string[];
  readonly deletedSubagentCount: number;
  readonly warnings: string[];
}

export interface UsageBucket {
  readonly id: string;
  readonly name: string;
  readonly window: string;
  readonly remainingFraction: number;
  readonly resetTime?: string;
}

export interface UsageGroup {
  readonly name: string;
  readonly description?: string;
  readonly buckets: UsageBucket[];
}

export interface UsageFetchOutcome {
  readonly ok: boolean;
  readonly fetchedAt?: string;
  readonly groups?: UsageGroup[];
  readonly error?: {
    readonly code: string;
    readonly message: string;
    readonly failedAt: string;
  };
}

export interface UpstreamSessionInfo {
  readonly upstreamTitle: string | null;
  readonly subagents: Array<{
    readonly sessionId: string;
    readonly upstreamTitle: string | null;
    readonly depth: number;
  }>;
}

export interface AdapterHostContext {
  getSessionSnapshot(sessionId: string): SavedSessionSnapshot | null;
  isSessionOwned(sessionId: string): boolean;
  isSessionDeleted(sessionId: string): boolean;
  isSessionBusy(sessionId: string): boolean;
  getCachedInitializeMsg(): Record<string, unknown> | null;
  onAdapterMessage(event: AdapterOutboundEvent): void;
  onSessionCommandsCaptured?(sessionId: string, commands: unknown[]): void;
  onSessionWakeRestored?(
    sessionId: string,
    canonicalCwd: string,
    restored: {
      models?: Record<string, unknown>;
      configOptions?: unknown[];
      modes?: Record<string, unknown>;
      availableCommands?: unknown[];
    }
  ): void;
  onUsageTierObserved(tier: { name?: string; id?: string }): void;
  onBackgroundSessionList(payload: {
    sessions: Record<string, unknown>[];
    requestedCwd?: string | null;
    isWatch: boolean;
    hasCursor: boolean;
    hasNextCursor: boolean;
    scopeSessionIds?: ReadonlySet<string>;
  }): void;
  onSessionMissingOnWake?(sessionId: string): void;
  onWorkerExited(affectedSessionIds: readonly string[]): void;
}

export interface AgentAdapter {
  readonly type: 'antigravity' | 'generic-acp';
  readonly capabilities: AdapterCapabilities;

  start(host: AdapterHostContext): Promise<void>;
  stop(): Promise<void>;
  isHealthy(): boolean;
  validateSessionCwd(rawCwd: unknown): { ok: true; cwd: string } | { ok: false; message: string };
  hasLoadedSession(sessionId: string, canonicalCwd: string): boolean;
  dispatchClientMessage(req: AdapterDispatchRequest): Promise<void>;
  respondToServerRequest(rewrittenId: string | number, rawResponse: Record<string, unknown>): boolean;
  closeSessionBestEffort(sessionId: string, timeoutMs?: number): Promise<void>;
  reclaimIdleFallbackIfProbeOnly?(): Promise<void>;
  syncSessionWatch?(sessionId: string, watchActive: boolean): void;

  fetchUsage?(): Promise<UsageFetchOutcome>;
  abortUsage?(): void;
  readSessionInfo?(sessionId: string, opts?: { strict?: boolean }): UpstreamSessionInfo;
  checkSessionDiskPresence?(sessionId: string): boolean;
  isSafeSessionId?(sessionId: string): boolean;
  deleteUpstreamSession?(sessionId: string, opts: DeleteUpstreamOptions): DeleteUpstreamResult;
  cleanUpstreamCacheEntries?(sessionIds: string[]): string[];
}
