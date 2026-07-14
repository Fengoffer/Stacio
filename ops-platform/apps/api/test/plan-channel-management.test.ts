import { describe, expect, it } from "vitest";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

describe("plan and channel management", () => {
  it("creates, edits, and archives plans with entitlement assignments", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const created = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/plans",
      headers,
      payload: {
        id: "plan_enterprise",
        name: "Enterprise",
        description: "Managed enterprise deployment",
        maxDevices: 100,
        maxSeats: 50,
        trialDays: 30,
        offlineGraceDays: 60,
        allowedChannels: ["stable", "beta"],
        supportedVersionRange: ">=0.13.0",
        entitlements: ["pro_features", "team_features", "priority_support"],
        paymentProvider: "stripe",
        providerPlanId: "price_enterprise_yearly",
        priceMinor: 19900,
        currency: "USD",
        billingInterval: "year",
        couponSupport: true,
        subscriptionSupport: true
      }
    });

    expect(created.statusCode).toBe(201);
    expect(created.json().data).toEqual(
      expect.objectContaining({
        id: "plan_enterprise",
        name: "Enterprise",
        maxSeats: 50,
        allowedChannels: ["stable", "beta"],
        entitlements: ["pro_features", "team_features", "priority_support"],
        paymentProvider: "stripe",
        providerPlanId: "price_enterprise_yearly",
        couponSupport: true,
        subscriptionSupport: true,
        status: "active"
      })
    );

    const updated = await server.inject({
      method: "PATCH",
      url: "/api/v1/products/stacio/plans/plan_enterprise",
      headers,
      payload: {
        maxSeats: 75,
        offlineGraceDays: 90,
        allowedChannels: ["stable", "beta", "internal"],
        entitlements: ["pro_features", "team_features", "priority_support", "sso"],
        couponSupport: false
      }
    });

    expect(updated.statusCode).toBe(200);
    expect(updated.json().data).toEqual(
      expect.objectContaining({
        maxSeats: 75,
        offlineGraceDays: 90,
        allowedChannels: ["stable", "beta", "internal"],
        entitlements: ["pro_features", "team_features", "priority_support", "sso"],
        couponSupport: false,
        subscriptionSupport: true
      })
    );

    const rejectedArchive = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/plans/plan_enterprise/archive",
      headers,
      payload: {
        confirmation: "wrong"
      }
    });
    expect(rejectedArchive.statusCode).toBe(409);

    const archived = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/plans/plan_enterprise/archive",
      headers,
      payload: {
        confirmation: "ARCHIVE"
      }
    });
    expect(archived.statusCode).toBe(200);
    expect(archived.json().data.status).toBe("archived");

    const plans = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/plans",
      headers
    });
    expect(plans.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: "plan_enterprise",
          entitlements: ["pro_features", "team_features", "priority_support", "sso"],
          paymentProvider: "stripe",
          couponSupport: false,
          subscriptionSupport: true,
          status: "archived"
        })
      ])
    );

    const auditLogs = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio",
      headers
    });
    expect(auditLogs.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ action: "plan.created", targetId: "plan_enterprise" }),
        expect.objectContaining({ action: "plan.updated", targetId: "plan_enterprise" }),
        expect.objectContaining({ action: "plan.archived", targetId: "plan_enterprise" })
      ])
    );
  });

  it("creates, adjusts, pauses, histories, and rolls back release channels", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const created = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/channels",
      headers,
      payload: {
        name: "canary",
        appcastUrl: "https://updates.example.com/stacio/canary/appcast.xml",
        allowedPlanIds: ["plan_internal"],
        minimumUpgradableVersion: "0.13.0",
        rolloutPercentage: 100,
        autoDownloadAllowed: false,
        forceUpdatePrompt: false
      }
    });

    expect(created.statusCode).toBe(201);
    const channelId = created.json().data.id as string;
    expect(created.json().data).toEqual(
      expect.objectContaining({
        name: "canary",
        rolloutPercentage: 100,
        status: "active"
      })
    );

    const adjusted = await server.inject({
      method: "PATCH",
      url: `/api/v1/products/stacio/channels/${channelId}`,
      headers,
      payload: {
        rolloutPercentage: 20,
        autoDownloadAllowed: true
      }
    });
    expect(adjusted.statusCode).toBe(200);
    expect(adjusted.json().data).toEqual(
      expect.objectContaining({
        rolloutPercentage: 20,
        autoDownloadAllowed: true
      })
    );

    const rejectedPause = await server.inject({
      method: "PATCH",
      url: `/api/v1/products/stacio/channels/${channelId}`,
      headers,
      payload: {
        status: "paused"
      }
    });
    expect(rejectedPause.statusCode).toBe(409);

    const paused = await server.inject({
      method: "PATCH",
      url: `/api/v1/products/stacio/channels/${channelId}`,
      headers,
      payload: {
        status: "paused",
        confirmation: "PAUSE"
      }
    });
    expect(paused.statusCode).toBe(200);
    expect(paused.json().data.status).toBe("paused");

    const history = await server.inject({
      method: "GET",
      url: `/api/v1/products/stacio/channels/${channelId}/history`,
      headers
    });
    expect(history.statusCode).toBe(200);
    expect(history.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ action: "channel.created" }),
        expect.objectContaining({ action: "channel.updated" }),
        expect.objectContaining({ action: "channel.paused" })
      ])
    );
    const rolloutChange = history
      .json()
      .data.find(
        (item: { action: string; afterValue?: { rolloutPercentage?: number } }) =>
          item.action === "channel.updated" &&
          item.afterValue?.rolloutPercentage === 20
      );
    expect(rolloutChange).toBeDefined();

    const rolledBack = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/channels/${channelId}/rollback`,
      headers,
      payload: {
        historyId: rolloutChange.id,
        confirmation: "ROLLBACK"
      }
    });
    expect(rolledBack.statusCode).toBe(200);
    expect(rolledBack.json().data).toEqual(
      expect.objectContaining({
        rolloutPercentage: 100,
        autoDownloadAllowed: false
      })
    );

    const auditLogs = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio",
      headers
    });
    expect(auditLogs.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ action: "channel.rolled_back", targetId: channelId })
      ])
    );
  });
});
