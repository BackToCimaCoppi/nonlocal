import { isIP } from 'node:net';
import type { ListenWarningLevel } from './types.js';

export function normalizeIpAddress(raw: string | undefined | null): string {
  if (typeof raw !== 'string') return '';
  let value = raw.trim();
  if (!value) return '';
  const zoneIdx = value.indexOf('%');
  if (zoneIdx !== -1) {
    value = value.slice(0, zoneIdx);
  }
  if (value.toLowerCase().startsWith('::ffff:')) {
    const v4Candidate = value.slice(7);
    if (isIP(v4Candidate) === 4) {
      return v4Candidate;
    }
  }
  return value;
}

export function isValidIpLiteral(raw: string | undefined | null): boolean {
  if (typeof raw !== 'string') return false;
  const trimmed = raw.trim();
  if (!trimmed || trimmed.includes('%')) return false;
  return isIP(trimmed) !== 0;
}

function parseIpv4Int(ip: string): number | null {
  if (isIP(ip) !== 4) return null;
  const parts = ip.split('.');
  if (parts.length !== 4) return null;
  let num = 0;
  for (const part of parts) {
    const n = Number(part);
    if (!Number.isInteger(n) || n < 0 || n > 255) return null;
    num = ((num << 8) | n) >>> 0;
  }
  return num;
}

function parseIpv6BigInt(ip: string): bigint | null {
  if (isIP(ip) !== 6) return null;
  const mappedIdx = ip.toLowerCase().lastIndexOf(':');
  let working = ip;
  if (working.includes('.')) {
    const v4Part = working.slice(mappedIdx + 1);
    const v4Int = parseIpv4Int(v4Part);
    if (v4Int === null) return null;
    const hi = ((v4Int >>> 16) & 0xffff).toString(16);
    const lo = (v4Int & 0xffff).toString(16);
    working = `${working.slice(0, mappedIdx)}:${hi}:${lo}`;
  }

  const halves = working.split('::');
  if (halves.length > 2) return null;

  const left = halves[0] ? halves[0].split(':').filter((x) => x.length > 0) : [];
  const right = halves.length === 2 && halves[1] ? halves[1].split(':').filter((x) => x.length > 0) : [];
  const missing = 8 - (left.length + right.length);
  if (halves.length === 1 && missing !== 0) return null;
  if (halves.length === 2 && missing < 0) return null;

  const groups = [...left, ...Array(missing).fill('0'), ...right];
  if (groups.length !== 8) return null;

  let result = 0n;
  for (const g of groups) {
    const val = Number.parseInt(g, 16);
    if (!Number.isFinite(val) || val < 0 || val > 0xffff) return null;
    result = (result << 16n) | BigInt(val);
  }
  return result;
}

export function isLoopbackIp(raw: string | undefined | null): boolean {
  const ip = normalizeIpAddress(raw);
  if (!ip) return false;
  const v4 = parseIpv4Int(ip);
  if (v4 !== null) {
    return ((v4 >>> 24) & 0xff) === 127;
  }
  const v6 = parseIpv6BigInt(ip);
  if (v6 !== null) {
    return v6 === 1n;
  }
  return false;
}

export function isWildcardIp(raw: string | undefined | null): boolean {
  const ip = normalizeIpAddress(raw);
  if (!ip) return false;
  const v4 = parseIpv4Int(ip);
  if (v4 !== null) return v4 === 0;
  const v6 = parseIpv6BigInt(ip);
  if (v6 !== null) return v6 === 0n;
  return false;
}

export function isPrivateOrLinkLocalIp(raw: string | undefined | null): boolean {
  const ip = normalizeIpAddress(raw);
  if (!ip || isLoopbackIp(ip) || isWildcardIp(ip)) return false;

  const v4 = parseIpv4Int(ip);
  if (v4 !== null) {
    const b0 = (v4 >>> 24) & 0xff;
    const b1 = (v4 >>> 16) & 0xff;
    // RFC1918: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
    if (b0 === 10) return true;
    if (b0 === 172 && b1 >= 16 && b1 <= 31) return true;
    if (b0 === 192 && b1 === 168) return true;
    // CGNAT / Tailscale: 100.64.0.0/10
    if (b0 === 100 && b1 >= 64 && b1 <= 127) return true;
    // Link-local: 169.254.0.0/16
    if (b0 === 169 && b1 === 254) return true;
    return false;
  }

  const v6 = parseIpv6BigInt(ip);
  if (v6 !== null) {
    // ULA fc00::/7
    if ((v6 >> 121n) === 0b1111110n) return true;
    // Link-local fe80::/10
    if ((v6 >> 118n) === 0b1111111010n) return true;
    return false;
  }
  return false;
}

export function classifyListenWarning(host: string): ListenWarningLevel {
  if (isLoopbackIp(host)) return 'none';
  if (isPrivateOrLinkLocalIp(host)) return 'lan_plaintext';
  return 'public_or_wildcard_plaintext';
}

export function getSecurityWarningText(level: ListenWarningLevel): string | null {
  if (level === 'lan_plaintext') {
    return '局域网明文 ws:// 风险警告，仅限可信内网使用';
  }
  if (level === 'public_or_wildcard_plaintext') {
    return '警告：当前配置可能监听公网网卡，强烈建议改回 127.0.0.1 并改用 Tailscale / Cloudflare Tunnel / 反代 wss://';
  }
  return null;
}

