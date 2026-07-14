import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createMemoryStore } from "../src/data/store.js";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

describe("connector management", () => {
  beforeEach(() => {
    vi.stubEnv("CONNECTOR_ENCRYPTION_KEY_BASE64", Buffer.alloc(32, 7).toString("base64"));
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("stores connector secrets encrypted and never returns them from admin APIs", async () => {
    const store = createMemoryStore();
    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "PUT",
      url: "/api/v1/products/stacio/connectors/github",
      headers,
      payload: {
        config: {
          owner: "zerx-lab",
          repository: "stacio",
          apiBaseUrl: "https://api.github.com"
        },
        secrets: {
          token: "github-secret-token"
        }
      }
    });

    expect(response.statusCode).toBe(200);
    expect(response.json().data).toEqual(
      expect.objectContaining({
        type: "github",
        status: "configured",
        hasSecrets: true,
        config: {
          owner: "zerx-lab",
          repository: "stacio",
          apiBaseUrl: "https://api.github.com"
        }
      })
    );
    expect(JSON.stringify(response.json())).not.toContain("github-secret-token");
    expect(JSON.stringify(response.json())).not.toContain("encryptedSecrets");

    const list = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/connectors",
      headers
    });
    expect(JSON.stringify(list.json())).not.toContain("github-secret-token");
    expect(JSON.stringify(list.json())).not.toContain("encryptedSecrets");
    expect(list.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          type: "github",
          hasSecrets: true
        })
      ])
    );

    const envelope = await store.getConnectorSecretEnvelope("stacio", "github");
    expect(envelope).toMatch(/^v1\./);
    expect(envelope).not.toContain("github-secret-token");

    const auditLogs = await store.listAuditLogs("stacio");
    expect(auditLogs).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "connector.configured",
          targetId: "github"
        })
      ])
    );
  });

  it("supports the PRD-required webhook connector type", async () => {
    const store = createMemoryStore();
    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "PUT",
      url: "/api/v1/products/stacio/connectors/webhook",
      headers,
      payload: {
        config: {
          url: "https://hooks.example.com/stacio",
          eventTypes: ["feedback.created", "license.revoked"],
          signingHeader: "X-Stacio-Signature"
        },
        secrets: {
          signingSecret: "webhook-signing-secret"
        }
      }
    });

    expect(response.statusCode).toBe(200);
    expect(response.json().data).toEqual(
      expect.objectContaining({
        type: "webhook",
        name: "Webhook",
        status: "configured",
        hasSecrets: true,
        config: {
          url: "https://hooks.example.com/stacio",
          eventTypes: ["feedback.created", "license.revoked"],
          signingHeader: "X-Stacio-Signature"
        }
      })
    );
    expect(JSON.stringify(response.json())).not.toContain("webhook-signing-secret");
  });

  it("tests a connector with decrypted secrets and records success or failure", async () => {
    const store = createMemoryStore();
    const testConnection = vi
      .fn()
      .mockResolvedValueOnce({ message: "GitHub repository is accessible" })
      .mockRejectedValueOnce(new Error("GitHub token rejected"));
    const server = buildServer({
      store,
      connectorTester: {
        test: testConnection
      }
    });
    const headers = await ownerAuthorization(server);

    await server.inject({
      method: "PUT",
      url: "/api/v1/products/stacio/connectors/github",
      headers,
      payload: {
        config: {
          owner: "zerx-lab",
          repository: "stacio"
        },
        secrets: {
          token: "github-secret-token"
        }
      }
    });

    const succeeded = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/connectors/github/test",
      headers
    });
    expect(succeeded.statusCode).toBe(200);
    expect(succeeded.json().data).toEqual(
      expect.objectContaining({
        result: {
          message: "GitHub repository is accessible"
        },
        connector: expect.objectContaining({
          status: "configured",
          lastSuccessAt: expect.any(String),
          lastError: null
        })
      })
    );
    expect(testConnection).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({
        productId: "stacio",
        type: "github",
        config: {
          owner: "zerx-lab",
          repository: "stacio"
        },
        secrets: {
          token: "github-secret-token"
        }
      })
    );

    const failed = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/connectors/github/test",
      headers
    });
    expect(failed.statusCode).toBe(502);
    expect(failed.json().error).toEqual(
      expect.objectContaining({
        code: "CONNECTOR_TEST_FAILED",
        message: "GitHub token rejected"
      })
    );

    const connector = (await store.listConnectors("stacio")).find((item) => item.type === "github");
    expect(connector).toEqual(
      expect.objectContaining({
        status: "error",
        lastError: "GitHub token rejected"
      })
    );

    const auditLogs = await store.listAuditLogs("stacio");
    expect(auditLogs).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ action: "connector.test_succeeded", targetId: "github" }),
        expect.objectContaining({ action: "connector.test_failed", targetId: "github" })
      ])
    );
  });

  it("requires typed confirmation before disconnecting and clears stored secrets", async () => {
    const store = createMemoryStore();
    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);

    await server.inject({
      method: "PUT",
      url: "/api/v1/products/stacio/connectors/smtp",
      headers,
      payload: {
        config: {
          host: "smtp.feishu.cn",
          port: 465,
          secure: true,
          user: "support@example.com",
          from: "support@example.com"
        },
        secrets: {
          password: "smtp-secret-password"
        }
      }
    });

    const rejected = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/connectors/smtp/disconnect",
      headers,
      payload: {
        confirmation: "wrong"
      }
    });
    expect(rejected.statusCode).toBe(409);
    expect(await store.getConnectorSecretEnvelope("stacio", "smtp")).toBeTruthy();

    const disconnected = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/connectors/smtp/disconnect",
      headers,
      payload: {
        confirmation: "DISCONNECT"
      }
    });
    expect(disconnected.statusCode).toBe(200);
    expect(disconnected.json().data).toEqual(
      expect.objectContaining({
        type: "smtp",
        status: "disabled",
        hasSecrets: false
      })
    );
    expect(await store.getConnectorSecretEnvelope("stacio", "smtp")).toBeUndefined();

    const auditLogs = await store.listAuditLogs("stacio");
    expect(auditLogs).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "connector.disconnected",
          targetId: "smtp"
        })
      ])
    );
  });
});
