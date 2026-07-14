import { createHmac } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import { createMemoryStore } from "../src/data/store.js";
import { buildServer } from "../src/server.js";
import { processGitHubPullJob, processNotificationSendJob, processWebhookDispatchJob } from "../src/jobs/handlers.js";
import { processOpsQueueJob } from "../src/jobs/worker.js";
import { encryptConnectorSecrets } from "../src/services/connectorSecrets.js";
import { ownerAuthorization } from "./helpers.js";

describe("background jobs", () => {
  it("processes notification send jobs through templates, SMTP and audit records", async () => {
    const store = createMemoryStore();
    await store.updateProduct("stacio", {
      supportEmail: "support@stacio.dev",
      emailBrand: {
        name: "Stacio",
        senderName: "Stacio Support",
        accentColor: "#00AAFF",
        replyToEmail: "reply@stacio.dev",
        footerText: "Sent by Stacio Ops"
      }
    });
    await store.upsertNotificationTemplate("stacio", {
      type: "feedback_reply",
      subjectTemplate: "{{brand.senderName}} 回复: {{feedback.title}}",
      htmlTemplate: "<p style=\"color:{{brand.accentColor}}\">{{brand.replyToEmail}}</p><p>{{reply.body}}</p>",
      textTemplate: "{{brand.footerText}} {{reply.body}}"
    });
    const notification = await store.createNotification("stacio", {
      type: "feedback_reply",
      recipient: "user@example.com",
      payload: {
        feedback: { title: "保存失败" },
        reply: { body: "我们已经收到反馈。" }
      }
    });
    expect(notification).toBeDefined();

    const sendMail = vi.fn(async () => ({
      status: "sent" as const,
      provider: "smtp" as const,
      providerMessageId: "smtp-1"
    }));

    const result = await processNotificationSendJob(
      {
        productId: "stacio",
        notificationId: notification!.id,
        requestedBy: "usr_test"
      },
      { store, sendMail }
    );

    expect(sendMail).toHaveBeenCalledWith(
      {
        to: "user@example.com",
        subject: "Stacio Support 回复: 保存失败",
        html: "<p style=\"color:#00AAFF\">reply@stacio.dev</p><p>我们已经收到反馈。</p>",
        text: "Sent by Stacio Ops 我们已经收到反馈。"
      },
      { dryRun: undefined }
    );
    expect(result.delivery).toEqual(
      expect.objectContaining({
        status: "sent",
        providerMessageId: "smtp-1"
      })
    );
    expect((await store.listNotifications("stacio")).find((item) => item.id === notification!.id)).toEqual(
      expect.objectContaining({ status: "sent" })
    );
    expect(await store.listAuditLogs("stacio")).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "notification.sent",
          targetId: notification!.id
        })
      ])
    );
  });

  it("processes GitHub pull jobs and records imported feedback", async () => {
    const store = createMemoryStore();
    const fetchIssues = vi.fn(async () => [
      {
        githubIssueId: "issue-100",
        number: 100,
        title: "Queued GitHub bug",
        body: "Imported by worker",
        labels: ["bug", "priority:p1"],
        author: "octocat",
        state: "open" as const,
        commentsCount: 1,
        url: "https://github.com/stacio/desktop/issues/100"
      }
    ]);

    const result = await processGitHubPullJob(
      {
        productId: "stacio",
        requestedBy: "usr_test",
        options: {
          owner: "stacio",
          repository: "desktop"
        }
      },
      { store, fetchIssues }
    );

    expect(fetchIssues).toHaveBeenCalledWith({
      owner: "stacio",
      repository: "desktop"
    });
    expect(result.run).toEqual(expect.objectContaining({ fetchedCount: 1, changedCount: 1 }));
    expect(result.feedbackCreated).toEqual([
      expect.objectContaining({
        title: "Queued GitHub bug",
        priority: "P1"
      })
    ]);
    expect(await store.listAuditLogs("stacio")).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "github.pull_sync",
          targetId: result.run.id
        })
      ])
    );
  });

  it("dispatches subscribed webhook events with an HMAC signature and audit record", async () => {
    const store = createMemoryStore();
    await store.upsertConnector("stacio", "webhook", {
      name: "Webhook",
      config: {
        url: "https://hooks.example.com/stacio",
        eventTypes: ["feedback.created"],
        signingHeader: "X-Stacio-Signature"
      },
      encryptedSecrets: encryptConnectorSecrets({
        signingSecret: "webhook-signing-secret"
      })
    });
    const sendWebhook = vi.fn(async () => ({
      status: 202,
      providerMessageId: "webhook-202"
    }));

    const result = await processWebhookDispatchJob(
      {
        productId: "stacio",
        eventType: "feedback.created",
        eventId: "feedback_1",
        payload: {
          feedback: {
            id: "feedback_1",
            title: "Save failed"
          }
        },
        requestedBy: "usr_test"
      },
      { store, sendWebhook }
    );

    expect(result).toEqual(
      expect.objectContaining({
        status: "sent",
        responseStatus: 202
      })
    );
    expect(sendWebhook).toHaveBeenCalledTimes(1);
    const message = sendWebhook.mock.calls[0][0];
    const expectedSignature = createHmac("sha256", "webhook-signing-secret")
      .update(message.body)
      .digest("hex");
    expect(message).toEqual(
      expect.objectContaining({
        url: "https://hooks.example.com/stacio",
        headers: expect.objectContaining({
          "Content-Type": "application/json",
          "X-Stacio-Event": "feedback.created",
          "X-Stacio-Delivery": "feedback_1",
          "X-Stacio-Signature": `sha256=${expectedSignature}`
        })
      })
    );
    expect(JSON.parse(message.body)).toEqual(
      expect.objectContaining({
        productId: "stacio",
        eventType: "feedback.created",
        eventId: "feedback_1",
        payload: {
          feedback: {
            id: "feedback_1",
            title: "Save failed"
          }
        }
      })
    );
    expect(await store.listAuditLogs("stacio")).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "webhook.dispatched",
          targetId: "feedback_1"
        })
      ])
    );
  });

  it("skips webhook events that are not subscribed without sending", async () => {
    const store = createMemoryStore();
    await store.upsertConnector("stacio", "webhook", {
      name: "Webhook",
      config: {
        url: "https://hooks.example.com/stacio",
        eventTypes: ["feedback.created"]
      }
    });
    const sendWebhook = vi.fn();

    await expect(
      processWebhookDispatchJob(
        {
          productId: "stacio",
          eventType: "license.revoked",
          eventId: "license_1",
          payload: {},
          requestedBy: "usr_test"
        },
        { store, sendWebhook }
      )
    ).resolves.toEqual(
      expect.objectContaining({
        status: "skipped",
        reason: "event_not_subscribed"
      })
    );

    expect(sendWebhook).not.toHaveBeenCalled();
  });

  it("enqueues notification send and GitHub pull jobs from admin APIs", async () => {
    const jobQueue = {
      enqueueNotificationSend: vi.fn(async (payload: unknown) => ({
        id: "job_notification_1",
        name: "notification.send",
        payload
      })),
      enqueueGitHubPull: vi.fn(async (payload: unknown) => ({
        id: "job_github_1",
        name: "github.pull",
        payload
      }))
    };
    const server = buildServer({ jobQueue });
    const headers = await ownerAuthorization(server);

    await server.inject({
      method: "PUT",
      url: "/api/v1/products/stacio/notification-templates/feedback_reply",
      headers,
      payload: {
        subjectTemplate: "Subject",
        htmlTemplate: "<p>Body</p>"
      }
    });
    const notificationResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/notifications",
      headers,
      payload: {
        type: "feedback_reply",
        recipient: "user@example.com",
        payload: {}
      }
    });
    const notificationId = notificationResponse.json().data.id;

    const sendResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/notifications/${notificationId}/send`,
      headers,
      payload: { mode: "queue", dryRun: true }
    });
    expect(sendResponse.statusCode).toBe(202);
    expect(sendResponse.json().data).toEqual(
      expect.objectContaining({
        id: "job_notification_1",
        name: "notification.send"
      })
    );
    expect(jobQueue.enqueueNotificationSend).toHaveBeenCalledWith({
      productId: "stacio",
      notificationId,
      requestedBy: expect.any(String),
      dryRun: true
    });

    const pullResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/github/pull/enqueue",
      headers,
      payload: {
        owner: "stacio",
        repository: "desktop",
        state: "all"
      }
    });
    expect(pullResponse.statusCode).toBe(202);
    expect(pullResponse.json().data).toEqual(
      expect.objectContaining({
        id: "job_github_1",
        name: "github.pull"
      })
    );
    expect(jobQueue.enqueueGitHubPull).toHaveBeenCalledWith({
      productId: "stacio",
      requestedBy: expect.any(String),
      options: {
        owner: "stacio",
        repository: "desktop",
        state: "all"
      }
    });
  });

  it("dispatches worker jobs by BullMQ job name", async () => {
    const processNotification = vi.fn(async () => ({ ok: true }));
    const processGitHubPull = vi.fn(async () => ({ ok: true }));
    const processWebhookDispatch = vi.fn(async () => ({ ok: true }));

    await expect(
      processOpsQueueJob(
        {
          name: "notification.send",
          data: {
            productId: "stacio",
            notificationId: "ntf_1"
          }
        },
        { processNotification, processGitHubPull, processWebhookDispatch }
      )
    ).resolves.toEqual({ ok: true });

    await expect(
      processOpsQueueJob(
        {
          name: "github.pull",
          data: {
            productId: "stacio"
          }
        },
        { processNotification, processGitHubPull, processWebhookDispatch }
      )
    ).resolves.toEqual({ ok: true });

    await expect(
      processOpsQueueJob(
        {
          name: "webhook.dispatch",
          data: {
            productId: "stacio",
            eventType: "feedback.created",
            eventId: "feedback_1",
            payload: {}
          }
        },
        { processNotification, processGitHubPull, processWebhookDispatch }
      )
    ).resolves.toEqual({ ok: true });

    expect(processNotification).toHaveBeenCalledWith({
      productId: "stacio",
      notificationId: "ntf_1"
    });
    expect(processGitHubPull).toHaveBeenCalledWith({
      productId: "stacio"
    });
    expect(processWebhookDispatch).toHaveBeenCalledWith({
      productId: "stacio",
      eventType: "feedback.created",
      eventId: "feedback_1",
      payload: {}
    });

    await expect(
      processOpsQueueJob(
        {
          name: "unknown.job",
          data: {}
        },
        { processNotification, processGitHubPull, processWebhookDispatch }
      )
    ).rejects.toThrow("Unsupported job");
  });
});
