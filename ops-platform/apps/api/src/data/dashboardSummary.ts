import type {
  AuditLogItem,
  DashboardSummary,
  NotificationDeliveryItem,
  NotificationItem
} from "./types.js";

type EmailDeliveryStatus = DashboardSummary["emailDeliveryStatus"];
type NotificationForSummary = Pick<NotificationItem, "id" | "status">;
type DeliveryForSummary = Pick<NotificationDeliveryItem, "notificationId" | "status" | "createdAt">;

function timestampOf(value: string | undefined) {
  return value ? new Date(value).getTime() : 0;
}

export function summarizeEmailDeliveryStatus(
  notifications: NotificationForSummary[],
  deliveries: DeliveryForSummary[]
): EmailDeliveryStatus {
  const latestDeliveryByNotification = new Map<string, DeliveryForSummary>();
  for (const delivery of deliveries) {
    const current = latestDeliveryByNotification.get(delivery.notificationId);
    if (!current || timestampOf(delivery.createdAt) >= timestampOf(current.createdAt)) {
      latestDeliveryByNotification.set(delivery.notificationId, delivery);
    }
  }

  const status: EmailDeliveryStatus = {
    queued: 0,
    sent: 0,
    failed: 0,
    dryRun: 0
  };

  for (const notification of notifications) {
    const latestDelivery = latestDeliveryByNotification.get(notification.id);
    if (latestDelivery?.status === "dry_run") {
      status.dryRun += 1;
      continue;
    }
    if (latestDelivery?.status === "sent" || notification.status === "sent") {
      status.sent += 1;
      continue;
    }
    if (latestDelivery?.status === "failed" || notification.status === "failed") {
      status.failed += 1;
      continue;
    }
    if (notification.status === "queued") {
      status.queued += 1;
    }
  }

  return status;
}

export function recentAuditEvents(auditLogs: AuditLogItem[], limit = 5) {
  return [...auditLogs]
    .sort((left, right) => right.createdAt.localeCompare(left.createdAt))
    .slice(0, limit);
}
