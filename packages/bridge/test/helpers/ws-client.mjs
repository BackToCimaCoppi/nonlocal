import http from 'node:http';
import { createHash, randomBytes } from 'node:crypto';
import net from 'node:net';
import { WebSocket } from 'ws';

export function httpRequest({ host = '127.0.0.1', port, method = 'GET', path = '/health', headers = {} }) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host, port, method, path, headers }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        resolve({
          statusCode: res.statusCode,
          headers: res.headers,
          body: Buffer.concat(chunks).toString('utf8'),
        });
      });
    });
    req.on('error', reject);
    req.end();
  });
}

export function rawUpgradeRequest({ host = '127.0.0.1', port, path = '/acp', headers = {} }) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host, port }, () => {
      const lines = [`GET ${path} HTTP/1.1`, `Host: ${host}:${port}`];
      for (const [k, v] of Object.entries(headers)) {
        lines.push(`${k}: ${v}`);
      }
      lines.push('', '');
      socket.write(lines.join('\r\n'));
    });

    let raw = Buffer.alloc(0);
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      const text = raw.toString('latin1');
      const idx = text.indexOf('\r\n\r\n');
      const headText = idx === -1 ? text : text.slice(0, idx);
      const bodyText = idx === -1 ? '' : raw.subarray(idx + 4).toString('utf8');
      const statusLine = headText.split('\r\n')[0] || '';
      const statusMatch = /^HTTP\/1\.\d\s+(\d+)/.exec(statusLine);
      const statusCode = statusMatch ? Number(statusMatch[1]) : 0;
      const hdrs = {};
      for (const line of headText.split('\r\n').slice(1)) {
        const colon = line.indexOf(':');
        if (colon !== -1) {
          hdrs[line.slice(0, colon).trim().toLowerCase()] = line.slice(colon + 1).trim();
        }
      }
      socket.destroy();
      resolve({ statusCode, headers: hdrs, body: bodyText, rawHead: headText });
    };

    socket.on('data', (chunk) => {
      raw = Buffer.concat([raw, chunk]);
      const s = raw.toString('latin1');
      const idx = s.indexOf('\r\n\r\n');
      if (idx !== -1) {
        if (s.startsWith('HTTP/1.1 101')) {
          finish();
        }
      }
    });
    socket.on('end', finish);
    socket.on('error', (err) => {
      if (!settled) {
        settled = true;
        reject(err);
      }
    });
  });
}

export function makeWsKey() {
  return randomBytes(16).toString('base64');
}

export function buildRawClientFrame({ fin = true, rsv = 0, opcode = 0x1, masked = true, payload = Buffer.alloc(0) }) {
  const buf = Buffer.isBuffer(payload) ? payload : Buffer.from(payload, 'utf8');
  const b0 = (fin ? 0x80 : 0) | ((rsv & 0x7) << 4) | (opcode & 0x0f);
  const maskBit = masked ? 0x80 : 0;
  let hdr;
  if (buf.length < 126) {
    hdr = Buffer.from([b0, maskBit | buf.length]);
  } else if (buf.length <= 0xffff) {
    hdr = Buffer.alloc(4);
    hdr[0] = b0;
    hdr[1] = maskBit | 126;
    hdr.writeUInt16BE(buf.length, 2);
  } else {
    hdr = Buffer.alloc(10);
    hdr[0] = b0;
    hdr[1] = maskBit | 127;
    hdr.writeBigUInt64BE(BigInt(buf.length), 2);
  }
  if (!masked) {
    return Buffer.concat([hdr, buf]);
  }
  const maskKey = randomBytes(4);
  const maskedPayload = Buffer.from(buf);
  for (let i = 0; i < maskedPayload.length; i++) {
    maskedPayload[i] ^= maskKey[i & 3];
  }
  return Buffer.concat([hdr, maskKey, maskedPayload]);
}

