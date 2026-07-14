import { describe, expect, it, vi } from "vitest";
import type { OpsJobQueue } from "../src/jobs/queue.js";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

function notificationJobQueue() {
  const enqueueNotificationSend = vi.fn(async (payload: unknown) => ({
    id: `job_notification_${String(enqueueNotificationSend.mock.calls.length)}`,
    name: "notification.send" as const,
    payload
  }));
  const jobQueue: OpsJobQueue = {
    enqueueNotificationSend,
    async enqueueGitHubPull(payload) {
      return {
        id: "job_github_unused",
        name: "github.pull",
        payload
      };
    }
  };
  return { jobQueue, enqueueNotificationSend };
}

describe("notification daily feedback digest", () => {
  it("creates an admin daily feedback digest notification and queues its email job", async () => {
    const { jobQueue, enqueueNotificationSend } = notificationJobQueue();
    const server = buildServer({ jobQueue });
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/notifications/daily-feedback-digest",
      headers,
      payload: {
        recipient: "ops@example.com",
        date: "2026-07-09"
      }
    });

    expect(response.statusCode).toBe(201);
    expect(response.json()).toEqual(
      expect.objectContaining({
        ok: true,
        data: expect.objectContaining({
          type: "admin_daily_feedback_digest",
          recipient: "ops@example.com",
          priority: "normal",
          status: "queued",
          payload: expect.objectContaining({
            date: "2026-07-09",
            summary: expect.stringContaining("2 条反馈"),
            metrics: {
              totalCount: 2,
              newCount: 1,
              unhandledCount: 2,
              p0p1Count: 1,
              resolvedCount: 0
            },
            topFeedback: [
              expect.objectContaining({
                id: "fb_001",
                title: "远端编辑器保存后偶发失败",
                priority: "P1"
              }),
              expect.objectContaining({
                id: "fb_002",
                title: "希望设备看板支持自定义刷新频率",
                priority: "P2"
              })
            ]
          })
        }),
        policy: {
          emailSent: false,
          queuedOnly: true,
          quietHoursEligible: true
        }
      })
    );

    const notificationId = response.json().data.id;
    expect(enqueueNotificationSend).toHaveBeenCalledWith({
      productId: "stacio",
      notificationId,
      dryRun: false
    });
    const deliveries = await server.inject({
      method: "GET",
      url: `/api/v1/products/stacio/notifications/${notificationId}/deliveries`,
      headers
    });
    expect(deliveries.json().data).toEqual([]);

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio&action=notification.digest_created",
      headers
    });
    expect(auditResponse.json().data).toEqual([
      expect.objectContaining({
        action: "notification.digest_created",
        targetType: "notification",
        targetId: notificationId
      })
    ]);
  });

  it("creates customer license expiring notifications and queues email jobs for new reminders", async () => {
    const { jobQueue, enqueueNotificationSend } = notificationJobQueue();
    const server = buildServer({ jobQueue });
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/notifications/license-expiring",
      headers,
      payload: {
        days: 30,
        referenceDate: "2026-07-10T00:00:00.000Z"
      }
    });

    expect(response.statusCode).toBe(201);
    expect(response.json().data).toEqual(
      expect.objectContaining({
        scannedCount: 2,
        createdCount: 1,
        skippedCount: 0,
        window: {
          referenceDate: "2026-07-10T00:00:00.000Z",
          days: 30,
          cutoffDate: "2026-08-09T00:00:00.000Z"
        },
        created: [
          expect.objectContaining({
            type: "customer_license_expiring",
            recipient: "pro@example.com",
            priority: "normal",
            status: "queued",
            payload: expect.objectContaining({
              licenseId: "lic_002",
              customerName: "Pro User",
              email: "pro@example.com",
              plan: "pro",
              status: "trial",
              expiresAt: "2026-08-09T00:00:00.000Z",
              daysRemaining: 30
            })
          })
        ]
      })
    );
    expect(response.json().policy).toEqual({
      emailSent: false,
      queuedOnly: true,
      customerVisible: true
    });
    const createdNotification = response.json().data.created[0];
    expect(enqueueNotificationSend).toHaveBeenCalledTimes(1);
    expect(enqueueNotificationSend).toHaveBeenCalledWith({
      productId: "stacio",
      notificationId: createdNotification.id,
      dryRun: false
    });

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio&action=notification.license_expiring_created",
      headers
    });
    expect(auditResponse.json().data).toEqual([
      expect.objectContaining({
        action: "notification.license_expiring_created",
        targetType: "notification_batch",
        afterValue: expect.objectContaining({
          createdCount: 1,
          skippedCount: 0,
          days: 30
        })
      })
    ]);
  });

  it("skips existing customer license expiring notifications for the same license window", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);
    const payload = {
      days: 30,
      referenceDate: "2026-07-10T00:00:00.000Z"
    };

    const firstResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/notifications/license-expiring",
      headers,
      payload
    });
    expect(firstResponse.statusCode).toBe(201);

    const secondResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/notifications/license-expiring",
      headers,
      payload
    });

    expect(secondResponse.statusCode).toBe(201);
    expect(secondResponse.json().data).toEqual(
      expect.objectContaining({
        createdCount: 0,
        skippedCount: 1,
        created: [],
        skipped: [
          expect.objectContaining({
            licenseId: "lic_002",
            recipient: "pro@example.com",
            reason: "already_queued"
          })
        ]
      })
    );

    const notificationsResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/notifications",
      headers
    });
    const expiringNotifications = notificationsResponse
      .json()
      .data.filter((notification: { type: string }) => notification.type === "customer_license_expiring");
    expect(expiringNotifications).toHaveLength(1);
  });
});
