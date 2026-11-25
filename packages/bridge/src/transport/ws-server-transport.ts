import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import http from 'node:http';
import type { Duplex } from 'node:stream';
import { WebSocketServer, type WebSocket } from 'ws';
import {
  isLoopbackIp,
  normalizeIpAddress,
  parseTrustedProxyEntry,
  resolveClientKey,
  resolveCompanionLoopback,
  type ParsedCidr,
} from '../config/ip.js';
import type { RateLimitConfig } from '../config/types.js';
import type { SanitizedLogger } from '../log/logger.js';
import { AuthRateLimiter } from './rate-limiter.js';
import type { BridgeTransport, ClientConnection, ListenEndpoint } from './types.js';

const SEC_KEY_RE = /^[A-Za-z0-9+/]{22}==$/;
const HMAC_KEY = randomBytes(32);

const PROXY_FORWARD_HEADERS = [
  'x-forwarded-for',
  'forwarded',
  'x-real-ip',
  'cf-connecting-ip',
] as const;

export function constantTimeTokenEqual(candidate: string, expected: string): boolean {
  if (
    typeof candidate !== 'string' ||
    typeof expected !== 'string' ||
    candidate.length === 0 ||
    expected.length === 0
  ) {
    return false;
  }
  const macA = createHmac('sha256', HMAC_KEY).update(candidate, 'utf8').digest();
  const macB = createHmac('sha256', HMAC_KEY).update(expected, 'utf8').digest();
  return timingSafeEqual(macA, macB);
}

export function extractBearerToken(authHeader: string | string[] | undefined): string | null {
  if (typeof authHeader !== 'string') return null;
  const match = /^Bearer[ \t]+([^\s]+)[ \t]*$/i.exec(authHeader);
  return match ? match[1] : null;
}

function writeHttpError(
  socket: Duplex,
  statusCode: number,
  statusText: string,
  extraHeaders: Record<string, string> = {},
  body: string = ''
): void {
  if (socket.destroyed || !socket.writable) return;
  const bodyBuf = Buffer.from(body, 'utf8');
  const lines = [`HTTP/1.1 ${statusCode} ${statusText}`];
  for (const [k, v] of Object.entries(extraHeaders)) {
    lines.push(`${k}: ${v}`);
  }
  lines.push('Connection: close');
  lines.push(`Content-Length: ${bodyBuf.length}`);
  lines.push('', '');
  socket.write(lines.join('\r\n'));
  if (bodyBuf.length > 0) {
    socket.write(bodyBuf);
  }
  socket.end();
}

function mapWsErrorToCloseCode(err: Error & { code?: string }): { code: number; reason: string } {
  const errCode = err?.code || '';
  const msg = (err?.message || '').toLowerCase();
  if (errCode === 'WS_ERR_UNSUPPORTED_MESSAGE_LENGTH' || msg.includes('max payload')) {
    return { code: 1009, reason: 'message_too_large' };
  }
  if (errCode === 'WS_ERR_INVALID_UTF8' || msg.includes('invalid utf-8')) {
    return { code: 1007, reason: 'invalid_utf8' };
  }
  if (errCode === 'WS_ERR_UNSUPPORTED_DATA_PAYLOAD_LENGTH') {
    return { code: 1009, reason: 'frame_too_large' };
  }
  return { code: 1002, reason: 'protocol_error' };
}

class WsClientConnection implements ClientConnection {
  readonly id: number;
  readonly remoteAddress: string;
  private readonly ws: WebSocket;
  private readonly pingTimer: NodeJS.Timeout | null;
  private messageHandlers: Array<(text: string) => void> = [];
  private closeHandlers: Array<(code: number, reason: string) => void> = [];
  private errorHandlers: Array<(err: Error) => void> = [];
  private closed = false;
  private awaitingPongSince: number | null = null;

