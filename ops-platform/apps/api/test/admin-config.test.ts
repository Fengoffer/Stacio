import { describe, expect, it } from "vitest";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

describe("admin configuration APIs", () => {
  it("serves the remaining admin catalog pages from real API routes", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const [product, channels, customers, plans, connectors, settings] = await Promise.all([
      server.inject({ method: "GET", url: "/api/v1/products/stacio", headers }),
      server.inject({ method: "GET", url: "/api/v1/products/stacio/channels", headers }),
      server.inject({ method: "GET", url: "/api/v1/products/stacio/customers", headers }),
      server.inject({ method: "GET", url: "/api/v1/products/stacio/plans", headers }),
      server.inject({ method: "GET", url: "/api/v1/products/stacio/connectors", headers }),
      server.inject({ method: "GET", url: "/api/v1/settings/summary?productId=stacio", headers })
    ]);

    expect(product.statusCode).toBe(200);
    expect(product.json().data).toEqual(expect.objectContaining({ id: "stacio", name: "Stacio" }));
    expect(channels.json().data).toEqual(expect.arrayContaining([expect.objectContaining({ name: "stable" })]));
    expect(customers.json().data).toEqual(expect.arrayContaining([expect.objectContaining({ email: "tester@example.com" })]));
    expect(plans.json().data).toEqual(expect.arrayContaining([expect.objectContaining({ name: "Pro", offlineGraceDays: 14 })]));
    expect(connectors.json().data).toEqual(expect.arrayContaining([expect.objectContaining({ type: "agent_api" })]));
    expect(settings.json().data).toEqual(
      expect.objectContaining({
        productId: "stacio",
        policy: {
          otaRequiresManualConfirmation: true,
          agentDangerousActionsBlocked: true,
          licenseOfflineGraceDays: 14
        }
      })
    );
  });

  it("updates product notification quiet-hours policy with audit evidence", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const updated = await server.inject({
      method: "PATCH",
      url: "/api/v1/products/stacio/notification-policy",
      headers,
      payload: {
        quietHoursEnabled: true,
        quietHoursStart: "22:30",
        quietHoursEnd: "08:15",
        quietHoursTimeZone: "Asia/Shanghai"
      }
    });

    expect(updated.statusCode).toBe(200);
    expect(updated.json().data).toEqual(
      expect.objectContaining({
        productId: "stacio",
        quietHoursEnabled: true,
        quietHoursStart: "22:30",
        quietHoursEnd: "08:15",
        quietHoursTimeZone: "Asia/Shanghai"
      })
    );

    const fetched = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/notification-policy",
      headers
    });

    expect(fetched.statusCode).toBe(200);
    expect(fetched.json().data).toEqual(updated.json().data);

    const logs = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio",
      headers
    });

    expect(logs.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "notification_policy.updated",
          targetType: "notification_policy",
          productId: "stacio"
        })
      ])
    );
  });
});
