import { isLoopbackIp } from '../config/ip.js';
import type { RateLimitConfig } from '../config/types.js';

interface IpBucket {
  failures: number[];
  bannedUntil: number;
  lastActiveAt: number;
}

export interface RateLimitDecision {
  allowed: boolean;
  banned: boolean;
  isLoopback: boolean;
  retryAfterSeconds: number;
}

export class AuthRateLimiter {
  private readonly maxFailures: number;
  private readonly windowMs: number;
  private readonly banMs: number;
  readonly loopbackBackoffMs: number;
  private readonly maxTrackedIps: number;
  private readonly nowFn: () => number;
  private readonly buckets = new Map<string, IpBucket>();

  constructor(cfg: RateLimitConfig, nowFn: () => number = () => Date.now()) {
    this.maxFailures = Math.max(1, cfg.maxFailures);
    this.windowMs = Math.max(10, cfg.windowMs);
    this.banMs = Math.max(10, cfg.banMs);
    this.loopbackBackoffMs = Math.max(0, Math.min(5000, cfg.loopbackBackoffMs));
    this.maxTrackedIps = Math.max(1, cfg.maxTrackedIps);
    this.nowFn = nowFn;
  }

  size(): number {
    return this.buckets.size;
  }

  private pruneExpired(now: number): void {
    for (const [key, bucket] of this.buckets.entries()) {
      const hasBan = bucket.bannedUntil > now;
      const freshFailures = bucket.failures.filter((ts) => now - ts < this.windowMs);
      bucket.failures = freshFailures;
      if (!hasBan && freshFailures.length === 0) {
        this.buckets.delete(key);
      }
    }
  }

  private ensureCapacity(key: string, now: number): void {
    if (this.buckets.has(key) || this.buckets.size < this.maxTrackedIps) {
      return;
    }
    this.pruneExpired(now);
    while (this.buckets.size >= this.maxTrackedIps) {
      const oldestKey = this.buckets.keys().next().value;
      if (oldestKey === undefined) break;
      this.buckets.delete(oldestKey);
    }
  }

  private touchLru(key: string, bucket: IpBucket, now: number): void {
    bucket.lastActiveAt = now;
    this.buckets.delete(key);
    this.buckets.set(key, bucket);
  }

  checkBeforeAuth(clientKey: string): RateLimitDecision {
    const now = this.nowFn();
    if (isLoopbackIp(clientKey)) {
      return { allowed: true, banned: false, isLoopback: true, retryAfterSeconds: 0 };
    }
    const bucket = this.buckets.get(clientKey);
    if (!bucket) {
      return { allowed: true, banned: false, isLoopback: false, retryAfterSeconds: 0 };
    }
    if (now < bucket.bannedUntil) {
      this.touchLru(clientKey, bucket, now);
      const retryAfterSeconds = Math.max(1, Math.ceil((bucket.bannedUntil - now) / 1000));
      return { allowed: false, banned: true, isLoopback: false, retryAfterSeconds };
    }
    return { allowed: true, banned: false, isLoopback: false, retryAfterSeconds: 0 };
  }

  recordFailure(clientKey: string): RateLimitDecision {
    const now = this.nowFn();
    if (isLoopbackIp(clientKey)) {
      return { allowed: true, banned: false, isLoopback: true, retryAfterSeconds: 0 };
    }
    this.ensureCapacity(clientKey, now);
    let bucket = this.buckets.get(clientKey);
    if (!bucket) {
      bucket = { failures: [], bannedUntil: 0, lastActiveAt: now };
    }

    if (now < bucket.bannedUntil) {
      this.touchLru(clientKey, bucket, now);
      return {
        allowed: false,
        banned: true,
        isLoopback: false,
        retryAfterSeconds: Math.max(1, Math.ceil((bucket.bannedUntil - now) / 1000)),
      };
    }

    bucket.failures = bucket.failures.filter((ts) => now - ts < this.windowMs);
    bucket.failures.push(now);

    if (bucket.failures.length >= this.maxFailures) {
      bucket.bannedUntil = now + this.banMs;
      bucket.failures = [];
      this.touchLru(clientKey, bucket, now);
      return {
        allowed: false,
        banned: true,
        isLoopback: false,
        retryAfterSeconds: Math.max(1, Math.ceil(this.banMs / 1000)),
      };
    }

    this.touchLru(clientKey, bucket, now);
    return { allowed: true, banned: false, isLoopback: false, retryAfterSeconds: 0 };
  }

  recordSuccess(clientKey: string): void {
    this.buckets.delete(clientKey);
  }
}
