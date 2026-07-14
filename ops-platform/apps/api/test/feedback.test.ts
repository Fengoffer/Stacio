import { describe, expect, it, vi } from "vitest";
import { createMemoryStore } from "../src/data/store.js";
import type { OpsJobQueue } from "../src/jobs/queue.js";
import { buildServer } from "../src/server";
import { ownerAuthorization } from "./helpers.js";

describe("feedback routes", () => {
  it("lists seeded feedback for a product", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.ok).toBe(true);
    expect(body.data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: "fb_001",
          productId: "stacio",
          priority: "P1",
          status: "new"
        })
      ])
    );
  });

  it("accepts public app feedback and stores it for triage", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);
    const keyResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback-api-key/rotate",
      headers,
      payload: {
        confirmation: "ROTATE"
      }
    });
    const feedbackApiKey = keyResponse.json().data.feedbackApiKey as string;

    const createResponse = await server.inject({
      method: "POST",
      url: "/api/v1/public/products/stacio/feedback",
      headers: {
        "x-product-api-key": feedbackApiKey
      },
      payload: {
        title: "Remote editor save failed",
        description: "Save failed after reconnecting to the host.",
        type: "bug",
        contactEmail: "user@example.com",
        appVersion: "0.13.2-Beta",
        buildNumber: "12",
        osVersion: "macOS 15.5",
        licenseState: "licensed",
        anonymousDeviceId: "device_test"
      }
    });

    expect(createResponse.statusCode).toBe(201);
    const created = createResponse.json();
    expect(created.ok).toBe(true);
    expect(created.data).toEqual(
      expect.objectContaining({
        id: expect.stringMatching(/^fb_/),
        productId: "stacio",
        title: "Remote editor save failed",
        source: "app",
        status: "new",
        priority: "P2",
        licenseState: "licensed"
      })
    );

    const today = new Date().toISOString().slice(0, 10);
    const filteredResponse = await server.inject({
      method: "GET",
      url: `/api/v1/products/stacio/feedback?licenseState=licensed&createdFrom=${today}&createdTo=${today}`,
      headers
    });
    expect(filteredResponse.statusCode).toBe(200);
    expect(filteredResponse.json().data).toEqual([
      expect.objectContaining({
        id: created.data.id,
        title: "Remote editor save failed",
        licenseState: "licensed"
      })
    ]);

    const listResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback",
      headers
    });
    const listBody = listResponse.json();
    expect(listBody.data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: created.data.id,
          title: "Remote editor save failed"
        })
      ])
    );

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio",
      headers
    });
    expect(auditResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "feedback.created",
          targetId: created.data.id
        })
      ])
    );
  });

  it("reuses public feedback responses for repeated idempotency keys", async () => {
    const store = createMemoryStore();
    const enqueueNotificationSend = vi.fn(async (payload: unknown) => ({
      id: `job_${String(vi.mocked(enqueueNotificationSend).mock.calls.length)}`,
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
      },
      async enqueueWebhookDispatch(payload) {
        return {
          id: "job_webhook_unused",
          name: "webhook.dispatch",
          payload
        };
      }
    };
    const server = buildServer({ store, jobQueue });
    const headers = await ownerAuthorization(server);
    const keyResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback-api-key/rotate",
      headers,
      payload: {
        confirmation: "ROTATE"
      }
    });
    const feedbackApiKey = keyResponse.json().data.feedbackApiKey as string;
    const payload = {
      title: "Repeated network submit",
      description: "The app retried feedback submission after a timeout.",
      type: "bug",
      contactEmail: "retry@example.com",
      appVersion: "0.13.2-Beta",
      buildNumber: "12",
      osVersion: "macOS 15.5",
      anonymousDeviceId: "device_retry"
    };
    const request = {
      method: "POST" as const,
      url: "/api/v1/public/products/stacio/feedback",
      headers: {
        "x-product-api-key": feedbackApiKey,
        "x-idempotency-key": "feedback_retry_001"
      },
      payload
    };

    const firstResponse = await server.inject(request);
    const secondResponse = await server.inject(request);

    expect(firstResponse.statusCode).toBe(201);
    expect(secondResponse.statusCode).toBe(201);
    expect(secondResponse.json().data.id).toBe(firstResponse.json().data.id);
    expect((await store.listFeedback("stacio")).filter((item) => item.title === payload.title)).toHaveLength(1);
    expect((await store.listNotifications("stacio")).filter((item) => item.payload.feedbackTitle === payload.title)).toHaveLength(2);
    expect(enqueueNotificationSend).toHaveBeenCalledTimes(2);
    expect((await store.listAuditLogs("stacio")).filter((item) => item.action === "feedback.created" && item.targetId === firstResponse.json().data.id)).toHaveLength(1);
  });

  it("enqueues a feedback.created webhook event once for idempotent public submissions", async () => {
    const store = createMemoryStore();
    const enqueueWebhookDispatch = vi.fn(async (payload: unknown) => ({
      id: "job_webhook_1",
      name: "webhook.dispatch" as const,
      payload
    }));
    const jobQueue: OpsJobQueue = {
      async enqueueNotificationSend(payload) {
        return {
          id: "job_notification_unused",
          name: "notification.send",
          payload
        };
      },
      async enqueueGitHubPull(payload) {
        return {
          id: "job_github_unused",
          name: "github.pull",
          payload
        };
      },
      enqueueWebhookDispatch
    };
    const server = buildServer({ store, jobQueue });
    const headers = await ownerAuthorization(server);
    const keyResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback-api-key/rotate",
      headers,
      payload: {
        confirmation: "ROTATE"
      }
    });
    const feedbackApiKey = keyResponse.json().data.feedbackApiKey as string;
    const request = {
      method: "POST" as const,
      url: "/api/v1/public/products/stacio/feedback",
      headers: {
        "x-product-api-key": feedbackApiKey,
        "x-idempotency-key": "feedback_webhook_once"
      },
      payload: {
        title: "Webhook event feedback",
        description: "This should notify downstream automation exactly once.",
        type: "feature",
        contactEmail: "webhook-user@example.com",
        appVersion: "0.13.2-Beta",
        buildNumber: "12"
      }
    };

    const firstResponse = await server.inject(request);
    const secondResponse = await server.inject(request);

    expect(firstResponse.statusCode).toBe(201);
    expect(secondResponse.statusCode).toBe(201);
    const feedback = firstResponse.json().data;
    expect(enqueueWebhookDispatch).toHaveBeenCalledTimes(1);
    expect(enqueueWebhookDispatch).toHaveBeenCalledWith({
      productId: "stacio",
      eventType: "feedback.created",
      eventId: feedback.id,
      payload: {
        feedback: expect.objectContaining({
          id: feedback.id,
          title: "Webhook event feedback",
          type: "feature",
          priority: "P2",
          source: "app",
          contactEmail: "webhook-user@example.com",
          appVersion: "0.13.2-Beta",
          buildNumber: "12"
        })
      }
    });
  });

  it("rejects public feedback idempotency key reuse with a different payload", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);
    const keyResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback-api-key/rotate",
      headers,
      payload: {
        confirmation: "ROTATE"
      }
    });
    const feedbackApiKey = keyResponse.json().data.feedbackApiKey as string;
    const baseRequest = {
      method: "POST" as const,
      url: "/api/v1/public/products/stacio/feedback",
      headers: {
        "x-product-api-key": feedbackApiKey,
        "x-idempotency-key": "feedback_retry_conflict"
      }
    };

    const firstResponse = await server.inject({
      ...baseRequest,
      payload: {
        title: "First retry payload",
        description: "The first payload should own this idempotency key.",
        type: "bug",
        contactEmail: "retry@example.com"
      }
    });
    const conflictResponse = await server.inject({
      ...baseRequest,
      payload: {
        title: "Different retry payload",
        description: "A different payload must not reuse the first response.",
        type: "bug",
        contactEmail: "retry@example.com"
      }
    });

    expect(firstResponse.statusCode).toBe(201);
    expect(conflictResponse.statusCode).toBe(409);
    expect(conflictResponse.json().error).toEqual(
      expect.objectContaining({
        code: "IDEMPOTENCY_CONFLICT"
      })
    );
  });

  it("queues customer confirmation and admin alert emails for public app feedback", async () => {
    const store = createMemoryStore();
    const enqueueNotificationSend = vi.fn(async (payload: unknown) => ({
      id: `job_${String(vi.mocked(enqueueNotificationSend).mock.calls.length)}`,
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
      },
      async enqueueWebhookDispatch(payload) {
        return {
          id: "job_webhook_unused",
          name: "webhook.dispatch",
          payload
        };
      }
    };
    const server = buildServer({ store, jobQueue });
    const headers = await ownerAuthorization(server);
    const keyResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback-api-key/rotate",
      headers,
      payload: {
        confirmation: "ROTATE"
      }
    });
    const feedbackApiKey = keyResponse.json().data.feedbackApiKey as string;

    const createResponse = await server.inject({
      method: "POST",
      url: "/api/v1/public/products/stacio/feedback",
      headers: {
        "x-product-api-key": feedbackApiKey
      },
      payload: {
        title: "Crash on launch",
        description: "The app crashes immediately after opening.",
        type: "crash",
        contactEmail: "user@example.com",
        appVersion: "0.13.2-Beta",
        buildNumber: "12",
        osVersion: "macOS 15.5",
        anonymousDeviceId: "device_test"
      }
    });

    expect(createResponse.statusCode).toBe(201);
    const feedbackId = createResponse.json().data.id;
    const notifications = await store.listNotifications("stacio");
    expect(notifications).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          type: "customer_feedback_received",
          recipient: "user@example.com",
          priority: "normal",
          payload: expect.objectContaining({
            feedbackId,
            feedbackTitle: "Crash on launch"
          })
        }),
        expect.objectContaining({
          type: "admin_new_feedback",
          recipient: "support@stacio.dev",
          priority: "normal",
          payload: expect.objectContaining({
            feedbackId,
            contactEmail: "user@example.com"
          })
        }),
        expect.objectContaining({
          type: "admin_p0_p1_bug_alert",
          recipient: "support@stacio.dev",
          priority: "high",
          payload: expect.objectContaining({
            feedbackId,
            priority: "P1"
          })
        })
      ])
    );
    expect(enqueueNotificationSend).toHaveBeenCalledTimes(3);
    for (const notification of notifications.filter((item) =>
      ["customer_feedback_received", "admin_new_feedback", "admin_p0_p1_bug_alert"].includes(item.type)
    )) {
      expect(enqueueNotificationSend).toHaveBeenCalledWith({
        productId: "stacio",
        notificationId: notification.id,
        dryRun: false
      });
    }
  });
});
