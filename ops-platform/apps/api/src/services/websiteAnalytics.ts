import { createHmac } from "node:crypto";
import type { WebsiteAnalyticsSummary, WebsiteEventItem } from "../data/types.js";
import type { CreateWebsiteEventInput } from "../data/store.js";

export interface WebsiteTelemetryPayload {
  eventId: string;
  type: WebsiteEventItem["type"];
  path: string;
  visitorId: string;
  sessionId?: string;
  releaseId?: string;
  platform?: string;
  architecture?: string;
  referrer?: string;
}

function hashValue(value: string) {
  const key = process.env.ANALYTICS_HASH_KEY ?? process.env.JWT_SECRET ?? "development-only-analytics-key";
  return createHmac("sha256", key).update(value).digest("hex");
}

function anonymizeAddress(ipAddress: string) {
  if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(ipAddress)) {
    return `${ipAddress.split(".").slice(0, 3).join(".")}.0/24`;
  }
  const parts = ipAddress.split(":").filter(Boolean);
  if (parts.length > 1) {
    return `${parts.slice(0, 4).join(":")}::/64`;
  }
  return "unknown";
}

function parseUserAgent(userAgent: string | undefined) {
  const source = userAgent ?? "";
  const browser = source.match(/Edg\/([\d.]+)/)
    ? { name: "Edge", version: RegExp.$1 }
    : source.match(/Chrome\/([\d.]+)/)
      ? { name: "Chrome", version: RegExp.$1 }
      : source.match(/Firefox\/([\d.]+)/)
        ? { name: "Firefox", version: RegExp.$1 }
        : source.match(/Version\/([\d.]+).*Safari\//)
          ? { name: "Safari", version: RegExp.$1 }
          : { name: "Other", version: undefined };
  const mac = source.match(/Mac OS X ([\d_]+)/);
  const android = source.match(/Android ([\d.]+)/);
  const ios = source.match(/(?:iPhone|iPad).*OS ([\d_]+)/);
  const windows = source.match(/Windows NT ([\d.]+)/);
  const operatingSystem = mac
    ? `macOS ${mac[1].replaceAll("_", ".")}`
    : android
      ? `Android ${android[1]}`
      : ios
        ? `iOS ${ios[1].replaceAll("_", ".")}`
        : windows
          ? `Windows ${windows[1]}`
          : /Linux/.test(source)
            ? "Linux"
            : "Other";
  const deviceType = /iPad|Tablet/.test(source)
    ? "tablet"
    : /Mobi|Android/.test(source)
      ? "mobile"
      : source
        ? "desktop"
        : "unknown";
  return { ...browser, operatingSystem, deviceType } as const;
}

function safeReferrer(value: string | undefined) {
  if (!value) return undefined;
  try {
    const url = new URL(value);
    return `${url.origin}${url.pathname}`;
  } catch {
    return undefined;
  }
}

export function websiteEventFromTelemetry(
  input: WebsiteTelemetryPayload,
  context: { ipAddress: string; userAgent?: string; occurredAt?: string }
): CreateWebsiteEventInput {
  const client = parseUserAgent(context.userAgent);
  return {
    eventId: input.eventId,
    type: input.type,
    path: input.path,
    referrer: safeReferrer(input.referrer),
    visitorHash: hashValue(input.visitorId),
    sessionHash: input.sessionId ? hashValue(input.sessionId) : undefined,
    releaseId: input.releaseId,
    platform: input.platform,
    architecture: input.architecture,
    ipAddress: anonymizeAddress(context.ipAddress),
    ipHash: hashValue(context.ipAddress),
    browserName: client.name,
    browserVersion: client.version,
    operatingSystem: client.operatingSystem,
    deviceType: client.deviceType,
    occurredAt: context.occurredAt ?? new Date().toISOString()
  };
}

function countBy(values: string[]) {
  const counts = new Map<string, number>();
  for (const value of values) {
    counts.set(value, (counts.get(value) ?? 0) + 1);
  }
  return [...counts.entries()]
    .map(([name, count]) => ({ name, count }))
    .sort((left, right) => right.count - left.count || left.name.localeCompare(right.name));
}

export function summarizeWebsiteAnalytics(events: WebsiteEventItem[]): WebsiteAnalyticsSummary {
  const pageViews = events.filter((event) => event.type === "page_view");
  const downloads = events.filter(
    (event) => event.type === "download_requested" || event.type === "download_redirected"
  );
  return {
    overview: {
      pageViews: pageViews.length,
      uniqueVisitors: new Set(pageViews.map((event) => event.visitorHash)).size,
      downloadRequests: downloads.length,
      uniqueDownloaders: new Set(downloads.map((event) => event.visitorHash)).size
    },
    browsers: countBy(events.map((event) => event.browserName)),
    operatingSystems: countBy(events.map((event) => event.operatingSystem)),
    devices: countBy(events.map((event) => event.deviceType)),
    recentEvents: [...events]
      .sort((left, right) => right.occurredAt.localeCompare(left.occurredAt))
      .slice(0, 50)
  };
}
