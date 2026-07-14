import { describe, expect, it, vi } from "vitest";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

const productPayload = {
  id: "portdesk",
  name: "PortDesk",
  platform: "macOS",
  bundleId: "com.zerxlab.portdesk",
  iconUrl: "https://cdn.example.com/portdesk/icon.png",
  description: "Remote operations client",
  supportEmail: "support@example.com",
  githubOwner: "zerx-lab",
  githubRepository: "portdesk",
  updateBaseUrl: "https://updates.example.com/portdesk",
  appcastBaseUrl: "https://updates.example.com/portdesk",
  objectStoragePrefix: "products/portdesk",
  licensePolicy: {
    defaultOfflineGraceDays: 14,
    maxDevices: 3
  },
  dataRetentionPolicy: {
    feedbackRetentionDays: 730,
    diagnosticsRetentionDays: 90,
    auditLogRetentionDays: 1095,
    inactiveCustomerRetentionDays: 730
  },
  emailBrand: {
    name: "PortDesk",
    accentColor: "#0070C0"
  }
};

describe("product management", () => {
  it("creates, edits, and archives a reusable product configuration", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const created = await server.inject({
      method: "POST",
      url: "/api/v1/products",
      headers,
      payload: productPayload
    });

    expect(created.statusCode).toBe(201);
    expect(created.json().data.product).toEqual(
      expect.objectContaining({
        id: "portdesk",
        name: "PortDesk",
        githubOwner: "zerx-lab",
        objectStoragePrefix: "products/portdesk",
        dataRetentionPolicy: {
          feedbackRetentionDays: 730,
          diagnosticsRetentionDays: 90,
          auditLogRetentionDays: 1095,
          inactiveCustomerRetentionDays: 730
        },
        status: "active"
      })
    );
    expect(created.json().data.feedbackApiKey).toMatch(/^pfk_/);
    expect(created.json().data.product).not.toHaveProperty("feedbackApiKeyHash");

    const updated = await server.inject({
      method: "PATCH",
      url: "/api/v1/products/portdesk",
      headers,
      payload: {
        supportEmail: "help@example.com",
        githubRepository: "portdesk-app",
        dataRetentionPolicy: {
          feedbackRetentionDays: 365,
          diagnosticsRetentionDays: 30,
          auditLogRetentionDays: 1095,
          inactiveCustomerRetentionDays: 540
        },
        emailBrand: {
          name: "PortDesk",
          accentColor: "#15A05C"
        }
      }
    });

    expect(updated.statusCode).toBe(200);
    expect(updated.json().data).toEqual(
      expect.objectContaining({
        supportEmail: "help@example.com",
        githubRepository: "portdesk-app",
        dataRetentionPolicy: {
          feedbackRetentionDays: 365,
          diagnosticsRetentionDays: 30,
          auditLogRetentionDays: 1095,
          inactiveCustomerRetentionDays: 540
        },
        emailBrand: {
          name: "PortDesk",
          accentColor: "#15A05C"
        }
      })
    );

    const rejectedArchive = await server.inject({
      method: "POST",
      url: "/api/v1/products/portdesk/archive",
      headers,
      payload: {
        confirmation: "wrong"
      }
    });
    expect(rejectedArchive.statusCode).toBe(409);

    const archived = await server.inject({
      method: "POST",
      url: "/api/v1/products/portdesk/archive",
      headers,
      payload: {
        confirmation: "ARCHIVE"
      }
    });
    expect(archived.statusCode).toBe(200);
    expect(archived.json().data.status).toBe("archived");

    const auditLogs = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=portdesk",
      headers
    });
    expect(auditLogs.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ action: "product.created" }),
        expect.objectContaining({ action: "product.updated" }),
        expect.objectContaining({ action: "product.archived" })
      ])
    );
  });

  it("rotates the feedback API key and rejects missing or stale keys", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const created = await server.inject({
      method: "POST",
      url: "/api/v1/products",
      headers,
      payload: productPayload
    });
    const initialKey = created.json().data.feedbackApiKey as string;

    const missingKey = await server.inject({
      method: "POST",
      url: "/api/v1/public/products/portdesk/feedback",
      payload: {
        title: "Cannot connect",
        description: "The connection fails after launch.",
        type: "bug"
      }
    });
    expect(missingKey.statusCode).toBe(401);

    const accepted = await server.inject({
      method: "POST",
      url: "/api/v1/public/products/portdesk/feedback",
      headers: {
        "x-product-api-key": initialKey
      },
      payload: {
        title: "Cannot connect",
        description: "The connection fails after launch.",
        type: "bug"
      }
    });
    expect(accepted.statusCode).toBe(201);

    const rotated = await server.inject({
      method: "POST",
      url: "/api/v1/products/portdesk/feedback-api-key/rotate",
      headers,
      payload: {
        confirmation: "ROTATE"
      }
    });
    expect(rotated.statusCode).toBe(200);
    expect(rotated.json().data.feedbackApiKey).toMatch(/^pfk_/);
    expect(rotated.json().data.feedbackApiKey).not.toBe(initialKey);

    const staleKey = await server.inject({
      method: "POST",
      url: "/api/v1/public/products/portdesk/feedback",
      headers: {
        "x-product-api-key": initialKey
      },
      payload: {
        title: "Stale key",
        description: "This request must be rejected.",
        type: "bug"
      }
    });
    expect(staleKey.statusCode).toBe(401);

    const currentKey = await server.inject({
      method: "POST",
      url: "/api/v1/public/products/portdesk/feedback",
      headers: {
        "x-product-api-key": rotated.json().data.feedbackApiKey
      },
      payload: {
        title: "Current key",
        description: "This request should be accepted.",
        type: "bug"
      }
    });
    expect(currentKey.statusCode).toBe(201);

    const product = await server.inject({
      method: "GET",
      url: "/api/v1/products/portdesk",
      headers
    });
    expect(product.json().data).not.toHaveProperty("feedbackApiKey");
    expect(product.json().data).not.toHaveProperty("feedbackApiKeyHash");
  });

  it("rate limits repeated public feedback submissions per product key and source", async () => {
    vi.stubEnv("PUBLIC_FEEDBACK_RATE_LIMIT_MAX", "2");
    vi.stubEnv("PUBLIC_FEEDBACK_RATE_LIMIT_WINDOW_SECONDS", "60");
    try {
      const server = buildServer();
      const headers = await ownerAuthorization(server);
      const created = await server.inject({
        method: "POST",
        url: "/api/v1/products",
        headers,
        payload: productPayload
      });
      const feedbackApiKey = created.json().data.feedbackApiKey as string;
      const request = {
        method: "POST" as const,
        url: "/api/v1/public/products/portdesk/feedback",
        headers: {
          "x-product-api-key": feedbackApiKey
        },
        remoteAddress: "198.51.100.12",
        payload: {
          title: "Repeated feedback",
          description: "This request exercises the public rate limit.",
          type: "bug"
        }
      };

      const first = await server.inject(request);
      const second = await server.inject(request);
      const limited = await server.inject(request);

      expect(first.statusCode).toBe(201);
      expect(second.statusCode).toBe(201);
      expect(limited.statusCode).toBe(429);
      expect(limited.headers["retry-after"]).toBeDefined();
      expect(limited.json().error.code).toBe("RATE_LIMITED");
    } finally {
      vi.unstubAllEnvs();
    }
  });
});