export function resolveCompanionLoopback(host: string): '127.0.0.1' | '::1' | null {
  const norm = normalizeIpAddress(host);
  if (!norm || isLoopbackIp(norm) || isWildcardIp(norm)) return null;
  const family = isIP(norm);
  if (family === 4) return '127.0.0.1';
  if (family === 6) return '::1';
  return null;
}

export function resolveLocalProbeHost(host: string): '127.0.0.1' | '::1' {
  const norm = normalizeIpAddress(host);
  if (isIP(norm) === 6) return '::1';
  return '127.0.0.1';
}

export function formatHostForUrl(host: string): string {
  return isIP(host) === 6 ? `[${host}]` : host;
}

export interface ParsedCidr {
  family: 4 | 6;
  network: bigint;
  maskBits: number;
}

export function parseTrustedProxyEntry(raw: string): ParsedCidr {
  if (typeof raw !== 'string') {
    throw new Error('trustedProxies entry must be a string');
  }
  const trimmed = raw.trim();
  if (!trimmed) {
    throw new Error('trustedProxies entry must not be empty');
  }
  if (trimmed === '0.0.0.0/0' || trimmed === '::/0') {
    throw new Error(`trustedProxies forbids wildcard subnet "${trimmed}"`);
  }

  const slashIdx = trimmed.indexOf('/');
  if (slashIdx === -1) {
    const norm = normalizeIpAddress(trimmed);
    const fam = isIP(norm);
    if (fam === 4) {
      const v4 = parseIpv4Int(norm)!;
      return { family: 4, network: BigInt(v4), maskBits: 32 };
    }
    if (fam === 6) {
      const v6 = parseIpv6BigInt(norm)!;
      return { family: 6, network: v6, maskBits: 128 };
    }
    throw new Error(`Invalid trustedProxies IP "${trimmed}"`);
  }

  const ipPart = trimmed.slice(0, slashIdx);
  const prefixStr = trimmed.slice(slashIdx + 1);
  if (!/^\d+$/.test(prefixStr)) {
    throw new Error(`Invalid trustedProxies CIDR prefix "${trimmed}"`);
  }
  const prefix = Number(prefixStr);
  const norm = normalizeIpAddress(ipPart);
  const fam = isIP(norm);
  if (fam === 4) {
    if (prefix <= 0 || prefix > 32) {
      throw new Error(`Invalid trustedProxies IPv4 CIDR "${trimmed}"`);
    }
    const v4 = BigInt(parseIpv4Int(norm)!);
    const shift = BigInt(32 - prefix);
    const mask = (0xffffffffn << shift) & 0xffffffffn;
    return { family: 4, network: v4 & mask, maskBits: prefix };
  }
  if (fam === 6) {
    if (prefix <= 0 || prefix > 128) {
      throw new Error(`Invalid trustedProxies IPv6 CIDR "${trimmed}"`);
    }
    const v6 = parseIpv6BigInt(norm)!;
    const shift = BigInt(128 - prefix);
    const full = (1n << 128n) - 1n;
    const mask = (full << shift) & full;
    return { family: 6, network: v6 & mask, maskBits: prefix };
  }
  throw new Error(`Invalid trustedProxies CIDR "${trimmed}"`);
}

export function matchCidr(ip: string, cidr: ParsedCidr): boolean {
  const norm = normalizeIpAddress(ip);
  const fam = isIP(norm);
  if (fam !== cidr.family) return false;
  if (fam === 4) {
    const val = BigInt(parseIpv4Int(norm)!);
    const shift = BigInt(32 - cidr.maskBits);
    const mask = (0xffffffffn << shift) & 0xffffffffn;
    return (val & mask) === cidr.network;
  }
  const val = parseIpv6BigInt(norm)!;
  const shift = BigInt(128 - cidr.maskBits);
  const full = (1n << 128n) - 1n;
  const mask = (full << shift) & full;
  return (val & mask) === cidr.network;
}

export function isIpInTrustedProxies(ip: string, cidrs: readonly ParsedCidr[]): boolean {
  for (const c of cidrs) {
    if (matchCidr(ip, c)) return true;
  }
  return false;
}

export function resolveClientKey(
  remoteAddress: string | undefined,
  xffHeader: string | string[] | undefined,
  trustedCidrs: readonly ParsedCidr[]
): string {
  const peerIp = normalizeIpAddress(remoteAddress) || 'unknown';
  if (trustedCidrs.length === 0 || peerIp === 'unknown' || !isIpInTrustedProxies(peerIp, trustedCidrs)) {
    return peerIp;
  }

  const rawXff = Array.isArray(xffHeader) ? xffHeader.join(',') : xffHeader;
  if (typeof rawXff !== 'string' || !rawXff.trim()) {
    return peerIp;
  }

  const chain = rawXff
    .split(',')
    .map((part) => normalizeIpAddress(part))
    .filter((part) => part.length > 0);
  chain.push(peerIp);

  for (let i = chain.length - 1; i >= 0; i--) {
    const candidate = chain[i];
    if (isIP(candidate) === 0) {
      return peerIp;
    }
    if (!isIpInTrustedProxies(candidate, trustedCidrs)) {
      return candidate;
    }
  }
  return peerIp;
}