  constructor(
    id: number,
    remoteAddress: string,
    ws: WebSocket,
    pingIntervalMs: number,
    pongTimeoutMs: number
  ) {
    this.id = id;
    this.remoteAddress = remoteAddress;
    this.ws = ws;

    ws.on('message', (data, isBinary) => {
      this.awaitingPongSince = null;
      if (isBinary) {
        this.close(1003, 'binary_unsupported');
        return;
      }
      const text = typeof data === 'string' ? data : Buffer.isBuffer(data) ? data.toString('utf8') : String(data);
      for (const h of this.messageHandlers) {
        h(text);
      }
    });

    ws.on('pong', () => {
      this.awaitingPongSince = null;
    });

    ws.on('ping', () => {
      this.awaitingPongSince = null;
    });

    ws.on('error', (err: Error & { code?: string }) => {
      for (const h of this.errorHandlers) {
        h(err);
      }
      if (!this.closed && ws.readyState === ws.OPEN) {
        const mapped = mapWsErrorToCloseCode(err);
        try {
          ws.close(mapped.code, mapped.reason);
        } catch {
          ws.terminate();
        }
      }
    });

    ws.on('close', (code, reasonBuf) => {
      if (this.closed) return;
      this.closed = true;
      if (this.pingTimer) {
        clearInterval(this.pingTimer);
      }
      const reason = Buffer.isBuffer(reasonBuf) ? reasonBuf.toString('utf8') : String(reasonBuf || '');
      for (const h of this.closeHandlers) {
        h(code, reason);
      }
    });

    this.pingTimer =
      pingIntervalMs > 0
        ? setInterval(() => {
            if (!this.isOpen()) return;
            if (this.awaitingPongSince !== null && Date.now() - this.awaitingPongSince >= pongTimeoutMs) {
              this.close(1001, 'ping_timeout');
              setTimeout(() => {
                if (!this.closed) {
                  try {
                    ws.terminate();
                  } catch {
                    // ignore
                  }
                }
              }, 100).unref?.();
              return;
            }
            if (this.awaitingPongSince === null) {
              this.awaitingPongSince = Date.now();
            }
            try {
              ws.ping(Buffer.from('ka', 'utf8'));
            } catch {
              // ignore
            }
          }, pingIntervalMs)
        : null;
    this.pingTimer?.unref?.();
  }

  isOpen(): boolean {
    return !this.closed && this.ws.readyState === this.ws.OPEN;
  }

  sendText(payload: string): boolean {
    if (!this.isOpen()) return false;
    try {
      this.ws.send(payload);
      return true;
    } catch {
      return false;
    }
  }

  close(code: number = 1000, reason: string = ''): void {
    if (this.closed) return;
    if (this.pingTimer) {
      clearInterval(this.pingTimer);
    }
    try {
      if (this.ws.readyState === this.ws.OPEN || this.ws.readyState === this.ws.CONNECTING) {
        this.ws.close(code, reason);
        if (code === 1002 || code === 1003 || code === 1007 || code === 1009) {
          setTimeout(() => {
            if (!this.closed) {
              try {
                this.ws.terminate();
              } catch {
                // ignore
              }
            }
          }, 80).unref?.();
        }
      }
    } catch {
      try {
        this.ws.terminate();
      } catch {
        // ignore
      }
    }
  }

  onMessage(handler: (text: string) => void): void {
    this.messageHandlers.push(handler);
  }

  onClose(handler: (code: number, reason: string) => void): void {
    this.closeHandlers.push(handler);
  }

  onError(handler: (err: Error) => void): void {
    this.errorHandlers.push(handler);
  }
}

export interface WsServerTransportOptions {
  host: string;
  port: number;
  allowNonLoopback: boolean;
  expectedToken: string;
  maxFrameBytes: number;
  pingIntervalMs: number;
  pongTimeoutMs: number;
  trustedProxies?: string[];
  rateLimit: RateLimitConfig;
  nowFn?: () => number;
  getHealthState: () => { childAlive: boolean; activeClient: boolean };
  logger?: SanitizedLogger;
  rateLimiter?: AuthRateLimiter;
}

