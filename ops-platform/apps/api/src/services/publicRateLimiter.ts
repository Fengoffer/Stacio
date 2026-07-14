import { createHash } from "node:crypto";

interface RateLimitBucket {
  count: number;
  resetAt: number;
}

export interface RateLimitResult {
  allowed: boolean;
  remaining: number;
  retryAfterSeconds: number;
}

export interface PublicRateLimiter {
  consume(parts: string[]): RateLimitResult;
}

function positiveInteger(value: string | undefined, fallback: number) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

export class FixedWindowRateLimiter implements PublicRateLimiter {
  private readonly buckets = new Map<string, RateLimitBucket>();

  constructor(
    private readonly maxRequests: number,
    private readonly windowMs: number,
    private readonly now: () => number = Date.now
  ) {}

  consume(parts: string[]): RateLimitResult {
    const timestamp = this.now();
    const key = createHash("sha256").update(parts.join("\u0000")).digest("hex");
    let bucket = this.buckets.get(key);
    if (!bucket || bucket.resetAt <= timestamp) {
      bucket = {
        count: 0,
        resetAt: timestamp + this.windowMs
      };
      this.buckets.set(key, bucket);
    }

    const retryAfterSeconds = Math.max(1, Math.ceil((bucket.resetAt - timestamp) / 1_000));
    if (bucket.count >= this.maxRequests) {
      return {
        allowed: false,
        remaining: 0,
        retryAfterSeconds
      };
    }

    bucket.count += 1;
    return {
      allowed: true,
      remaining: Math.max(0, this.maxRequests - bucket.count),
      retryAfterSeconds
    };
  }
}

export function createPublicFeedbackRateLimiter() {
  const maxRequests = positiveInteger(process.env.PUBLIC_FEEDBACK_RATE_LIMIT_MAX, 30);
  const windowSeconds = positiveInteger(process.env.PUBLIC_FEEDBACK_RATE_LIMIT_WINDOW_SECONDS, 60);
  return new FixedWindowRateLimiter(maxRequests, windowSeconds * 1_000);
}

export function createPublicTelemetryRateLimiter() {
  const maxRequests = positiveInteger(process.env.PUBLIC_TELEMETRY_RATE_LIMIT_MAX, 120);
  const windowSeconds = positiveInteger(process.env.PUBLIC_TELEMETRY_RATE_LIMIT_WINDOW_SECONDS, 60);
  return new FixedWindowRateLimiter(maxRequests, windowSeconds * 1_000);
}
