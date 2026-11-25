import { existsSync, statSync, realpathSync } from 'node:fs';
import { resolve as resolvePath } from 'node:path';
import { expandHome } from '../../dist/config/paths.js';

export class FakeTestAdapter {
  constructor(opts = {}) {
    this.type = opts.type ?? 'antigravity';
    this.capabilities = opts.capabilities ?? {
      usage: true,
      sessionInfo: true,
      deleteSession: true,
      diskPresence: false,
    };
    this.host = null;
    this.healthy = false;
    this.loadedSessions = new Set();
    this.dispatchedRequests = [];
    this.serverResponses = [];
    this.onDispatch = opts.onDispatch ?? null;
    this.diskPresentSet = new Set();
    this.watchStates = new Map();
  }

  async start(host) {
    this.host = host;
  }

  async stop() {
    this.healthy = false;
  }

  isHealthy() {
    return this.healthy;
  }

  validateSessionCwd(rawCwd) {
    if (typeof rawCwd !== 'string' || !rawCwd.trim()) {
      return { ok: false, message: 'Invalid params: cwd must be a non-empty directory path' };
    }
    const resolved = resolvePath(expandHome(rawCwd.trim()));
    try {
      const st = statSync(resolved);
      if (!st.isDirectory()) return { ok: false, message: 'Invalid params: cwd is not a directory' };
      return { ok: true, cwd: realpathSync(resolved) };
    } catch {
      return { ok: false, message: 'Invalid params: cwd does not exist' };
    }
  }

  hasLoadedSession(sessionId) {
    return this.loadedSessions.has(sessionId);
  }

  async dispatchClientMessage(req) {
    this.healthy = true;
    this.dispatchedRequests.push(req);
    if (typeof this.onDispatch === 'function') {
      await this.onDispatch(req, this);
      return;
    }
    if (req.clientReqId !== undefined) {
      this.host.onAdapterMessage({
        kind: 'response',
        connId: req.connId,
        clientReqId: req.clientReqId,
        method: req.method,
        sessionId: req.sessionId,
        canonicalCwd: req.canonicalCwd,
        message: { jsonrpc: '2.0', id: req.clientReqId, result: {} },
      });
    }
  }

  respondToServerRequest(rewrittenId, rawResponse) {
    if (typeof rewrittenId !== 'string' || !/^w\d+_s\d+_/.test(rewrittenId)) {
      return false;
    }
    this.serverResponses.push({ rewrittenId, rawResponse });
    return true;
  }

  async closeSessionBestEffort() {}

  syncSessionWatch(sessionId, watchActive) {
    this.watchStates.set(sessionId, watchActive);
  }

  checkSessionDiskPresence(sessionId) {
    return this.diskPresentSet.has(sessionId);
  }
}
