import { describe, expect, it } from "vitest";
import { createMemoryStore } from "../src/data/store.js";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

const productPayload = {
  id: "pagination-product",
  name: "Pagination Product",
  platform: "macOS",
  bundleId: "com.stacio.pagination",
  supportEmail: "support@example.com"
};

async function createPublishableRelease(
  store: ReturnType<typeof createMemoryStore>,
  input: { version: string; buildNumber: string; artifactName: string; artifactSize: number }
) {
  const release = await store.createRelease("stacio", {
    channel: "dev",
    version: input.version,
    buildNumber: input.buildNumber,
    minimumSystemVersion: "14.0",
    artifactName: input.artifactName,
    artifactUrl: `https://downloads.example.com/${input.artifactName}`,
    artifactObjectKey: `products/stacio/releases/dev/${input.artifactName}`,
    artifactType: "application/x-apple-diskimage",
    artifactSize: input.artifactSize,
    artifactSha256: "a".repeat(64),
    sparkleEdDsaSignature: `signature-${input.buildNumber}`,
    releaseNotes: `Release notes for ${input.version}`,
    downloadReachabilityEvidence: {
      status: "reachable",
      contentLength: input.artifactSize
    }
  });
  expect(release).toBeTruthy();
  const validation = await store.validateRelease("stacio", release?.id ?? "");
  expect(validation?.passed).toBe(true);
  const published = await store.publishRelease("stacio", release?.id ?? "", "usr_development_owner");
  expect(published).toBeTruthy();
  return published;
}

