import { afterEach, describe, expect, it, vi } from "vitest";
import { createMemoryStore } from "../src/data/store.js";
import { buildServer } from "../src/server";
import { ownerAuthorization } from "./helpers.js";

afterEach(() => {
  vi.useRealTimers();
});

describe("dashboard route", () => {
  it("returns product operations summary cards", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/dashboard",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.ok).toBe(true);
    expect(body.data).toEqual(
      expect.objectContaining({
        productId: "stacio",
        currentStableVersion: "0.13.1-Beta",
        currentBetaVersion: "0.13.2-Beta",
        unhandledFeedbackCount: expect.any(Number),
        p0p1BugCount: expect.any(Number),
        activeLicenseCount: expect.any(Number)
      })
    );
  });

  it("counts active licenses that expire inside the next 30 days", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-07-10T00:00:00.000Z"));
    const store = createMemoryStore();
    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);

    await store.createLicense("stacio", {
      customerName: "Renewal User",
      customerEmail: "renewal@example.com",
      username: "renewal",
      plan: "pro",
      status: "active",
      expiresAt: "2026-07-20T00:00:00.000Z"
    });

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/dashboard",
      headers
    });

    expect(response.statusCode).toBe(200);
    expect(response.json().data).toEqual(
      expect.objectContaining({
        expiringLicenseCount: 2
      })
    );
  });

  it("summarizes license validation errors, email delivery status, and recent audit events", async () => {
    const store = createMemoryStore();
    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);

    await store.validateLicense("stacio", {
      licenseKey: "STACIO-WRONG-KEY",
      email: "dashboard@example.com",
      username: "Dashboard Tester"
    });

    await store.createNotification("stacio", {
      type: "feedback_reply",
      recipient: "queued@example.com",
      payload: {}
    });
    const sentNotification = await store.createNotification("stacio", {
      type: "feedback_reply",
      recipient: "sent@example.com",
      payload: {}
    });
    const failedNotification = await store.createNotification("stacio", {
      type: "feedback_reply",
      recipient: "failed@example.com",
      payload: {}
    });
    const dryRunNotification = await store.createNotification("stacio", {
      type: "feedback_reply",
      recipient: "dry-run@example.com",
      payload: {}
    });
    await store.createNotificationDelivery(sentNotification?.id ?? "", {
      provider: "smtp",
      status: "sent",
      providerMessageId: "smtp-sent"
    });
    await store.createNotificationDelivery(failedNotification?.id ?? "", {
      provider: "smtp",
      status: "failed",
      error: "Mailbox unavailable"
    });
    await store.createNotificationDelivery(dryRunNotification?.id ?? "", {
      provider: "smtp",
      status: "dry_run",
      providerMessageId: "smtp-dry-run"
    });

    await store.createAuditLog({
      actorType: "user",
      actorId: "usr_test",
      action: "dashboard.signal_seeded",
      targetType: "dashboard",
      targetId: "stacio",
      productId: "stacio"
    });
    await store.recordGitHubSyncFailure("stacio", {
      trigger: "manual",
      error: "GitHub API returned 403"
    });

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/dashboard",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toEqual(
      expect.objectContaining({
        githubSyncStatus: "failed",
        licenseValidationErrorCount: 1,
        emailDeliveryStatus: {
          queued: 1,
          sent: 1,
          failed: 1,
          dryRun: 1
        },
        recentAuditEvents: expect.arrayContaining([
          expect.objectContaining({
            action: "dashboard.signal_seeded",
            targetType: "dashboard",
            actorType: "user"
          })
        ])
      })
    );
  });
});
