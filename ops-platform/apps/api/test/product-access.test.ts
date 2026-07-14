import { randomUUID } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { afterEach, describe, expect, it, vi } from "vitest";
import { hashPasswordSync } from "../src/auth/password.js";
import type { AuthStore, AuthUser, RefreshTokenRecord } from "../src/auth/store.js";
import { createMemoryStore } from "../src/data/store.js";
import { buildServer } from "../src/server.js";

const restrictedCredentials = {
  email: "stacio-admin@example.com",
  password: "restricted-password"
};

afterEach(() => {
  vi.unstubAllEnvs();
});

function createRestrictedAuthStore(productIds = ["stacio"]): AuthStore {
  const refreshTokens = new Map<string, RefreshTokenRecord>();
  const user: AuthUser = {
    id: "usr_stacio_admin",
    email: restrictedCredentials.email,
    name: "Stacio Admin",
    passwordHash: hashPasswordSync(restrictedCredentials.password, Buffer.from("stacio-admin-salt")),
    status: "active",
    roles: ["admin"],
    permissions: ["products:read", "products:write", "audit:read"],
    productIds
  };

  return {
    async findByEmail(email) {
      return email.toLowerCase() === user.email ? user : undefined;
    },
    async findById(id) {
      return id === user.id ? user : undefined;
    },
    async touchLastLogin() {},
    async createRefreshToken(input) {
      const record: RefreshTokenRecord = {
        id: `rt_${randomUUID()}`,
        ...input,
        createdAt: new Date().toISOString()
      };
      refreshTokens.set(record.tokenHash, record);
      return record;
    },
    async findRefreshToken(tokenHash) {
      return refreshTokens.get(tokenHash);
    },
    async revokeRefreshToken(tokenHash, replacedByTokenHash) {
      const record = refreshTokens.get(tokenHash);
      if (!record || record.revokedAt) {
        return;
      }
      record.revokedAt = new Date().toISOString();
      record.replacedByTokenHash = replacedByTokenHash;
    },
    async listRoles() {
      return [];
    },
    async listUsers() {
      return [];
    },
    async createUser() {
      return "unknown_role";
    },
    async updateUser() {
      return undefined;
    }
  };
}

async function restrictedAuthorization(server: FastifyInstance) {
  const response = await server.inject({
    method: "POST",
    url: "/api/v1/auth/login",
    payload: restrictedCredentials
  });
  expect(response.statusCode).toBe(200);
  return {
    authorization: `Bearer ${response.json().data.token}`
  };
}

async function addSecondProduct(store: ReturnType<typeof createMemoryStore>) {
  await store.createProduct({
    id: "other-product",
    name: "Other Product",
    platform: "macOS",
    bundleId: "com.example.OtherProduct",
    supportEmail: "support@example.com"
  });
}

