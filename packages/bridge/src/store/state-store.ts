import { createHash } from 'node:crypto';
import { chmodSync, mkdirSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve as resolvePath } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import type { SanitizedLogger } from '../log/logger.js';

export const IGNORED_PROBE_SESSION_IDS = new Set(['capability-probe']);

function expandHomeCwd(rawPath: string, homeDir: string = homedir()): string {
  const trimmed = rawPath.trim();
  if (trimmed === '~') return homeDir;
  if (trimmed.startsWith('~/')) return join(homeDir, trimmed.slice(2));
  return trimmed;
}

function canonicalizeCwdSafe(rawCwd: string | null | undefined, fallbackCwd: string | null = null): string | null {
  const candidate = typeof rawCwd === 'string' && rawCwd.trim().length > 0 ? rawCwd.trim() : fallbackCwd;
  if (!candidate) return null;
  const expanded = expandHomeCwd(candidate);
  const resolved = resolvePath(expanded);
  try {
    return realpathSync(resolved);
  } catch {
    return resolved;
  }
}

function parseTimestampMs(iso: unknown): number {
  if (typeof iso !== 'string' || !iso) return NaN;
  const ms = Date.parse(iso);
  return Number.isFinite(ms) ? ms : NaN;
}

function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== 'object') {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return '[' + value.map((item) => canonicalJson(item === undefined ? null : item)).join(',') + ']';
  }
  const obj = value as Record<string, unknown>;
  const keys = Object.keys(obj)
    .filter((k) => obj[k] !== undefined)
    .sort();
  return '{' + keys.map((k) => `${JSON.stringify(k)}:${canonicalJson(obj[k])}`).join(',') + '}';
}