describe("API pagination protocol", () => {
  it("paginates product lists with the documented response metadata", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    await server.inject({
      method: "POST",
      url: "/api/v1/products",
      headers,
      payload: productPayload
    });

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products?page=1&page_size=1",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 1,
      page_size: 1,
      total_pages: 2,
      has_next: true,
      has_prev: false
    });
  });

  it("paginates filtered feedback lists with one-based pages", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback?page=2&page_size=1",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 2,
      page_size: 1,
      total_pages: 2,
      has_next: false,
      has_prev: true
    });
  });

  it("paginates release lists", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/releases?page=2&page_size=1",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 2,
      page_size: 1,
      total_pages: 2,
      has_next: false,
      has_prev: true
    });
  });

  it("paginates license lists", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/licenses?page=1&page_size=1",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 1,
      page_size: 1,
      total_pages: 2,
      has_next: true,
      has_prev: false
    });
  });

  it("paginates customer lists", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/customers?page=2&page_size=1",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 2,
      page_size: 1,
      total_pages: 2,
      has_next: false,
      has_prev: true
    });
  });

  it("paginates release channel lists", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/channels?page=2&page_size=1",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 4,
      page: 2,
      page_size: 1,
      total_pages: 4,
      has_next: true,
      has_prev: true
    });
  });

  it("paginates license plan lists", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/plans?page=2&page_size=1",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 4,
      page: 2,
      page_size: 1,
      total_pages: 4,
      has_next: true,
      has_prev: true
    });
  });

  it("paginates connector lists", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/connectors?page=3&page_size=1",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 5,
      page: 3,
      page_size: 1,
      total_pages: 5,
      has_next: true,
      has_prev: true
    });
  });

  it("paginates notification template lists", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/notification-templates?page=2&page_size=5",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(5);
    expect(body.pagination).toEqual({
      total: 14,
      page: 2,
      page_size: 5,
      total_pages: 3,
      has_next: true,
      has_prev: true
    });
  });

  it("paginates admin role lists", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/admin/roles?page=2&page_size=2",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(2);
    expect(body.pagination).toEqual({
      total: 5,
      page: 2,
      page_size: 2,
      total_pages: 3,
      has_next: true,
      has_prev: true
    });
  });

  it("paginates admin user lists", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    for (const index of [1, 2]) {
      const created = await server.inject({
        method: "POST",
        url: "/api/v1/admin/users",
        headers,
        payload: {
          email: `pagination-admin-${index}@example.com`,
          name: `Pagination Admin ${index}`,
          password: "change-me-too",
          role: "operator",
          productIds: ["stacio"]
        }
      });
      expect(created.statusCode).toBe(201);
    }

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/admin/users?page=2&page_size=2",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 3,
      page: 2,
      page_size: 2,
      total_pages: 2,
      has_next: false,
      has_prev: true
    });
  });

  it("paginates admin Agent API key lists", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    for (const index of [1, 2]) {
      const created = await server.inject({
        method: "POST",
        url: "/api/v1/admin/agent-api-keys",
        headers,
        payload: {
          name: `Pagination Agent Key ${index}`,
          productIds: ["stacio"],
          scopes: ["feedback:read"]
        }
      });
      expect(created.statusCode).toBe(201);
    }

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/admin/agent-api-keys?page=2&page_size=1",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 2,
      page_size: 1,
      total_pages: 2,
      has_next: false,
      has_prev: true
    });
  });

  it("paginates release appcast entry lists", async () => {
    const store = createMemoryStore();
    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);

    await createPublishableRelease(store, {
      version: "1.0.1-Dev",
      buildNumber: "901",
      artifactName: "Stacio-1.0.1-Dev.dmg",
      artifactSize: 901
    });
    await createPublishableRelease(store, {
      version: "1.0.2-Dev",
      buildNumber: "902",
      artifactName: "Stacio-1.0.2-Dev.dmg",
      artifactSize: 902
    });

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/appcast-entries?channel=dev&page=2&page_size=1",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 2,
      page_size: 1,
      total_pages: 2,
      has_next: false,
      has_prev: true
    });
  });

  it("paginates release artifact lists", async () => {
    const store = createMemoryStore();
    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);

    const release = await store.createRelease("stacio", {
      channel: "dev",
      version: "1.0.3-Dev",
      buildNumber: "903",
      artifactName: "Stacio-1.0.3-Dev-a.dmg",
      artifactUrl: "https://downloads.example.com/Stacio-1.0.3-Dev-a.dmg",
      artifactObjectKey: "products/stacio/releases/dev/Stacio-1.0.3-Dev-a.dmg",
      artifactType: "application/x-apple-diskimage",
      artifactSize: 903,
      artifactSha256: "b".repeat(64),
      packageSignatureEvidence: {
        status: "passed"
      }
    });
    expect(release).toBeTruthy();
    const updated = await store.updateReleaseDraft("stacio", release?.id ?? "", {
      artifactName: "Stacio-1.0.3-Dev-b.dmg",
      artifactUrl: "https://downloads.example.com/Stacio-1.0.3-Dev-b.dmg",
      artifactObjectKey: "products/stacio/releases/dev/Stacio-1.0.3-Dev-b.dmg",
      artifactType: "application/x-apple-diskimage",
      artifactSize: 904,
      artifactSha256: "c".repeat(64),
      packageSignatureEvidence: {
        status: "passed"
      }
    });
    expect(updated).toBeTruthy();

    const response = await server.inject({
      method: "GET",
      url: `/api/v1/products/stacio/releases/${release?.id}/artifacts?page=2&page_size=1`,
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 2,
      page_size: 1,
      total_pages: 2,
      has_next: false,
      has_prev: true
    });
  });

  it("paginates notification delivery lists", async () => {
    const store = createMemoryStore();
    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);

    const notification = await store.createNotification("stacio", {
      type: "customer_feedback_reply",
      recipient: "delivery-pagination@example.com",
      payload: {
        reply: "Thanks for the report."
      },
      status: "sent"
    });
    expect(notification).toBeTruthy();
    await store.createNotificationDelivery(notification?.id ?? "", {
      provider: "smtp",
      status: "sent",
      responseBody: "250 accepted"
    });
    await store.createNotificationDelivery(notification?.id ?? "", {
      provider: "smtp",
      status: "failed",
      errorMessage: "SMTP timeout"
    });

    const response = await server.inject({
      method: "GET",
      url: `/api/v1/products/stacio/notifications/${notification?.id}/deliveries?page=2&page_size=1`,
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 2,
      page_size: 1,
      total_pages: 2,
      has_next: false,
      has_prev: true
    });
  });

  it("paginates GitHub issue lists after sync", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/github/sync",
      headers,
      payload: {
        trigger: "manual",
        issues: [
          {
            githubIssueId: "gh_pagination_1",
            number: 501,
            title: "First pagination issue",
            state: "open",
            url: "https://github.com/stacio/stacio/issues/501"
          },
          {
            githubIssueId: "gh_pagination_2",
            number: 502,
            title: "Second pagination issue",
            state: "open",
            url: "https://github.com/stacio/stacio/issues/502"
          }
        ]
      }
    });

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/github/issues?page=2&page_size=1",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 2,
      page_size: 1,
      total_pages: 2,
      has_next: false,
      has_prev: true
    });
  });

  it("paginates audit log lists after admin actions", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    await server.inject({
      method: "POST",
      url: "/api/v1/products",
      headers,
      payload: {
        ...productPayload,
        id: "pagination-audit-product"
      }
    });

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?page=1&page_size=1",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 1,
      page_size: 1,
      total_pages: 2,
      has_next: true,
      has_prev: false
    });
  });

  it("paginates product notification lists", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    for (const index of [1, 2]) {
      const created = await server.inject({
        method: "POST",
        url: "/api/v1/products/stacio/notifications",
        headers,
        payload: {
          type: "customer_feedback_reply",
          recipient: `pagination-${index}@example.com`,
          priority: "normal",
          payload: {
            reply: `Reply ${index}`
          }
        }
      });
      expect(created.statusCode).toBe(201);
    }

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/notifications?page=2&page_size=1",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 2,
      page_size: 1,
      total_pages: 2,
      has_next: false,
      has_prev: true
    });
  });

  it("paginates admin AI analysis lists", async () => {
    const store = createMemoryStore();
    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);

    for (const index of [1, 2]) {
      await store.createAiAnalysis({
        productId: "stacio",
        targetType: "feedback",
        targetId: "fb_001",
        agentIdentity: `agent-${index}`,
        analysisType: "feedback_summary",
        outputBody: {
          summary: `Summary ${index}`
        }
      });
    }

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/ai-analysis?page=2&page_size=1",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 2,
      page_size: 1,
      total_pages: 2,
      has_next: false,
      has_prev: true
    });
  });

  it("paginates admin proposed action lists", async () => {
    const store = createMemoryStore();
    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);

    for (const index of [1, 2]) {
      const analysis = await store.createAiAnalysis({
        productId: "stacio",
        targetType: "feedback",
        targetId: "fb_001",
        agentIdentity: `agent-${index}`,
        analysisType: "feedback_action",
        outputBody: {
          summary: `Action ${index}`
        }
      });
      await store.createProposedAction({
        analysisId: analysis?.id ?? "",
        actionType: "feedback.update_priority",
        payload: {
          priority: index === 1 ? "P1" : "P2"
        }
      });
    }

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/proposed-actions?page=1&page_size=1",
      headers
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 1,
      page_size: 1,
      total_pages: 2,
      has_next: true,
      has_prev: false
    });
  });

  it("paginates Agent-facing request queues", async () => {
    const store = createMemoryStore();
    const server = buildServer({ store });

    for (const index of [1, 2]) {
      await store.createAgentRequest({
        productId: "stacio",
        targetType: "feedback",
        targetId: "fb_001",
        requestType: "summary",
        agentHint: "codex",
        prompt: `Summarize feedback ${index}.`
      });
    }

    const response = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/feedback/agent-requests?status=queued&page=2&page_size=1",
      headers: {
        authorization: "Bearer development-agent-key"
      }
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 2,
      page_size: 1,
      total_pages: 2,
      has_next: false,
      has_prev: true
    });
  });

  it("paginates Agent-facing feedback triage queues", async () => {
    const server = buildServer();

    const response = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/feedback/triage-queue?page=2&page_size=1",
      headers: {
        authorization: "Bearer development-agent-key"
      }
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 2,
      page_size: 1,
      total_pages: 2,
      has_next: false,
      has_prev: true
    });
  });

  it("paginates Agent-facing GitHub issue lists", async () => {
    const store = createMemoryStore();
    const server = buildServer({ store });

    await store.syncGitHubIssues("stacio", {
      trigger: "manual",
      issues: [
        {
          githubIssueId: "gh_agent_page_1",
          number: 601,
          title: "First Agent issue",
          state: "open",
          url: "https://github.com/stacio/stacio/issues/601"
        },
        {
          githubIssueId: "gh_agent_page_2",
          number: 602,
          title: "Second Agent issue",
          state: "open",
          url: "https://github.com/stacio/stacio/issues/602"
        }
      ]
    });

    const response = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/github/issues?page=2&page_size=1",
      headers: {
        authorization: "Bearer development-agent-key"
      }
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 2,
      page_size: 1,
      total_pages: 2,
      has_next: false,
      has_prev: true
    });
  });

  it("paginates Agent-facing customer lists", async () => {
    const store = createMemoryStore();
    const server = buildServer({ store });

    for (const index of [1, 2]) {
      await store.createCustomer("stacio", {
        email: `agent-customer-${index}@example.com`,
        name: `Agent Customer ${index}`
      });
    }

    const response = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/customers?page=1&page_size=1",
      headers: {
        authorization: "Bearer development-agent-key"
      }
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 4,
      page: 1,
      page_size: 1,
      total_pages: 4,
      has_next: true,
      has_prev: false
    });
  });

  it("paginates Agent-facing license lists", async () => {
    const server = buildServer();

    const response = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/licenses?page=2&page_size=1",
      headers: {
        authorization: "Bearer development-agent-key"
      }
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 2,
      page_size: 1,
      total_pages: 2,
      has_next: false,
      has_prev: true
    });
  });

  it("paginates Agent-facing release draft lists", async () => {
    const store = createMemoryStore();
    const server = buildServer({ store });

    for (const index of [1, 2]) {
      await store.createRelease("stacio", {
        channel: "beta",
        version: `0.20.${index}-Beta`,
        buildNumber: `20${index}`,
        artifactName: `Stacio-0.20.${index}-Beta.dmg`
      });
    }

    const response = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/releases/drafts?page=1&page_size=1",
      headers: {
        authorization: "Bearer development-agent-key"
      }
    });

    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.data).toHaveLength(1);
    expect(body.pagination).toEqual({
      total: 2,
      page: 1,
      page_size: 1,
      total_pages: 2,
      has_next: true,
      has_prev: false
    });
  });
});
