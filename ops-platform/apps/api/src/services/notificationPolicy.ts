import type { NotificationItem, NotificationPolicyItem } from "../data/types.js";

const minuteMs = 60_000;
const dayMinutes = 24 * 60;
const defaultQuietHoursStart = "22:00";
const defaultQuietHoursEnd = "08:00";
const defaultQuietHoursTimeZone = "Asia/Shanghai";

function parseClockMinutes(value: string | undefined) {
  const match = /^(\d{2}):(\d{2})$/.exec(value ?? "");
  if (!match) return undefined;
  const hours = Number(match[1]);
  const minutes = Number(match[2]);
  if (hours < 0 || hours > 23 || minutes < 0 || minutes > 59) return undefined;
  return hours * 60 + minutes;
}

function localClockMinutes(date: Date, timeZone: string) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false
  }).formatToParts(date);
  const hour = Number(parts.find((part) => part.type === "hour")?.value ?? "0") % 24;
  const minute = Number(parts.find((part) => part.type === "minute")?.value ?? "0");
  return hour * 60 + minute;
}

function quietDelayMinutes(current: number, start: number, end: number) {
  if (start === end) return 0;
  if (start < end) {
    return current >= start && current < end ? end - current : 0;
  }
  if (current >= start) {
    return dayMinutes - current + end;
  }
  return current < end ? end - current : 0;
}

export function defaultNotificationPolicy(productId: string): NotificationPolicyItem {
  const start = process.env.NOTIFICATION_QUIET_HOURS_START ?? defaultQuietHoursStart;
  const end = process.env.NOTIFICATION_QUIET_HOURS_END ?? defaultQuietHoursEnd;
  const enabled = parseClockMinutes(start) !== undefined && parseClockMinutes(end) !== undefined;
  const timestamp = new Date(0).toISOString();
  return {
    productId,
    quietHoursEnabled: enabled && Boolean(process.env.NOTIFICATION_QUIET_HOURS_START && process.env.NOTIFICATION_QUIET_HOURS_END),
    quietHoursStart: parseClockMinutes(start) === undefined ? defaultQuietHoursStart : start,
    quietHoursEnd: parseClockMinutes(end) === undefined ? defaultQuietHoursEnd : end,
    quietHoursTimeZone: process.env.NOTIFICATION_QUIET_HOURS_TIME_ZONE ?? defaultQuietHoursTimeZone,
    createdAt: timestamp,
    updatedAt: timestamp
  };
}

export function notificationQuietHoursDelay(
  notification: Pick<NotificationItem, "type" | "priority">,
  now = new Date(),
  policy?: Pick<
    NotificationPolicyItem,
    "quietHoursEnabled" | "quietHoursStart" | "quietHoursEnd" | "quietHoursTimeZone"
  >
) {
  if (!notification.type.startsWith("admin_")) return undefined;
  if (notification.priority === "high" || notification.priority === "urgent") return undefined;

  if (policy && !policy.quietHoursEnabled) return undefined;

  const start = parseClockMinutes(policy?.quietHoursStart ?? process.env.NOTIFICATION_QUIET_HOURS_START);
  const end = parseClockMinutes(policy?.quietHoursEnd ?? process.env.NOTIFICATION_QUIET_HOURS_END);
  if (start === undefined || end === undefined) return undefined;

  const timeZone = policy?.quietHoursTimeZone ?? process.env.NOTIFICATION_QUIET_HOURS_TIME_ZONE ?? "UTC";
  const delayMinutes = quietDelayMinutes(localClockMinutes(now, timeZone), start, end);
  if (delayMinutes <= 0) return undefined;

  const delayMs = delayMinutes * minuteMs;
  return {
    delayMs,
    scheduledFor: new Date(now.getTime() + delayMs).toISOString()
  };
}