function sha256Hex(text: string): string {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

export function normalizeOptionalTitle(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

export function extractPromptText(params: unknown): string {
  if (!params || typeof params !== 'object') return '';
  const prompt = (params as Record<string, unknown>).prompt;
  let raw = '';
  if (typeof prompt === 'string') {
    raw = prompt;
  } else if (Array.isArray(prompt)) {
    const parts: string[] = [];
    for (const block of prompt) {
      if (
        block &&
        typeof block === 'object' &&
        (block as Record<string, unknown>).type === 'text' &&
        typeof (block as Record<string, unknown>).text === 'string'
      ) {
        parts.push((block as Record<string, unknown>).text as string);
      }
    }
    raw = parts.join(' ');
  }
  return raw.replace(/\s+/g, ' ').trim();
}

export function sliceFallbackTitle(promptText: string): string | null {
  if (typeof promptText !== 'string') return null;
  const normalized = promptText.replace(/\s+/g, ' ').trim();
  if (!normalized) return null;
  const sliced = Array.from(normalized).slice(0, 30).join('').trim();
  return sliced || null;
}

export function computeDisplayTitle(row: Record<string, unknown> | null | undefined): string | null {
  if (!row || typeof row !== 'object') return null;
  const custom = normalizeOptionalTitle(row.custom_title ?? row.customTitle);
  if (custom) return custom;
  const ai = normalizeOptionalTitle(row.ai_title ?? row.aiTitle);
  if (ai) return ai;
  const fallback = normalizeOptionalTitle(row.fallback_title ?? row.fallbackTitle);
  if (fallback) return fallback;
  return null;
}

interface CapSplit {
  hash: string | null;
  catalog: unknown;
  selected: string | Record<string, unknown> | null;
}

function splitCapabilityCatalog(kind: string, value: unknown): CapSplit {
  if (value === null || value === undefined) return { hash: null, catalog: null, selected: null };
  if (kind === 'models' && typeof value === 'object' && !Array.isArray(value)) {
    const catalog = structuredClone(value) as Record<string, unknown>;
    const selected = typeof catalog.currentModelId === 'string' && catalog.currentModelId ? catalog.currentModelId : null;
    delete catalog.currentModelId;
    return { hash: sha256Hex('models:' + canonicalJson(catalog)), catalog, selected };
  }
  if (kind === 'modes' && typeof value === 'object' && !Array.isArray(value)) {
    const catalog = structuredClone(value) as Record<string, unknown>;
    const selected = typeof catalog.currentModeId === 'string' && catalog.currentModeId ? catalog.currentModeId : null;
    delete catalog.currentModeId;
    return { hash: sha256Hex('modes:' + canonicalJson(catalog)), catalog, selected };
  }
  if (kind === 'configOptions' && Array.isArray(value)) {
    const selectedMap: Record<string, unknown> = {};
    const catalog = value.map((item) => {
      if (!item || typeof item !== 'object') return item;
      const copy = structuredClone(item) as Record<string, unknown>;
      if (typeof copy.id === 'string' && copy.currentValue !== undefined) {
        selectedMap[copy.id] = copy.currentValue;
      }
      delete copy.currentValue;
      return copy;
    });
    return {
      hash: sha256Hex('configOptions:' + canonicalJson(catalog)),
      catalog,
      selected: Object.keys(selectedMap).length > 0 ? selectedMap : {},
    };
  }
  if (kind === 'availableCommands' && Array.isArray(value)) {
    const catalog = structuredClone(value);
    return {
      hash: sha256Hex('availableCommands:' + canonicalJson(catalog)),
      catalog,
      selected: null,
    };
  }
  return { hash: null, catalog: null, selected: null };
}

export interface StoredSessionRecord {
  cwd: string;
  createdAt: string;
  updatedAt: string;
  upstreamTitle: string | null;
  customTitle: string | null;
  aiTitle: string | null;
  fallbackTitle: string | null;
  title: string | null;
  summaryAttempted: boolean;
  summaryStatus: string | null;
  modes?: Record<string, unknown>;
  models?: Record<string, unknown>;
  configOptions?: unknown[];
  availableCommands?: unknown[];
}

export interface ReconcileSessionRow {
  sessionId: string;
  cwd: string;
  createdAt: string | null;
  updatedAt: string;
  upstreamTitle: string | null;
  customTitle: string | null;
  aiTitle: string | null;
  fallbackTitle: string | null;
  seenInUpstreamList: boolean;
  seenOnDisk: boolean;
}

export interface StateStoreOptions {
  stateDir: string;
  defaultFallbackCwd?: string;
  logger?: SanitizedLogger;
}

export class StateStore {
  readonly dbPath: string;
  private readonly db: DatabaseSync;
  private readonly defaultFallbackCwd: string;

  private readonly stmtInsertCap;
  private readonly stmtGetCap;
  private readonly stmtHasSession;
  private readonly stmtGetSession;
  private readonly stmtAllSessions;
  private readonly stmtCountSessions;
  private readonly stmtInsertIgnoreSession;

  constructor(opts: StateStoreOptions) {
    this.defaultFallbackCwd = opts.defaultFallbackCwd ?? '/tmp';
    this.dbPath = join(opts.stateDir, 'bridge-state.db');

    mkdirSync(opts.stateDir, { recursive: true, mode: 0o700 });
    try {
      chmodSync(opts.stateDir, 0o700);
    } catch {
      // ignore
    }

    let db: DatabaseSync | undefined;
    try {
      db = new DatabaseSync(this.dbPath);
      db.exec('PRAGMA busy_timeout = 3000;');
      db.exec('PRAGMA journal_mode = DELETE;');
      db.exec('PRAGMA synchronous = FULL;');

      const qcRows = db.prepare('PRAGMA quick_check;').all() as Array<{ quick_check?: string }>;
      const qcOk = qcRows.length === 1 && qcRows[0]?.quick_check === 'ok';
      if (!qcOk) {
        throw new Error('PRAGMA quick_check did not return ok');
      }

      const metaTable = db
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'meta'")
        .get();
      if (metaTable) {
        const verRow = db.prepare("SELECT value FROM meta WHERE key = 'schema_version'").get() as
          | { value?: string }
          | undefined;
        if (verRow && verRow.value !== '1') {
          throw new Error(`Unsupported bridge-state.db schema_version "${String(verRow.value)}"`);
        }
      }

      db.exec(`
        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS capability_snapshots (
          hash TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          payload_json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sessions (
          session_id TEXT PRIMARY KEY,
          cwd TEXT NOT NULL,
          created_at TEXT,
          updated_at TEXT NOT NULL,
          upstream_title TEXT DEFAULT NULL,
          custom_title TEXT DEFAULT NULL,
          ai_title TEXT DEFAULT NULL,
          fallback_title TEXT DEFAULT NULL,
          summary_attempted INTEGER NOT NULL DEFAULT 0,
          summary_status TEXT DEFAULT NULL,
          selected_model_id TEXT DEFAULT NULL,
          selected_mode_id TEXT DEFAULT NULL,
          selected_config_json TEXT DEFAULT NULL,
          models_hash TEXT DEFAULT NULL,
          modes_hash TEXT DEFAULT NULL,
          config_options_hash TEXT DEFAULT NULL,
          commands_hash TEXT DEFAULT NULL,
          seen_in_upstream_list INTEGER NOT NULL DEFAULT 0,
          seen_on_disk INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS usage_snapshot (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          payload_json TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      `);

      const sessionCols = db.prepare('PRAGMA table_info(sessions)').all() as Array<{ name?: string }>;
      if (!sessionCols.some((col) => col.name === 'commands_hash')) {
        db.exec('ALTER TABLE sessions ADD COLUMN commands_hash TEXT DEFAULT NULL;');
      }
      if (!sessionCols.some((col) => col.name === 'seen_in_upstream_list')) {
        db.exec('ALTER TABLE sessions ADD COLUMN seen_in_upstream_list INTEGER NOT NULL DEFAULT 0;');
      }
      if (!sessionCols.some((col) => col.name === 'seen_on_disk')) {
        db.exec('ALTER TABLE sessions ADD COLUMN seen_on_disk INTEGER NOT NULL DEFAULT 0;');
      }

      db.prepare("INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', '1')").run();
      chmodSync(this.dbPath, 0o600);
      this.db = db;
    } catch (err) {
      try {
        db?.close();
      } catch {
        // ignore close failure
      }
      throw new Error(
        `Fail-closed loading bridge-state.db (${this.dbPath}): ${err instanceof Error ? err.message : String(err)}`
      );
    }

    this.stmtInsertCap = this.db.prepare(
      'INSERT OR IGNORE INTO capability_snapshots (hash, kind, payload_json) VALUES (?, ?, ?)'
    );
    this.stmtGetCap = this.db.prepare('SELECT payload_json FROM capability_snapshots WHERE hash = ?');
    this.stmtHasSession = this.db.prepare('SELECT 1 AS ok FROM sessions WHERE session_id = ?');
    this.stmtGetSession = this.db.prepare('SELECT * FROM sessions WHERE session_id = ?');
    this.stmtAllSessions = this.db.prepare('SELECT * FROM sessions');
    this.stmtCountSessions = this.db.prepare('SELECT COUNT(*) AS cnt FROM sessions');
    this.stmtInsertIgnoreSession = this.db.prepare(`
      INSERT OR IGNORE INTO sessions (
        session_id, cwd, created_at, updated_at, upstream_title,
        custom_title, ai_title, fallback_title, summary_attempted, summary_status,
        selected_model_id, selected_mode_id, selected_config_json,
        models_hash, modes_hash, config_options_hash, commands_hash
      ) VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, 0, NULL, ?, ?, ?, ?, ?, ?, ?)
    `);
  }

  private storeCapabilityCatalog(kind: string, value: unknown): CapSplit {
    const split = splitCapabilityCatalog(kind, value);
    if (split.hash && split.catalog !== null) {
      this.stmtInsertCap.run(split.hash, kind, JSON.stringify(split.catalog));
    }
    return split;
  }

  private hydrateCapability(row: Record<string, unknown>) {
    let models: Record<string, unknown> | undefined;
    if (typeof row.models_hash === 'string' && row.models_hash) {
      const capRow = this.stmtGetCap.get(row.models_hash) as { payload_json?: string } | undefined;
      if (capRow?.payload_json) {
        models = JSON.parse(capRow.payload_json) as Record<string, unknown>;
        if (typeof row.selected_model_id === 'string' && row.selected_model_id) {
          models.currentModelId = row.selected_model_id;
        }
      }
    }

    let modes: Record<string, unknown> | undefined;
    if (typeof row.modes_hash === 'string' && row.modes_hash) {
      const capRow = this.stmtGetCap.get(row.modes_hash) as { payload_json?: string } | undefined;
      if (capRow?.payload_json) {
        modes = JSON.parse(capRow.payload_json) as Record<string, unknown>;
        if (typeof row.selected_mode_id === 'string' && row.selected_mode_id) {
          modes.currentModeId = row.selected_mode_id;
        }
      }
    }

    let configOptions: unknown[] | undefined;
    if (typeof row.config_options_hash === 'string' && row.config_options_hash) {
      const capRow = this.stmtGetCap.get(row.config_options_hash) as { payload_json?: string } | undefined;
      if (capRow?.payload_json) {
        const selectedMap = typeof row.selected_config_json === 'string' && row.selected_config_json
          ? (JSON.parse(row.selected_config_json) as Record<string, unknown>)
          : {};
        configOptions = (JSON.parse(capRow.payload_json) as unknown[]).map((item) => {
          if (item && typeof item === 'object' && typeof (item as Record<string, unknown>).id === 'string') {
            const id = (item as Record<string, unknown>).id as string;
            if (Object.hasOwn(selectedMap, id)) {
              return { ...(item as Record<string, unknown>), currentValue: selectedMap[id] };
            }
          }
          return item;
        });
      }
    }

    let availableCommands: unknown[] | undefined;
    if (typeof row.commands_hash === 'string' && row.commands_hash) {
      const capRow = this.stmtGetCap.get(row.commands_hash) as { payload_json?: string } | undefined;
      if (capRow?.payload_json) {
        availableCommands = JSON.parse(capRow.payload_json) as unknown[];
      }
    }

    return { models, modes, configOptions, availableCommands };
  }

  private formatSessionRecord(row: Record<string, unknown> | undefined): StoredSessionRecord | undefined {
    if (!row) return undefined;
    const caps = this.hydrateCapability(row);
    const displayTitle = computeDisplayTitle(row);
    const out: StoredSessionRecord = {
      cwd: String(row.cwd),
      createdAt: String(row.created_at || row.updated_at),
      updatedAt: String(row.updated_at),
      upstreamTitle: (row.upstream_title as string | null) ?? null,
      customTitle: (row.custom_title as string | null) ?? null,
      aiTitle: (row.ai_title as string | null) ?? null,
      fallbackTitle: (row.fallback_title as string | null) ?? null,
      title: displayTitle,
      summaryAttempted: Number(row.summary_attempted) === 1,
      summaryStatus: (row.summary_status as string | null) ?? null,
    };
    if (caps.modes !== undefined) out.modes = caps.modes;
    if (caps.models !== undefined) out.models = caps.models;
    if (caps.configOptions !== undefined) out.configOptions = caps.configOptions;
    if (caps.availableCommands !== undefined) out.availableCommands = caps.availableCommands;
    return out;
  }

  has(sessionId: string): boolean {
    if (typeof sessionId !== 'string' || IGNORED_PROBE_SESSION_IDS.has(sessionId)) return false;
    return Boolean(this.stmtHasSession.get(sessionId));
  }

  get(sessionId: string): StoredSessionRecord | undefined {
    if (!this.has(sessionId)) return undefined;
    const row = this.stmtGetSession.get(sessionId) as Record<string, unknown> | undefined;
    return this.formatSessionRecord(row);
  }

  private getRawRow(sessionId: string): Record<string, unknown> | null {
    if (!this.has(sessionId)) return null;
    return (this.stmtGetSession.get(sessionId) as Record<string, unknown> | undefined) ?? null;
  }

  getDisplayTitle(sessionId: string): string | null {
    return computeDisplayTitle(this.getRawRow(sessionId));
  }

  recordCreated(params: {
    sessionId: string;
    cwd?: string | null;
    createdAt?: string;
    updatedAt?: string;
    title?: unknown;
    modes?: unknown;
    models?: unknown;
    configOptions?: unknown;
    availableCommands?: unknown;
  }): void {
    const { sessionId, cwd, createdAt, updatedAt, title, modes, models, configOptions, availableCommands } = params;
    if (typeof sessionId !== 'string' || !sessionId.trim() || IGNORED_PROBE_SESSION_IDS.has(sessionId)) return;
    const existing = this.stmtGetSession.get(sessionId) as Record<string, unknown> | undefined;
    const nowIso = new Date().toISOString();
    const resolvedCreatedAt = createdAt || (existing?.created_at as string | undefined) || nowIso;
    const resolvedUpdatedAt = updatedAt || (existing?.updated_at as string | undefined) || resolvedCreatedAt;
    const resolvedCwd = canonicalizeCwdSafe(cwd, (existing?.cwd as string | undefined) || this.defaultFallbackCwd) || this.defaultFallbackCwd;
    const resolvedUpstream = normalizeOptionalTitle(title) ?? (existing?.upstream_title as string | null) ?? null;

    const mSplit = models !== undefined ? this.storeCapabilityCatalog('models', models) : null;
    const mdSplit = modes !== undefined ? this.storeCapabilityCatalog('modes', modes) : null;
    const coSplit = configOptions !== undefined ? this.storeCapabilityCatalog('configOptions', configOptions) : null;
    const cmdSplit = availableCommands !== undefined ? this.storeCapabilityCatalog('availableCommands', availableCommands) : null;

    if (!existing) {
      this.stmtInsertIgnoreSession.run(
        sessionId,
        resolvedCwd,
        resolvedCreatedAt,
        resolvedUpdatedAt,
        resolvedUpstream,
        typeof mSplit?.selected === 'string' ? mSplit.selected : null,
        typeof mdSplit?.selected === 'string' ? mdSplit.selected : null,
        coSplit?.hash ? JSON.stringify(coSplit.selected || {}) : null,
        mSplit?.hash ?? null,
        mdSplit?.hash ?? null,
        coSplit?.hash ?? null,
        cmdSplit?.hash ?? null
      );
    } else {
      this.db
        .prepare(
          `UPDATE sessions
           SET cwd = ?, updated_at = ?, upstream_title = COALESCE(?, upstream_title),
               selected_model_id = COALESCE(?, selected_model_id),
               selected_mode_id = COALESCE(?, selected_mode_id),
               selected_config_json = COALESCE(?, selected_config_json),
               models_hash = COALESCE(?, models_hash),
               modes_hash = COALESCE(?, modes_hash),
               config_options_hash = COALESCE(?, config_options_hash),
               commands_hash = COALESCE(?, commands_hash)
           WHERE session_id = ?`
        )
        .run(
          resolvedCwd,
          resolvedUpdatedAt,
          resolvedUpstream,
          typeof mSplit?.selected === 'string' ? mSplit.selected : null,
          typeof mdSplit?.selected === 'string' ? mdSplit.selected : null,
          coSplit?.hash ? JSON.stringify(coSplit.selected || {}) : null,
          mSplit?.hash ?? null,
          mdSplit?.hash ?? null,
          coSplit?.hash ?? null,
          cmdSplit?.hash ?? null,
          sessionId
        );
    }
    chmodSync(this.dbPath, 0o600);
  }

  updateSession(
    sessionId: string,
    patch: {
      cwd?: string;
      updatedAt?: string;
      upstreamTitle?: unknown;
      title?: unknown;
      models?: unknown;
      modes?: unknown;
      configOptions?: unknown;
      availableCommands?: unknown;
    } = {}
  ): boolean {
    if (!this.has(sessionId)) return false;
    const existing = this.stmtGetSession.get(sessionId) as Record<string, unknown> | undefined;
    if (!existing) return false;

    const nextCwd =
      typeof patch.cwd === 'string' && patch.cwd
        ? canonicalizeCwdSafe(patch.cwd, String(existing.cwd)) || String(existing.cwd)
        : String(existing.cwd);
    // Updating upstream_title NEVER changes updated_at.
    const nextUpdatedAt =
      typeof patch.updatedAt === 'string' && Number.isFinite(parseTimestampMs(patch.updatedAt))
        ? patch.updatedAt
        : String(existing.updated_at);
    const incomingUpstream = normalizeOptionalTitle(patch.upstreamTitle ?? patch.title);
    const nextUpstream = incomingUpstream ?? (existing.upstream_title as string | null);

    let nextModelId = existing.selected_model_id as string | null;
    let nextModelsHash = existing.models_hash as string | null;
    if (patch.models !== undefined && patch.models !== null) {
      const mSplit = this.storeCapabilityCatalog('models', patch.models);
      nextModelsHash = mSplit.hash;
      nextModelId = typeof mSplit.selected === 'string' ? mSplit.selected : null;
    }

    let nextModeId = existing.selected_mode_id as string | null;
    let nextModesHash = existing.modes_hash as string | null;
    if (patch.modes !== undefined && patch.modes !== null) {
      const mdSplit = this.storeCapabilityCatalog('modes', patch.modes);
      nextModesHash = mdSplit.hash;
      nextModeId = typeof mdSplit.selected === 'string' ? mdSplit.selected : null;
    }

    let nextConfigJson = existing.selected_config_json as string | null;
    let nextConfigHash = existing.config_options_hash as string | null;
    if (Array.isArray(patch.configOptions)) {
      const coSplit = this.storeCapabilityCatalog('configOptions', patch.configOptions);
      nextConfigHash = coSplit.hash;
      nextConfigJson = coSplit.hash ? JSON.stringify(coSplit.selected || {}) : null;
    }

    let nextCommandsHash = existing.commands_hash as string | null;
    if (Array.isArray(patch.availableCommands)) {
      const cmdSplit = this.storeCapabilityCatalog('availableCommands', patch.availableCommands);
      nextCommandsHash = cmdSplit.hash;
    }

    this.db
      .prepare(
        `UPDATE sessions
         SET cwd = ?, updated_at = ?, upstream_title = ?,
             selected_model_id = ?, selected_mode_id = ?, selected_config_json = ?,
             models_hash = ?, modes_hash = ?, config_options_hash = ?,
             commands_hash = ?
         WHERE session_id = ?`
      )
      .run(
        nextCwd,
        nextUpdatedAt,
        nextUpstream,
        nextModelId,
        nextModeId,
        nextConfigJson,
        nextModelsHash,
        nextModesHash,
        nextConfigHash,
        nextCommandsHash,
        sessionId
      );
    return true;
  }

  recordPromptFallbackTitle(
    sessionId: string,
    promptText: string
  ): { displayTitle: string | null; fallbackTitle?: string | null; updated: boolean } | null {
    const existing = this.getRawRow(sessionId);
    if (!existing) return null;
    const fb = sliceFallbackTitle(promptText);
    if (!fb) return { displayTitle: computeDisplayTitle(existing), updated: false };
    const beforeDisplay = computeDisplayTitle(existing);
    if (!existing.fallback_title) {
      // Never modify updated_at!
      this.db
        .prepare('UPDATE sessions SET fallback_title = ? WHERE session_id = ? AND fallback_title IS NULL')
        .run(fb, sessionId);
    }
    const updatedRow = this.getRawRow(sessionId);
    const afterDisplay = computeDisplayTitle(updatedRow);
    return {
      displayTitle: afterDisplay,
      fallbackTitle: (updatedRow?.fallback_title as string | null) ?? null,
      updated: afterDisplay !== beforeDisplay,
    };
  }

  claimSummaryAttempt(sessionId: string): {
    claimed: boolean;
    displayTitle?: string | null;
    fallbackTitle?: string | null;
  } {
    if (!this.has(sessionId)) return { claimed: false };
    const res = this.db
      .prepare(
        "UPDATE sessions SET summary_attempted = 1, summary_status = 'pending' WHERE session_id = ? AND summary_attempted = 0 AND (custom_title IS NULL OR custom_title = '') AND (ai_title IS NULL OR ai_title = '')"
      )
      .run(sessionId);
    if (res.changes !== 1) {
      return { claimed: false };
    }
    const row = this.getRawRow(sessionId);
    return {
      claimed: true,
      displayTitle: computeDisplayTitle(row),
      fallbackTitle: (row?.fallback_title as string | null) ?? null,
    };
  }

  recordSummaryResult(
    sessionId: string,
    params: { status: string; aiTitle: string | null }
  ): { displayTitle: string | null; shouldPushUpdate: boolean } {
    const existing = this.getRawRow(sessionId);
    if (!existing) return { displayTitle: null, shouldPushUpdate: false };
    const cleanAi = normalizeOptionalTitle(params.aiTitle);
    const beforeDisplay = computeDisplayTitle(existing);
    // Never modify updated_at!
    if (cleanAi) {
      this.db
        .prepare('UPDATE sessions SET ai_title = ?, summary_status = ? WHERE session_id = ?')
        .run(cleanAi, params.status || 'succeeded', sessionId);
    } else {
      this.db
        .prepare('UPDATE sessions SET summary_status = ? WHERE session_id = ?')
        .run(params.status || 'failed', sessionId);
    }
    const afterRow = this.getRawRow(sessionId);
    const afterDisplay = computeDisplayTitle(afterRow);
    return {
      displayTitle: afterDisplay,
      shouldPushUpdate: Boolean(
        cleanAi && !normalizeOptionalTitle(afterRow?.custom_title) && afterDisplay !== beforeDisplay
      ),
    };
  }

  renameSession(
    sessionId: string,
    rawTitle: string | null
  ): { sessionId: string; title: string | null; customTitle: string | null } | null {
    if (!this.has(sessionId)) return null;
    const cleanCustom = normalizeOptionalTitle(rawTitle);
    // Never modify updated_at!
    this.db.prepare('UPDATE sessions SET custom_title = ? WHERE session_id = ?').run(cleanCustom, sessionId);
    const updatedRow = this.getRawRow(sessionId);
    return {
      sessionId,
      title: computeDisplayTitle(updatedRow),
      customTitle: (updatedRow?.custom_title as string | null) ?? null,
    };
  }

  mergeListItems(rawItems: unknown): Array<Record<string, unknown>> {
    const byId = new Map<string, Record<string, unknown>>();
    const list = Array.isArray(rawItems) ? rawItems : [];

    for (const rawItem of list) {
      if (!rawItem || typeof rawItem !== 'object') continue;
      const item = rawItem as Record<string, unknown>;
      const sid = item.sessionId;
      if (typeof sid !== 'string' || !sid.trim() || IGNORED_PROBE_SESSION_IDS.has(sid)) continue;

      const ownedRow = this.stmtGetSession.get(sid) as Record<string, unknown> | undefined;
      if (!ownedRow) {
        continue;
      }

      const incomingUpstream = normalizeOptionalTitle(item.title);
      if (incomingUpstream && incomingUpstream !== ownedRow.upstream_title) {
        // Never modify updated_at!
        this.db
          .prepare('UPDATE sessions SET upstream_title = ?, seen_in_upstream_list = 1 WHERE session_id = ?')
          .run(incomingUpstream, sid);
      } else if (!ownedRow.seen_in_upstream_list) {
        this.db.prepare('UPDATE sessions SET seen_in_upstream_list = 1 WHERE session_id = ?').run(sid);
      }

      const hydratedRow = this.stmtGetSession.get(sid) as Record<string, unknown>;
      const displayTitle = computeDisplayTitle(hydratedRow);
      const upMs = parseTimestampMs(item.updatedAt);
      const ownedMs = parseTimestampMs(hydratedRow.updated_at);
      const resolvedUpdatedAt =
        Number.isFinite(upMs) && (!Number.isFinite(ownedMs) || upMs >= ownedMs)
          ? String(item.updatedAt)
          : String(hydratedRow.updated_at);

      const sanitized: Record<string, unknown> = {
        ...item,
        cwd: hydratedRow.cwd,
        updatedAt: resolvedUpdatedAt,
        title: displayTitle,
      };
      delete sanitized.prompt;
      delete sanitized.rawTitle;
      byId.set(sid, sanitized);
    }

    for (const row of this.stmtAllSessions.all() as Array<Record<string, unknown>>) {
      const sid = String(row.session_id);
      if (IGNORED_PROBE_SESSION_IDS.has(sid)) continue;
      if (byId.has(sid)) continue;
      byId.set(sid, {
        sessionId: sid,
        cwd: row.cwd,
        updatedAt: row.updated_at,
        title: computeDisplayTitle(row),
      });
    }

    return Array.from(byId.values()).sort((a, b) => {
      const aMs = parseTimestampMs(a.updatedAt);
      const bMs = parseTimestampMs(b.updatedAt);
      if (Number.isFinite(aMs) && Number.isFinite(bMs) && aMs !== bMs) {
        return bMs - aMs;
      }
      if (Number.isFinite(bMs) && !Number.isFinite(aMs)) return 1;
      if (Number.isFinite(aMs) && !Number.isFinite(bMs)) return -1;
      return String(a.sessionId).localeCompare(String(b.sessionId));
    });
  }

  deleteSession(sessionId: string): boolean {
    if (typeof sessionId !== 'string' || !sessionId.trim()) return false;
    const res = this.db.prepare('DELETE FROM sessions WHERE session_id = ?').run(sessionId);
    return Number(res?.changes || 0) > 0;
  }

  markSeenInUpstreamList(sessionId: string): void {
    if (typeof sessionId !== 'string' || !sessionId.trim()) return;
    this.db
      .prepare('UPDATE sessions SET seen_in_upstream_list = 1 WHERE session_id = ? AND seen_in_upstream_list = 0')
      .run(sessionId);
  }

  markSeenOnDisk(sessionId: string): void {
    if (typeof sessionId !== 'string' || !sessionId.trim()) return;
    this.db
      .prepare('UPDATE sessions SET seen_on_disk = 1 WHERE session_id = ? AND seen_on_disk = 0')
      .run(sessionId);
  }

  getSessionInfoRow(sessionId: string): {
    sessionId: string;
    displayTitle: string | null;
    upstreamTitle: string | null;
    cwd: string | null;
  } | null {
    const row = this.getRawRow(sessionId);
    if (!row) return null;
    return {
      sessionId: String(row.session_id),
      displayTitle: computeDisplayTitle(row),
      upstreamTitle: normalizeOptionalTitle(row.upstream_title),
      cwd: (row.cwd as string | null) ?? null,
    };
  }

  getRawSessionsForReconcile(): ReconcileSessionRow[] {
    const rows = this.stmtAllSessions.all() as Array<Record<string, unknown>>;
    return rows.map((row) => ({
      sessionId: String(row.session_id),
      cwd: String(row.cwd),
      createdAt: (row.created_at as string | null) ?? null,
      updatedAt: String(row.updated_at),
      upstreamTitle: normalizeOptionalTitle(row.upstream_title),
      customTitle: normalizeOptionalTitle(row.custom_title),
      aiTitle: normalizeOptionalTitle(row.ai_title),
      fallbackTitle: normalizeOptionalTitle(row.fallback_title),
      seenInUpstreamList: Number(row.seen_in_upstream_list || 0) === 1,
      seenOnDisk: Number(row.seen_on_disk || 0) === 1,
    }));
  }

  getUsageSnapshot(): Record<string, unknown> | null {
    try {
      const row = this.db.prepare('SELECT payload_json FROM usage_snapshot WHERE id = 1').get() as
        | { payload_json?: string }
        | undefined;
      if (!row || typeof row.payload_json !== 'string') return null;
      const parsed = JSON.parse(row.payload_json);
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        this.clearUsageSnapshot();
        return null;
      }
      return parsed as Record<string, unknown>;
    } catch {
      this.clearUsageSnapshot();
      return null;
    }
  }

  saveUsageSnapshot(snapshot: Record<string, unknown>): boolean {
    try {
      const payloadJson = JSON.stringify(snapshot ?? {});
      const nowIso = new Date().toISOString();
      this.db
        .prepare(
          `INSERT INTO usage_snapshot (id, payload_json, updated_at)
           VALUES (1, ?, ?)
           ON CONFLICT(id) DO UPDATE SET payload_json = excluded.payload_json, updated_at = excluded.updated_at`
        )
        .run(payloadJson, nowIso);
      return true;
    } catch {
      return false;
    }
  }

  clearUsageSnapshot(): void {
    try {
      this.db.prepare('DELETE FROM usage_snapshot WHERE id = 1').run();
    } catch {
      // ignore
    }
  }

  entries(): Array<[string, StoredSessionRecord]> {
    const rows = this.stmtAllSessions.all() as Array<Record<string, unknown>>;
    return rows.map((r) => [String(r.session_id), this.formatSessionRecord(r)!]);
  }

  size(): number {
    const res = this.stmtCountSessions.get() as { cnt?: number } | undefined;
    return Number(res?.cnt || 0);
  }

  close(): void {
    try {
      this.db.close();
    } catch {
      // ignore
    }
  }
}