export function openRawWsSocket({ host = '127.0.0.1', port, path = '/acp', token }) {
  return new Promise((resolve, reject) => {
    const key = makeWsKey();
    const expectedAccept = createHash('sha1')
      .update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
      .digest('base64');
    const socket = net.createConnection({ host, port }, () => {
      const req = [
        `GET ${path} HTTP/1.1`,
        `Host: ${host}:${port}`,
        'Upgrade: websocket',
        'Connection: Upgrade',
        'Sec-WebSocket-Version: 13',
        `Sec-WebSocket-Key: ${key}`,
        `Authorization: Bearer ${token}`,
        '',
        '',
      ].join('\r\n');
      socket.write(req);
    });

    let buf = Buffer.alloc(0);
    let upgraded = false;
    socket.on('data', (chunk) => {
      if (upgraded) return;
      buf = Buffer.concat([buf, chunk]);
      const idx = buf.indexOf('\r\n\r\n');
      if (idx !== -1) {
        const head = buf.subarray(0, idx).toString('latin1');
        if (!head.includes('101') || !head.includes(expectedAccept)) {
          socket.destroy();
          reject(new Error(`Unexpected handshake: ${head}`));
          return;
        }
        upgraded = true;
        resolve({ socket, leftover: buf.subarray(idx + 4) });
      }
    });
    socket.on('error', reject);
  });
}

export function parseFirstCloseCode(rawBuf) {
  let offset = 0;
  while (offset + 2 <= rawBuf.length) {
    const b0 = rawBuf[offset];
    const b1 = rawBuf[offset + 1];
    const opcode = b0 & 0x0f;
    let len = b1 & 0x7f;
    let pos = offset + 2;
    if (len === 126) {
      if (pos + 2 > rawBuf.length) break;
      len = rawBuf.readUInt16BE(pos);
      pos += 2;
    } else if (len === 127) {
      if (pos + 8 > rawBuf.length) break;
      len = Number(rawBuf.readBigUInt64BE(pos));
      pos += 8;
    }
    if (pos + len > rawBuf.length) break;
    if (opcode === 0x8 && len >= 2) {
      return rawBuf.readUInt16BE(pos);
    }
    offset = pos + len;
  }
  return null;
}

export function connectWs(url, token, headers = {}) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, {
      headers: {
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...headers,
      },
      perMessageDeflate: false,
    });
    const messages = [];
    const waiters = [];
    let closedInfo = null;
    const closeWaiters = [];

    ws.on('message', (data) => {
      const text = data.toString('utf8');
      let parsed;
      try {
        parsed = JSON.parse(text);
      } catch {
        parsed = text;
      }
      if (waiters.length > 0) {
        const idx = waiters.findIndex((w) => w.pred(parsed));
        if (idx !== -1) {
          const w = waiters.splice(idx, 1)[0];
          clearTimeout(w.timer);
          w.resolve(parsed);
          return;
        }
      }
      messages.push(parsed);
    });

    ws.on('close', (code, reasonBuf) => {
      closedInfo = { code, reason: reasonBuf.toString('utf8') };
      while (closeWaiters.length > 0) {
        closeWaiters.shift()(closedInfo);
      }
    });

    ws.once('open', () => {
      resolve({
        ws,
        messages,
        sendJson(obj) {
          ws.send(JSON.stringify(obj));
        },
        waitFor(pred, timeoutMs = 4000) {
          const existingIdx = messages.findIndex(pred);
          if (existingIdx !== -1) {
            return Promise.resolve(messages.splice(existingIdx, 1)[0]);
          }
          return new Promise((res, rej) => {
            const timer = setTimeout(() => {
              const i = waiters.findIndex((w) => w.resolve === res);
              if (i !== -1) waiters.splice(i, 1);
              rej(new Error(`waitFor timeout after ${timeoutMs}ms; seen=${JSON.stringify(messages.slice(-5))}`));
            }, timeoutMs);
            waiters.push({ pred, resolve: res, timer });
          });
        },
        waitForClose(timeoutMs = 4000) {
          if (closedInfo) return Promise.resolve(closedInfo);
          return new Promise((res, rej) => {
            const timer = setTimeout(() => rej(new Error('waitForClose timeout')), timeoutMs);
            closeWaiters.push((info) => {
              clearTimeout(timer);
              res(info);
            });
          });
        },
        close(code = 1000, reason = '') {
          try {
            ws.close(code, reason);
          } catch {
            ws.terminate();
          }
        },
      });
    });

    ws.once('unexpected-response', (_req, res) => {
      reject(Object.assign(new Error(`Unexpected HTTP ${res.statusCode}`), { statusCode: res.statusCode, headers: res.headers }));
    });
    ws.once('error', (err) => {
      if (ws.readyState !== ws.OPEN) reject(err);
    });
  });
}