export class WsServerTransport implements BridgeTransport {
  private readonly opts: WsServerTransportOptions;
  private readonly trustedCidrs: ParsedCidr[];
  readonly rateLimiter: AuthRateLimiter;
  private readonly wss: WebSocketServer;
  private readonly servers: Array<{ server: http.Server; role: 'primary' | 'companion-loopback'; host: string }> = [];
  private readonly activeConnections = new Set<WsClientConnection>();
  private readonly openSockets = new Set<Duplex>();
  private connectionHandlers: Array<(conn: ClientConnection) => void> = [];
  private nextConnId = 0;

  constructor(opts: WsServerTransportOptions) {
    if (!opts.allowNonLoopback && !isLoopbackIp(opts.host)) {
      throw new Error(
        `Refusing non-loopback host "${opts.host}" without allowNonLoopback=true`
      );
    }
    if (!Number.isInteger(opts.port) || opts.port < 0 || opts.port > 65535) {
      throw new Error(`Invalid port "${opts.port}": must be integer 0..65535`);
    }
    if (typeof opts.expectedToken !== 'string' || opts.expectedToken.length < 32) {
      throw new Error('Bearer token missing or shorter than 32 bytes');
    }

    this.opts = opts;
    this.trustedCidrs = (opts.trustedProxies ?? []).map((p) => parseTrustedProxyEntry(p));
    this.rateLimiter = opts.rateLimiter ?? new AuthRateLimiter(opts.rateLimit, opts.nowFn);
    this.wss = new WebSocketServer({
      noServer: true,
      perMessageDeflate: false,
      maxPayload: opts.maxFrameBytes,
    });
  }

  onConnection(handler: (conn: ClientConnection) => void): void {
    this.connectionHandlers.push(handler);
  }

