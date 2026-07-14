import { describe, expect, it } from "vitest";
import { createMemoryStore } from "../src/data/store.js";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

describe("Agent API key management", () => {
  it("creates, lists, uses and disables scoped Agent API keys without exposing stored secrets", async () => {
    const store = createMemoryStore();
    await store.createProduct({
      id: "other-product",
      name: "Other Product",
      platform: "macOS",
      bundleId: "com.example.OtherProduct",
      supportEmail: "support@example.com"
    });
    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);

    const createResponse = await server.inject({
      method: "POST",
      url: "/api/v1/admin/agent-api-keys",
      headers,
      payload: {
        name: "Codex feedback triage",
        productIds: ["stacio"],
        scopes: ["feedback:read"],
        expiresAt: "2099-01-01T00:00:00.000Z"
      }
    });
    expect(createResponse.statusCode).toBe(201);
    const created = createResponse.json().data;
    expect(created).toEqual(
      expect.objectContaining({
        name: "Codex feedback triage",
        productIds: ["stacio"],
        scopes: ["feedback:read"],
        status: "active"
      })
    );
    expect(created.key).toMatch(/^agent_[a-f0-9]{48}$/);
    expect(created.keyHash).toBeUndefined();

    const listResponse = await server.inject({
      method: "GET",
      url: "/api/v1/admin/agent-api-keys",
      headers
    });
    expect(listResponse.statusCode).toBe(200);
    expect(listResponse.json().data).toEqual([
      expect.objectContaining({
        id: created.id,
        keyPrefix: created.keyPrefix,
        productIds: ["stacio"],
        scopes: ["feedback:read"],
        status: "active"
      })
    ]);
    expect(listResponse.json().data[0].key).toBeUndefined();
    expect(listResponse.json().data[0].keyHash).toBeUndefined();

    const allowed = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/feedback/triage-queue",
      headers: {
        authorization: `Bearer ${created.key}`
      }
    });
    expect(allowed.statusCode).toBe(200);

    const deniedScope = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/releases/drafts",
      headers: {
        authorization: `Bearer ${created.key}`
      }
    });
    expect(deniedScope.statusCode).toBe(403);
    expect(deniedScope.json().error.code).toBe("AGENT_SCOPE_DENIED");

    const deniedProduct = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/other-product/feedback/triage-queue",
      headers: {
        authorization: `Bearer ${created.key}`
      }
    });
    expect(deniedProduct.statusCode).toBe(403);
    expect(deniedProduct.json().error.code).toBe("AGENT_PRODUCT_ACCESS_DENIED");

    const disableResponse = await server.inject({
      method: "PATCH",
      url: `/api/v1/admin/agent-api-keys/${created.id}`,
      headers,
      payload: {
        status: "disabled",
        confirmation: "DISABLE"
      }
    });
    expect(disableResponse.statusCode).toBe(200);
    expect(disableResponse.json().data).toEqual(
      expect.objectContaining({
        id: created.id,
        status: "disabled"
      })
    );

    const disabled = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/feedback/triage-queue",
      headers: {
        authorization: `Bearer ${created.key}`
      }
    });
    expect(disabled.statusCode).toBe(401);
    expect(disabled.json().error.code).toBe("AGENT_KEY_DISABLED");

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs",
      headers
    });
    expect(auditResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "agent_api_key.created",
          targetId: created.id
        }),
        expect.objectContaining({
          action: "agent_api_key.disabled",
          targetId: created.id
        })
      ])
    );
  });

  it("rotates an Agent API key, invalidates the old token, and audits the change", async () => {
    const store = createMemoryStore();
    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);

    const createResponse = await server.inject({
      method: "POST",
      url: "/api/v1/admin/agent-api-keys",
      headers,
      payload: {
        name: "Claude release drafter",
        productIds: ["stacio"],
        scopes: ["releases:read"],
        expiresAt: "2099-01-01T00:00:00.000Z"
      }
    });
    expect(createResponse.statusCode).toBe(201);
    const created = createResponse.json().data;

    const rotateResponse = await server.inject({
      method: "POST",
      url: `/api/v1/admin/agent-api-keys/${created.id}/rotate`,
      headers,
      payload: {
        confirmation: "ROTATE"
      }
    });
    expect(rotateResponse.statusCode).toBe(200);
    const rotated = rotateResponse.json().data;
    expect(rotated).toEqual(
      expect.objectContaining({
        id: created.id,
        name: "Claude release drafter",
        productIds: ["stacio"],
        scopes: ["releases:read"],
        status: "active"
      })
    );
    expect(rotated.key).toMatch(/^agent_[a-f0-9]{48}$/);
    expect(rotated.key).not.toBe(created.key);
    expect(rotated.keyPrefix).not.toBe(created.keyPrefix);
    expect(rotated.keyHash).toBeUndefined();

    const oldTokenResponse = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/releases/drafts",
      headers: {
        authorization: `Bearer ${created.key}`
      }
    });
    expect(oldTokenResponse.statusCode).toBe(401);
    expect(oldTokenResponse.json().error.code).toBe("UNAUTHORIZED_AGENT");

    const newTokenResponse = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/releases/drafts",
      headers: {
        authorization: `Bearer ${rotated.key}`
      }
    });
    expect(newTokenResponse.statusCode).toBe(200);

    const listResponse = await server.inject({
      method: "GET",
      url: "/api/v1/admin/agent-api-keys",
      headers
    });
    expect(listResponse.json().data).toEqual([
      expect.objectContaining({
        id: created.id,
        keyPrefix: rotated.keyPrefix
      })
    ]);
    expect(listResponse.json().data[0].key).toBeUndefined();
    expect(listResponse.json().data[0].keyHash).toBeUndefined();

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs",
      headers
    });
    expect(auditResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "agent_api_key.rotated",
          targetId: created.id
        })
      ])
    );
  });
});