describe("product-scoped authorization", () => {
  it("denies an unassigned product path and audits the product denial", async () => {
    const store = createMemoryStore();
    await addSecondProduct(store);
    const server = buildServer({
      store,
      authStore: createRestrictedAuthStore()
    });
    const headers = await restrictedAuthorization(server);

    const allowed = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/dashboard",
      headers
    });
    expect(allowed.statusCode).toBe(200);

    const denied = await server.inject({
      method: "GET",
      url: "/api/v1/products/other-product/dashboard",
      headers
    });
    expect(denied.statusCode).toBe(403);
    expect(denied.json()).toEqual(
      expect.objectContaining({
        error: expect.objectContaining({
          code: "PRODUCT_ACCESS_DENIED"
        })
      })
    );

    expect(await store.listAuditLogs()).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "authorization.denied",
          productId: "other-product",
          metadata: expect.objectContaining({
            method: "GET",
            url: "/api/v1/products/other-product/dashboard"
          })
        })
      ])
    );
  });

  it("returns only products assigned to a restricted user", async () => {
    const store = createMemoryStore();
    await addSecondProduct(store);
    const server = buildServer({
      store,
      authStore: createRestrictedAuthStore()
    });
    const headers = await restrictedAuthorization(server);

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products",
      headers
    });

    expect(response.statusCode).toBe(200);
    expect(response.json().data.map((product: { id: string }) => product.id)).toEqual(["stacio"]);
  });

  it("filters unscoped audit logs and rejects an unassigned product query", async () => {
    const store = createMemoryStore();
    await addSecondProduct(store);
    await store.createAuditLog({
      actorType: "user",
      actorId: "user_stacio",
      action: "stacio.changed",
      targetType: "product",
      targetId: "stacio",
      productId: "stacio"
    });
    await store.createAuditLog({
      actorType: "user",
      actorId: "user_other",
      action: "other.changed",
      targetType: "product",
      targetId: "other-product",
      productId: "other-product"
    });
    const server = buildServer({
      store,
      authStore: createRestrictedAuthStore()
    });
    const headers = await restrictedAuthorization(server);

    const listResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs",
      headers
    });
    expect(listResponse.statusCode).toBe(200);
    expect(listResponse.json().data).toEqual([
      expect.objectContaining({
        action: "stacio.changed",
        productId: "stacio"
      })
    ]);

    const deniedResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=other-product",
      headers
    });
    expect(deniedResponse.statusCode).toBe(403);
    expect(deniedResponse.json().error.code).toBe("PRODUCT_ACCESS_DENIED");
  });

  it("does not let a product-scoped user create global products", async () => {
    const server = buildServer({
      authStore: createRestrictedAuthStore()
    });
    const headers = await restrictedAuthorization(server);

    const response = await server.inject({
      method: "POST",
      url: "/api/v1/products",
      headers,
      payload: {
        id: "unauthorized-product",
        name: "Unauthorized Product",
        platform: "macOS",
        bundleId: "com.example.Unauthorized",
        supportEmail: "support@example.com"
      }
    });

    expect(response.statusCode).toBe(403);
    expect(response.json().error.code).toBe("GLOBAL_ACCESS_REQUIRED");
  });

  it("uses the only assigned product for settings when productId is omitted", async () => {
    const store = createMemoryStore();
    await addSecondProduct(store);
    const server = buildServer({
      store,
      authStore: createRestrictedAuthStore(["other-product"])
    });
    const headers = await restrictedAuthorization(server);

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/settings/summary",
      headers
    });

    expect(response.statusCode).toBe(200);
    expect(response.json().data.productId).toBe("other-product");
  });

  it("enforces Agent API product restrictions, scopes, and expiration", async () => {
    vi.stubEnv(
      "AGENT_API_KEYS_JSON",
      JSON.stringify([
        {
          id: "agent_stacio_feedback",
          key: "agent-stacio-feedback-key",
          name: "Stacio feedback triage",
          productIds: ["stacio"],
          scopes: ["feedback:read", "feedback:write_analysis"],
          expiresAt: "2099-01-01T00:00:00.000Z"
        },
        {
          id: "agent_other_feedback",
          key: "agent-other-feedback-key",
          name: "Other feedback triage",
          productIds: ["other-product"],
          scopes: ["feedback:read", "feedback:write_analysis"],
          expiresAt: "2099-01-01T00:00:00.000Z"
        },
        {
          id: "agent_expired",
          key: "agent-expired-key",
          name: "Expired agent",
          productIds: ["stacio"],
          scopes: ["feedback:read"],
          expiresAt: "2020-01-01T00:00:00.000Z"
        }
      ])
    );
    const store = createMemoryStore();
    await addSecondProduct(store);
    const server = buildServer({ store });

    const allowed = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/feedback/triage-queue",
      headers: {
        authorization: "Bearer agent-stacio-feedback-key"
      }
    });
    expect(allowed.statusCode).toBe(200);

    const deniedProduct = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/other-product/feedback/triage-queue",
      headers: {
        authorization: "Bearer agent-stacio-feedback-key"
      }
    });
    expect(deniedProduct.statusCode).toBe(403);
    expect(deniedProduct.json().error.code).toBe("AGENT_PRODUCT_ACCESS_DENIED");

    const deniedScope = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/releases/drafts",
      headers: {
        authorization: "Bearer agent-stacio-feedback-key"
      }
    });
    expect(deniedScope.statusCode).toBe(403);
    expect(deniedScope.json().error.code).toBe("AGENT_SCOPE_DENIED");

    const expired = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/feedback/triage-queue",
      headers: {
        authorization: "Bearer agent-expired-key"
      }
    });
    expect(expired.statusCode).toBe(401);
    expect(expired.json().error.code).toBe("AGENT_KEY_EXPIRED");

    expect(await store.listAuditLogs()).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          actorType: "agent",
          actorId: "agent_stacio_feedback",
          action: "agent.authorization_denied",
          productId: "other-product"
        }),
        expect.objectContaining({
          actorType: "agent",
          actorId: "agent_stacio_feedback",
          action: "agent.authorization_denied",
          productId: "stacio"
        })
      ])
    );
  });

  it("returns a controlled error when scoped Agent API keys are invalid JSON", async () => {
    vi.stubEnv("AGENT_API_KEYS_JSON", "{not-valid-json");
    const server = buildServer();

    const response = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/feedback/triage-queue",
      headers: {
        authorization: "Bearer agent-stacio-feedback-key"
      }
    });

    expect(response.statusCode).toBe(503);
    expect(response.json()).toEqual(
      expect.objectContaining({
        error: expect.objectContaining({
          code: "AGENT_API_KEY_CONFIG_INVALID"
        })
      })
    );
  });
});