  private createBoundHttpServer(): http.Server {
    const server = http.createServer((req, res) => {
      let pathname = '/';
      try {
        pathname = decodeURIComponent(new URL(req.url || '/', 'http://127.0.0.1').pathname);
      } catch {
        res.writeHead(400, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('Bad Request');
        return;
      }

      if (req.method === 'GET' && pathname === '/health') {
        const remoteNorm = normalizeIpAddress(req.socket.remoteAddress);
        const hasProxyHeader = PROXY_FORWARD_HEADERS.some((h) => req.headers[h] !== undefined);
        if (!isLoopbackIp(remoteNorm) || hasProxyHeader) {
          res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
          res.end('Not Found');
          return;
        }
        const state = this.opts.getHealthState();
        const payload = JSON.stringify({
          ok: true,
          childAlive: Boolean(state.childAlive),
          activeClient: Boolean(state.activeClient),
        });
        res.writeHead(200, {
          'Content-Type': 'application/json; charset=utf-8',
          'Cache-Control': 'no-store',
          'Content-Length': String(Buffer.byteLength(payload)),
        });
        res.end(payload);
        return;
      }

      if (pathname === '/' || pathname === '/acp' || pathname === '/ws') {
        res.writeHead(426, {
          Upgrade: 'websocket',
          'Content-Type': 'text/plain; charset=utf-8',
        });
        res.end('Upgrade Required');
        return;
      }

      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Not Found');
    });

    server.on('connection', (sock) => {
      this.openSockets.add(sock);
      sock.on('close', () => this.openSockets.delete(sock));
    });

    server.on('upgrade', (req, socket, head) => {
      this.voidHandleUpgrade(req, socket, head);
    });

    return server;
  }

  private voidHandleUpgrade(req: http.IncomingMessage, socket: Duplex, head: Buffer): void {
    void this.handleUpgrade(req, socket, head).catch(() => {
      try {
        socket.destroy();
      } catch {
        // ignore
      }
    });
  }

  private async handleUpgrade(req: http.IncomingMessage, socket: Duplex, head: Buffer): Promise<void> {
    this.openSockets.add(socket);
    socket.on('close', () => this.openSockets.delete(socket));
    socket.on('error', () => {
      // Prevent unhandled socket errors from crashing process.
    });

    const upgradeHdr = String(req.headers['upgrade'] || '').toLowerCase();
    const connHdr = String(req.headers['connection'] || '').toLowerCase();
    const wsVersion = req.headers['sec-websocket-version'];
    const wsKey = req.headers['sec-websocket-key'];
    if (
      upgradeHdr !== 'websocket' ||
      !connHdr.split(',').some((t) => t.trim() === 'upgrade') ||
      wsVersion !== '13' ||
      typeof wsKey !== 'string' ||
      !SEC_KEY_RE.test(wsKey) ||
      Buffer.from(wsKey, 'base64').length !== 16
    ) {
      this.opts.logger?.log('warn', 'ws_handshake_rejected', { reason: 'invalid_websocket_headers' });
      writeHttpError(socket, 400, 'Bad Request', {}, 'Bad Request');
      return;
    }

    let reqUrl: URL;
    try {
      reqUrl = new URL(req.url || '/', 'http://127.0.0.1');
      decodeURIComponent(reqUrl.pathname);
    } catch {
      writeHttpError(socket, 400, 'Bad Request', {}, 'Bad Request');
      return;
    }

    const remoteAddr = req.socket?.remoteAddress;
    const clientKey = resolveClientKey(remoteAddr, req.headers['x-forwarded-for'], this.trustedCidrs);

    // Rate-limit ban check BEFORE HMAC verification
    const preCheck = this.rateLimiter.checkBeforeAuth(clientKey);
    if (!preCheck.allowed) {
      this.opts.logger?.log('warn', 'ws_auth_rate_limited', {
        clientKey,
        reason: 'banned',
      });
      writeHttpError(
        socket,
        429,
        'Too Many Requests',
        {
          'Retry-After': String(preCheck.retryAfterSeconds),
          'Content-Type': 'text/plain; charset=utf-8',
        },
        'Too Many Requests'
      );
      return;
    }

    const hasQueryToken = reqUrl.searchParams.has('token') || reqUrl.searchParams.has('access_token');
    const candidate = hasQueryToken ? null : extractBearerToken(req.headers['authorization']);
    const authOk = !hasQueryToken && candidate !== null && constantTimeTokenEqual(candidate, this.opts.expectedToken);

    if (!authOk) {
      const reason = hasQueryToken
        ? 'query_token_forbidden'
        : candidate
          ? 'invalid_token'
          : 'missing_bearer_header';

      const decision = this.rateLimiter.recordFailure(clientKey);
      if (decision.isLoopback && this.rateLimiter.loopbackBackoffMs > 0) {
        await new Promise((r) => setTimeout(r, this.rateLimiter.loopbackBackoffMs));
      }

      if (!decision.allowed) {
        this.opts.logger?.log('warn', 'ws_auth_rate_limited', { clientKey, reason });
        writeHttpError(
          socket,
          429,
          'Too Many Requests',
          {
            'Retry-After': String(decision.retryAfterSeconds),
            'Content-Type': 'text/plain; charset=utf-8',
          },
          'Too Many Requests'
        );
        return;
      }

      this.opts.logger?.log('warn', 'ws_auth_rejected', { clientKey, reason });
      writeHttpError(
        socket,
        401,
        'Unauthorized',
        {
          'WWW-Authenticate': 'Bearer realm="nonlocal-bridge"',
          'Content-Type': 'text/plain; charset=utf-8',
        },
        'Unauthorized'
      );
      return;
    }

    // Valid handshake resets failure record for non-banned clientKey
    this.rateLimiter.recordSuccess(clientKey);
    if ('setNoDelay' in socket && typeof (socket as { setNoDelay?: (b: boolean) => void }).setNoDelay === 'function') {
      (socket as { setNoDelay: (b: boolean) => void }).setNoDelay(true);
    }

    this.wss.handleUpgrade(req, socket, head, (ws) => {
      const conn = new WsClientConnection(
        ++this.nextConnId,
        normalizeIpAddress(remoteAddr) || 'unknown',
        ws,
        this.opts.pingIntervalMs,
        this.opts.pongTimeoutMs
      );
      this.activeConnections.add(conn);
      conn.onClose(() => {
        this.activeConnections.delete(conn);
      });
      for (const h of this.connectionHandlers) {
        h(conn);
      }
    });
  }

  private listenSingle(
    server: http.Server,
    host: string,
    port: number
  ): Promise<{ address: string; port: number }> {
    return new Promise((resolve, reject) => {
      const onErr = (err: Error) => reject(err);
      server.once('error', onErr);
      const listenOpts: { port: number; host: string; ipv6Only?: boolean } = { port, host };
      if (host === '::') {
        listenOpts.ipv6Only = false;
      }
      server.listen(listenOpts, () => {
        server.off('error', onErr);
        const addr = server.address();
        if (!addr || typeof addr === 'string') {
          reject(new Error('Unexpected server address'));
          return;
        }
        resolve({ address: addr.address, port: addr.port });
      });
    });
  }

  async start(): Promise<{ host: string; port: number; listenAddresses: ListenEndpoint[] }> {
    if (!this.opts.allowNonLoopback && !isLoopbackIp(this.opts.host)) {
      throw new Error(`Refusing non-loopback host "${this.opts.host}" without allowNonLoopback=true`);
    }

    const primaryServer = this.createBoundHttpServer();
    let primaryAddr: { address: string; port: number };
    try {
      primaryAddr = await this.listenSingle(primaryServer, this.opts.host, this.opts.port);
    } catch (err) {
      await new Promise<void>((r) => primaryServer.close(() => r()));
      throw err;
    }

    this.servers.push({ server: primaryServer, role: 'primary', host: this.opts.host });
    const listenAddresses: ListenEndpoint[] = [
      { host: this.opts.host, port: primaryAddr.port, role: 'primary' },
    ];

    const companionHost = resolveCompanionLoopback(this.opts.host);
    if (companionHost && this.opts.allowNonLoopback) {
      const companionServer = this.createBoundHttpServer();
      try {
        const compAddr = await this.listenSingle(companionServer, companionHost, primaryAddr.port);
        this.servers.push({
          server: companionServer,
          role: 'companion-loopback',
          host: companionHost,
        });
        listenAddresses.push({
          host: companionHost,
          port: compAddr.port,
          role: 'companion-loopback',
        });
      } catch (err) {
        await new Promise<void>((r) => companionServer.close(() => r()));
        await this.stop();
        throw new Error(
          `Failed binding companion loopback ${companionHost}:${primaryAddr.port}: ${err instanceof Error ? err.message : String(err)}`
        );
      }
    }

    return {
      host: this.opts.host,
      port: primaryAddr.port,
      listenAddresses,
    };
  }

  async stop(): Promise<void> {
    if (this.activeConnections.size > 0) {
      for (const conn of Array.from(this.activeConnections)) {
        conn.close(1001, 'bridge_shutting_down');
      }
      const deadline = Date.now() + 80;
      while (this.activeConnections.size > 0 && Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 10));
      }
      this.activeConnections.clear();
    }

    for (const sock of Array.from(this.openSockets)) {
      try {
        sock.destroy();
      } catch {
        // ignore
      }
    }
    this.openSockets.clear();

    await Promise.all(
      this.servers.map(
        ({ server }) =>
          new Promise<void>((resolve) => {
            try {
              (server as { closeAllConnections?: () => void }).closeAllConnections?.();
              server.close(() => resolve());
            } catch {
              resolve();
            }
          })
      )
    );
    this.servers.length = 0;

    try {
      this.wss.close();
    } catch {
      // ignore
    }
  }
}
