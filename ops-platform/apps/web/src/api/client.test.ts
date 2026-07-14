// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from "vitest";
import { getRefreshToken, opsClient, setAuthToken, setRefreshToken } from "./client";

describe("opsClient task enqueue APIs", () => {
  beforeEach(() => {
    window.localStorage.clear();
    setAuthToken("test-token");
    setRefreshToken("rt_test_refresh");
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
  });

  it("stores access and refresh tokens after login", async () => {
    window.localStorage.clear();
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          data: {
            token: "access-token",
            refreshToken: "rt_refresh_token",
            user: {
              id: "usr_owner",
              email: "owner@stacio.local",
              name: "Owner",
              roles: ["owner"],
              permissions: ["*"]
            }
          }
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" }
        }
      )
    );

    await expect(opsClient.login("owner@stacio.local", "change-me-now")).resolves.toEqual(
      expect.objectContaining({
        token: "access-token"
      })
    );

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/auth/login",
      expect.objectContaining({
        method: "POST"
      })
    );
    expect(window.localStorage.getItem("stacio.ops.authToken")).toBe("access-token");
    expect(getRefreshToken()).toBe("rt_refresh_token");
  });

  it("loads and updates the current administrator account", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: {
              id: "usr_owner",
              email: "owner@stacio.local",
              name: "Stacio Owner",
              roles: ["owner"],
              permissions: ["*"],
              productIds: []
            }
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: {
              user: {
                id: "usr_owner",
                email: "admin@stacio.example",
                name: "Stacio Administrator",
                roles: ["owner"],
                permissions: ["*"],
                productIds: []
              },
              reauthenticationRequired: true
            }
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      );

    await expect(opsClient.currentUser()).resolves.toEqual(
      expect.objectContaining({ email: "owner@stacio.local" })
    );
    await expect(
      opsClient.updateCurrentUser({
        name: "Stacio Administrator",
        email: "admin@stacio.example",
        currentPassword: "change-me-now",
        newPassword: "updated-owner-password"
      })
    ).resolves.toEqual(
      expect.objectContaining({ reauthenticationRequired: true })
    );

    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "/api/v1/auth/me",
      expect.objectContaining({ method: "GET" })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "/api/v1/auth/me",
      expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({
          name: "Stacio Administrator",
          email: "admin@stacio.example",
          currentPassword: "change-me-now",
          newPassword: "updated-owner-password"
        })
      })
    );
  });

  it("refreshes the access token after a 401 response and replays the admin request", async () => {
    setAuthToken("expired-token");
    setRefreshToken("rt_old_refresh");
    const fetchMock = vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ ok: false, error: { message: "expired" } }), {
          status: 401,
          headers: { "Content-Type": "application/json" }
        })
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: {
              token: "new-access-token",
              refreshToken: "rt_new_refresh"
            }
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        )
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: [
              {
                id: "role_owner",
                name: "owner",
                permissions: ["*"]
              }
            ]
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        )
      );

    await expect(opsClient.adminRoles()).resolves.toEqual([
      {
        id: "role_owner",
        name: "owner",
        permissions: ["*"]
      }
    ]);

    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "/api/v1/admin/roles?page_size=100",
      expect.objectContaining({
        headers: expect.objectContaining({
          Authorization: "Bearer expired-token"
        })
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "/api/v1/auth/refresh",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ refreshToken: "rt_old_refresh" })
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      3,
      "/api/v1/admin/roles?page_size=100",
      expect.objectContaining({
        headers: expect.objectContaining({
          Authorization: "Bearer new-access-token"
        })
      })
    );
    expect(window.localStorage.getItem("stacio.ops.authToken")).toBe("new-access-token");
    expect(getRefreshToken()).toBe("rt_new_refresh");
  });

  it("requests an expanded default page size for admin table lists while preserving filters", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ ok: true, data: [] }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    );

    await opsClient.adminRoles();
    await opsClient.feedback("stacio", { status: "new", sort: "priority" });
    await opsClient.appcastEntries("stacio", "dev");

    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "/api/v1/admin/roles?page_size=100",
      expect.objectContaining({ method: "GET" })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "/api/v1/products/stacio/feedback?status=new&sort=priority&page_size=100",
      expect.objectContaining({ method: "GET" })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      3,
      "/api/v1/products/stacio/appcast-entries?channel=dev&page_size=100",
      expect.objectContaining({ method: "GET" })
    );
  });

  it("revokes the refresh token on logout and clears the local session", async () => {
    setAuthToken("access-token");
    setRefreshToken("rt_refresh_token");
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    );

    await opsClient.logout();

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/auth/logout",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ refreshToken: "rt_refresh_token" })
      })
    );
    expect(window.localStorage.getItem("stacio.ops.authToken")).toBeNull();
    expect(getRefreshToken()).toBeNull();
  });

  it("clears the local session when logout revocation fails", async () => {
    setAuthToken("access-token");
    setRefreshToken("rt_refresh_token");
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("network down"));

    await opsClient.logout();

    expect(window.localStorage.getItem("stacio.ops.authToken")).toBeNull();
    expect(getRefreshToken()).toBeNull();
  });

  it("enqueues GitHub issue pulls instead of running them synchronously", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ ok: true, data: { id: "job_github_1" } }), {
        status: 202,
        headers: { "Content-Type": "application/json" }
      })
    );

    await expect(opsClient.pullGitHubIssues()).resolves.toEqual({ id: "job_github_1" });

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/github/pull/enqueue",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({})
      })
    );
  });

  it("posts GitHub issue comments with manual confirmation", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          data: {
            commentId: "777",
            url: "https://github.com/example/stacio/issues/42#issuecomment-777",
            body: "Thanks, we have reproduced this issue."
          }
        }),
        {
          status: 201,
          headers: { "Content-Type": "application/json" }
        }
      )
    );

    await expect(
      opsClient.commentGitHubIssue("stacio", "ghi_1", {
        body: "Thanks, we have reproduced this issue.",
        confirmation: "POST"
      })
    ).resolves.toEqual({
      commentId: "777",
      url: "https://github.com/example/stacio/issues/42#issuecomment-777",
      body: "Thanks, we have reproduced this issue."
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/github/issues/ghi_1/comments",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          body: "Thanks, we have reproduced this issue.",
          confirmation: "POST"
        })
      })
    );
  });

  it("maps GitHub sync run errors for admin status views", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          data: [
            {
              id: "ghsync_failed_1",
              trigger: "manual",
              status: "failed",
              fetchedCount: 0,
              changedCount: 0,
              feedbackCreatedCount: 0,
              error: "GitHub API returned 403",
              finishedAt: "2026-07-10T00:30:00.000Z"
            }
          ]
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" }
        }
      )
    );

    await expect(opsClient.githubSyncRuns("stacio")).resolves.toEqual([
      {
        id: "ghsync_failed_1",
        trigger: "Manual",
        status: "Failed",
        fetched: 0,
        changed: 0,
        feedbackCreated: 0,
        error: "GitHub API returned 403",
        finishedAt: "2026/07/10"
      }
    ]);

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/github/sync-runs?page_size=100",
      expect.any(Object)
    );
  });

  it("patches editable release draft fields without publishing", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          data: {
            id: "rel_1",
            productId: "stacio",
            version: "0.14.2-Beta",
            buildNumber: "22",
            channel: "beta",
            status: "draft",
            artifactName: "Stacio-0.14.2-Beta.dmg",
            artifactUrl: "https://objects.example.com/Stacio-0.14.2-Beta.dmg",
            artifactSize: 22334455,
            sparkleEdDsaSignature: "new-signature",
            releaseNotes: "Edited release notes.",
            aiReleaseSummary: "Agent summary.",
            aiRiskSummary: "Risk summary.",
            createdAt: "2026-07-10T00:00:00.000Z"
          }
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" }
        }
      )
    );

    await expect(
      opsClient.updateReleaseDraft("stacio", "rel_1", {
        artifactUrl: "https://objects.example.com/Stacio-0.14.2-Beta.dmg",
        artifactSize: 22334455,
        sparkleEdDsaSignature: "new-signature",
        releaseNotes: "Edited release notes.",
        aiReleaseSummary: "Agent summary.",
        aiRiskSummary: "Risk summary."
      })
    ).resolves.toEqual(expect.objectContaining({ status: "draft" }));

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/releases/rel_1/draft",
      expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({
          artifactUrl: "https://objects.example.com/Stacio-0.14.2-Beta.dmg",
          artifactSize: 22334455,
          sparkleEdDsaSignature: "new-signature",
          releaseNotes: "Edited release notes.",
          aiReleaseSummary: "Agent summary.",
          aiRiskSummary: "Risk summary."
        })
      })
    );
  });

  it("maps release preflight check counts from backend evidence", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          data: [
            {
              id: "rel_1",
              productId: "stacio",
              version: "0.14.0-Beta",
              buildNumber: "20",
              channel: "beta",
              status: "ready",
              artifactName: "Stacio-0.14.0-Beta.dmg",
              preflightEvidence: {
                checks: [
                  { key: "artifact_url", passed: true, message: "ok" },
                  { key: "artifact_size", passed: true, message: "ok" },
                  { key: "signature", passed: true, message: "ok" },
                  { key: "release_notes", passed: true, message: "ok" },
                  { key: "build_number", passed: true, message: "ok" },
                  { key: "build_number_gt_previous", passed: true, message: "ok" },
                  { key: "version_format", passed: true, message: "ok" },
                  { key: "minimum_system_version", passed: true, message: "ok" },
                  { key: "appcast_xml", passed: true, message: "ok" }
                ]
              },
              createdAt: "2026-07-10T00:00:00.000Z"
            }
          ]
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" }
        }
      )
    );

    await expect(opsClient.releases("stacio")).resolves.toEqual([
      expect.objectContaining({
        id: "rel_1",
        checks: "9/9"
      })
    ]);
  });

  it("manages admin users through owner-scoped APIs", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: [
              {
                id: "role_operator",
                name: "operator",
                description: "Triage feedback",
                permissions: ["feedback:read"]
              }
            ]
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        )
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: [
              {
                id: "usr_operator",
                email: "operator@example.com",
                name: "Support Operator",
                status: "active",
                roles: ["operator"],
                permissions: ["feedback:read"],
                productIds: ["stacio"],
                createdAt: "2026-07-10T00:00:00.000Z"
              }
            ]
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        )
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: {
              id: "usr_operator",
              email: "operator@example.com",
              name: "Support Operator",
              status: "active",
              roles: ["operator"],
              permissions: ["feedback:read"],
              productIds: ["stacio"]
            }
          }),
          {
            status: 201,
            headers: { "Content-Type": "application/json" }
          }
        )
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: {
              id: "usr_operator",
              email: "operator@example.com",
              name: "Support Operator",
              status: "disabled",
              roles: ["operator"],
              permissions: ["feedback:read"],
              productIds: ["stacio"]
            }
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        )
      )
      ;

    await expect(opsClient.adminRoles()).resolves.toEqual([
      {
        id: "role_operator",
        name: "operator",
        description: "Triage feedback",
        permissions: ["feedback:read"]
      }
    ]);
    await expect(opsClient.adminUsers()).resolves.toEqual([
      expect.objectContaining({
        id: "usr_operator",
        role: "operator",
        productScope: "stacio",
        createdAt: "2026/07/10"
      })
    ]);
    await opsClient.createAdminUser({
      email: "operator@example.com",
      name: "Support Operator",
      password: "operator-password",
      role: "operator",
      productIds: ["stacio"]
    });
    await opsClient.updateAdminUser("usr_operator", {
      status: "disabled",
      confirmation: "DISABLE"
    });

    expect(fetchMock).toHaveBeenNthCalledWith(
      3,
      "/api/v1/admin/users",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          email: "operator@example.com",
          name: "Support Operator",
          password: "operator-password",
          role: "operator",
          productIds: ["stacio"]
        })
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      4,
      "/api/v1/admin/users/usr_operator",
      expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({
          status: "disabled",
          confirmation: "DISABLE"
        })
      })
    );
  });

  it("manages Agent API keys through owner-scoped APIs without expecting stored secrets", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: [
              {
                id: "agent_key_existing",
                name: "Existing Codex key",
                keyPrefix: "agent_abcd1234",
                productIds: ["stacio"],
                scopes: ["feedback:read"],
                status: "active",
                createdAt: "2026-07-10T00:00:00.000Z"
              }
            ]
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        )
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: {
              id: "agent_key_new",
              name: "Codex feedback triage",
              key: "agent_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              keyPrefix: "agent_aaaaaaaaaaaaa",
              productIds: ["stacio"],
              scopes: ["feedback:read", "actions:propose"],
              status: "active",
              createdAt: "2026-07-10T01:00:00.000Z"
            }
          }),
          {
            status: 201,
            headers: { "Content-Type": "application/json" }
          }
        )
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: {
              id: "agent_key_new",
              name: "Codex feedback triage",
              keyPrefix: "agent_aaaaaaaaaaaaa",
              productIds: ["stacio"],
              scopes: ["feedback:read", "actions:propose"],
              status: "disabled",
              createdAt: "2026-07-10T01:00:00.000Z"
            }
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        )
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: {
              id: "agent_key_new",
              name: "Codex feedback triage",
              key: "agent_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              keyPrefix: "agent_bbbbbbbbbbbbb",
              productIds: ["stacio"],
              scopes: ["feedback:read", "actions:propose"],
              status: "active",
              createdAt: "2026-07-10T01:00:00.000Z"
            }
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        )
      );

    await expect(opsClient.agentApiKeys()).resolves.toEqual([
      expect.objectContaining({
        id: "agent_key_existing",
        name: "Existing Codex key",
        productScope: "stacio",
        status: "Active"
      })
    ]);
    await expect(
      opsClient.createAgentApiKey({
        name: "Codex feedback triage",
        productIds: ["stacio"],
        scopes: ["feedback:read", "actions:propose"]
      })
    ).resolves.toEqual(
      expect.objectContaining({
        id: "agent_key_new",
        oneTimeKey: "agent_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        scopes: ["feedback:read", "actions:propose"]
      })
    );
    await expect(
      opsClient.updateAgentApiKey("agent_key_new", {
        status: "disabled",
        confirmation: "DISABLE"
      })
    ).resolves.toEqual(
      expect.objectContaining({
        id: "agent_key_new",
        status: "Disabled"
      })
    );
    await expect(
      opsClient.rotateAgentApiKey("agent_key_new", {
        confirmation: "ROTATE"
      })
    ).resolves.toEqual(
      expect.objectContaining({
        id: "agent_key_new",
        oneTimeKey: "agent_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        keyPrefix: "agent_bbbbbbbbbbbbb"
      })
    );

    expect(fetchMock).toHaveBeenNthCalledWith(1, "/api/v1/admin/agent-api-keys?page_size=100", expect.objectContaining({
      method: "GET"
    }));
    expect(fetchMock).toHaveBeenNthCalledWith(2, "/api/v1/admin/agent-api-keys", expect.objectContaining({
      method: "POST",
      body: JSON.stringify({
        name: "Codex feedback triage",
        productIds: ["stacio"],
        scopes: ["feedback:read", "actions:propose"]
      })
    }));
    expect(fetchMock).toHaveBeenNthCalledWith(3, "/api/v1/admin/agent-api-keys/agent_key_new", expect.objectContaining({
      method: "PATCH",
      body: JSON.stringify({
        status: "disabled",
        confirmation: "DISABLE"
      })
    }));
    expect(fetchMock).toHaveBeenNthCalledWith(4, "/api/v1/admin/agent-api-keys/agent_key_new/rotate", expect.objectContaining({
      method: "POST",
      body: JSON.stringify({
        confirmation: "ROTATE"
      })
    }));
  });

  it("enqueues notification sends with dry-run mode by default", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ ok: true, data: { id: "job_notification_1" } }), {
        status: 202,
        headers: { "Content-Type": "application/json" }
      })
    );

    await expect(opsClient.sendNotification("ntf_1")).resolves.toEqual({ id: "job_notification_1" });

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/notifications/ntf_1/send",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ mode: "queue", dryRun: true })
      })
    );
  });

  it("includes the manual SEND confirmation for real notification delivery", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ ok: true, data: { id: "job_notification_2" } }), {
        status: 202,
        headers: { "Content-Type": "application/json" }
      })
    );

    await opsClient.sendNotification("ntf_2", false, "queue", "second-product");

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/second-product/notifications/ntf_2/send",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          mode: "queue",
          dryRun: false,
          confirmation: "SEND"
        })
      })
    );
  });

  it("creates customer license expiring reminder notifications through the admin API", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          data: {
            scannedCount: 2,
            createdCount: 1,
            skippedCount: 1,
            window: {
              referenceDate: "2026-07-10T00:00:00.000Z",
              days: 30,
              cutoffDate: "2026-08-09T00:00:00.000Z"
            },
            created: [
              {
                id: "notification_expiring",
                type: "customer_license_expiring",
                recipient: "pro@example.com",
                payload: {
                  licenseId: "lic_002",
                  expiresAt: "2026-08-09T00:00:00.000Z"
                },
                priority: "normal",
                status: "queued",
                createdAt: "2026-07-10T00:00:00.000Z"
              }
            ],
            skipped: [
              {
                licenseId: "lic_003",
                recipient: "team@example.com",
                reason: "already_queued"
              }
            ]
          }
        }),
        {
          status: 201,
          headers: { "Content-Type": "application/json" }
        }
      )
    );

    await expect(
      opsClient.createLicenseExpiringReminders("stacio", {
        days: 30,
        referenceDate: "2026-07-10T00:00:00.000Z"
      })
    ).resolves.toEqual(
      expect.objectContaining({
        createdCount: 1,
        skippedCount: 1,
        created: [
          expect.objectContaining({
            id: "notification_expiring",
            type: "Customer License Expiring",
            recipient: "pro@example.com",
            status: "Queued"
          })
        ],
        skipped: [
          expect.objectContaining({
            licenseId: "lic_003",
            reason: "already_queued"
          })
        ]
      })
    );

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/notifications/license-expiring",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          days: 30,
          referenceDate: "2026-07-10T00:00:00.000Z"
        })
      })
    );
  });

  it("loads notification delivery history through the product-scoped admin API", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          data: [
            {
              id: "delivery_1",
              notificationId: "ntf_2",
              provider: "smtp",
              attempt: 1,
              status: "sent",
              providerMessageId: "smtp-1",
              sentAt: "2026-07-10T00:00:00.000Z",
              createdAt: "2026-07-10T00:00:00.000Z"
            }
          ]
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" }
        }
      )
    );

    await expect(opsClient.notificationDeliveries("stacio", "ntf_2")).resolves.toEqual([
      {
        id: "delivery_1",
        notificationId: "ntf_2",
        provider: "smtp",
        attempt: 1,
        status: "Sent",
        providerMessageId: "smtp-1",
        error: undefined,
        sentAt: "2026/07/10",
        createdAt: "2026/07/10"
      }
    ]);

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/notifications/ntf_2/deliveries?page_size=100",
      expect.objectContaining({
        method: "GET"
      })
    );
  });

  it("scopes object storage presign dry-runs to the selected product", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          data: {
            objectKey: "products/second-product/releases/rel_smoke/Stacio-Smoke.dmg",
            uploadUrl: "https://storage.example.test/upload"
          }
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" }
        }
      )
    );

    await opsClient.presignUploadDryRun("second-product");

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/second-product/storage/presign-upload",
      expect.objectContaining({
        method: "POST"
      })
    );
  });

  it("maps AI analysis input references and output body previews for review", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          data: [
            {
              id: "ai_1",
              targetType: "feedback",
              targetId: "fb_001",
              agentIdentity: "codex",
              model: "gpt-test",
              analysisType: "triage",
              inputReferences: {
                feedbackId: "fb_001",
                githubIssue: "#44"
              },
              outputBody: {
                summary: "保存失败应优先处理。",
                classification: "bug"
              },
              confidence: "0.91",
              adoptionState: "pending",
              createdAt: "2026-07-10T01:00:00.000Z"
            }
          ]
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" }
        }
      )
    );

    await expect(opsClient.aiAnalysis()).resolves.toEqual([
      expect.objectContaining({
        id: "ai_1",
        target: "feedback / fb_001",
        analysisType: "Triage",
        summary: "保存失败应优先处理。",
        classification: "bug",
        inputReferencesPreview: "feedbackId: fb_001, githubIssue: #44",
        outputBodyPreview: "summary: 保存失败应优先处理。, classification: bug"
      })
    ]);
  });

  it("reviews AI analysis through the admin confirmation endpoint", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ ok: true, data: { id: "ai_1", adoptionState: "accepted" } }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    );

    await expect(opsClient.reviewAiAnalysis("ai_1", "accepted")).resolves.toEqual({
      id: "ai_1",
      adoptionState: "accepted"
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/ai-analysis/ai_1",
      expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ adoptionState: "accepted" })
      })
    );
  });

  it("lists and reviews AI proposed actions through the admin API", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: [
              {
                id: "act_1",
                actionType: "feedback.update_status",
                payload: { status: "in_progress" },
                status: "pending",
                targetType: "feedback",
                targetId: "fb_001",
                createdAt: "2026-07-10T01:00:00.000Z",
                analysis: {
                  agentIdentity: "codex-action-agent",
                  model: "gpt-test",
                  outputBody: {
                    rationale: "保存失败影响核心链路。"
                  }
                }
              }
            ]
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        )
      )
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ ok: true, data: { id: "act_1", status: "accepted" } }), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: {
              action: { id: "act_1", status: "executed" },
              result: {
                targetType: "feedback",
                targetId: "fb_001",
                changes: { status: "in_progress" }
              }
            },
            policy: {
              actionExecuted: true,
              customerVisibleEmailSent: false,
              publicGitHubReplySent: false,
              otaPublished: false,
              licenseChanged: false,
              feedbackDeleted: false
            }
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        )
      );

    await expect(opsClient.proposedActions()).resolves.toEqual([
      expect.objectContaining({
        id: "act_1",
        actionType: "feedback.update_status",
        status: "Pending",
        target: "feedback / fb_001",
        rationale: "保存失败影响核心链路。"
      })
    ]);
    await expect(opsClient.reviewProposedAction("act_1", "accepted")).resolves.toEqual({
      id: "act_1",
      status: "accepted"
    });
    await expect(opsClient.executeProposedAction("act_1")).resolves.toEqual(
      expect.objectContaining({
        action: expect.objectContaining({
          id: "act_1",
          status: "executed"
        }),
        result: expect.objectContaining({
          targetType: "feedback",
          targetId: "fb_001",
          changes: {
            status: "in_progress"
          }
        })
      })
    );

    expect(fetchMock).toHaveBeenNthCalledWith(1, "/api/v1/products/stacio/proposed-actions?page_size=100", expect.objectContaining({
      method: "GET"
    }));
    expect(fetchMock).toHaveBeenNthCalledWith(2, "/api/v1/products/stacio/proposed-actions/act_1", expect.objectContaining({
      method: "PATCH",
      body: JSON.stringify({ status: "accepted" })
    }));
    expect(fetchMock).toHaveBeenNthCalledWith(3, "/api/v1/products/stacio/proposed-actions/act_1/execute", expect.objectContaining({
      method: "POST",
      body: JSON.stringify({ confirmation: "EXECUTE" })
    }));
  });

  it("updates license lifecycle state through admin APIs", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ ok: true, data: { id: "lic_1", status: "suspended" } }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    );

    await expect(opsClient.updateLicense("lic_1", { status: "suspended", confirmation: "SUSPEND" })).resolves.toEqual({
      id: "lic_1",
      status: "suspended"
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/licenses/lic_1",
      expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ status: "suspended", confirmation: "SUSPEND" })
      })
    );
  });

  it("resets license activations through the admin API", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ ok: true, data: { id: "lic_1", devices: 0 } }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    );

    await expect(opsClient.resetLicenseActivations("lic_1", "RESET")).resolves.toEqual({
      id: "lic_1",
      devices: 0
    });

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/licenses/lic_1/reset-activations",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ confirmation: "RESET" })
      })
    );
  });

  it("queues license issued email through the product-scoped admin API", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          data: {
            notification: {
              id: "ntf_license_1",
              productId: "stacio",
              type: "customer_license_issued",
              recipient: "paid@example.com",
              priority: "normal",
              status: "queued",
              payload: {
                licenseId: "lic_1",
                licenseKey: "STACIO-ONE-TIME"
              },
              createdAt: "2026-07-10T00:00:00.000Z"
            },
            job: {
              id: "job_notification_1",
              name: "notification.send",
              payload: {
                productId: "stacio",
                notificationId: "ntf_license_1"
              }
            }
          }
        }),
        {
          status: 202,
          headers: { "Content-Type": "application/json" }
        }
      )
    );

    await expect(
      opsClient.sendLicenseEmail("lic_1", {
        licenseKey: "STACIO-ONE-TIME",
        confirmation: "SEND"
      })
    ).resolves.toEqual(
      expect.objectContaining({
        notification: expect.objectContaining({
          id: "ntf_license_1",
          type: "Customer License Issued",
          recipient: "paid@example.com"
        }),
        job: expect.objectContaining({
          id: "job_notification_1",
          name: "notification.send"
        })
      })
    );

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/licenses/lic_1/email",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          licenseKey: "STACIO-ONE-TIME",
          confirmation: "SEND"
        })
      })
    );
  });

  it("queues batch license issued emails through the product-scoped admin API", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          data: {
            requestedCount: 2,
            queuedCount: 1,
            skippedCount: 1,
            queued: [
              {
                licenseId: "lic_batch_1",
                recipient: "team@example.com",
                notification: {
                  id: "ntf_batch_1",
                  productId: "stacio",
                  type: "customer_license_issued",
                  recipient: "team@example.com",
                  priority: "normal",
                  status: "queued",
                  payload: {
                    licenseId: "lic_batch_1",
                    licenseKey: "STACIO-BATCH-ONE"
                  },
                  createdAt: "2026-07-10T00:00:00.000Z"
                },
                job: {
                  id: "job_batch_1",
                  name: "notification.send"
                }
              }
            ],
            skipped: [
              {
                licenseId: "lic_batch_2",
                recipient: "two@example.com",
                reason: "license_key_mismatch"
              }
            ]
          }
        }),
        {
          status: 202,
          headers: { "Content-Type": "application/json" }
        }
      )
    );

    await expect(
      opsClient.batchSendLicenseEmails(
        "stacio",
        [
          {
            licenseId: "lic_batch_1",
            licenseKey: "STACIO-BATCH-ONE"
          },
          {
            licenseId: "lic_batch_2",
            licenseKey: "STACIO-BATCH-TWO"
          }
        ],
        "SEND"
      )
    ).resolves.toEqual(
      expect.objectContaining({
        requestedCount: 2,
        queuedCount: 1,
        skippedCount: 1,
        queued: [
          expect.objectContaining({
            licenseId: "lic_batch_1",
            recipient: "team@example.com",
            notification: expect.objectContaining({
              id: "ntf_batch_1",
              type: "Customer License Issued"
            })
          })
        ],
        skipped: [
          expect.objectContaining({
            licenseId: "lic_batch_2",
            reason: "license_key_mismatch"
          })
        ]
      })
    );

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/licenses/batch-email",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          confirmation: "SEND",
          items: [
            {
              licenseId: "lic_batch_1",
              licenseKey: "STACIO-BATCH-ONE"
            },
            {
              licenseId: "lic_batch_2",
              licenseKey: "STACIO-BATCH-TWO"
            }
          ]
        })
      })
    );
  });

  it("loads license detail with activation and validation history", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          data: {
            license: {
              id: "lic_1",
              productId: "stacio",
              customerName: "Ada",
              customerEmail: "ada@example.com",
              plan: "pro",
              status: "active",
              seats: 1,
              devices: 1,
              expiresAt: "2027-07-10T00:00:00.000Z",
              createdAt: "2026-07-10T00:00:00.000Z"
            },
            customer: {
              id: "cust_1",
              productId: "stacio",
              name: "Ada",
              email: "ada@example.com",
              status: "active",
              riskFlag: false,
              createdAt: "2026-07-10T00:00:00.000Z",
              updatedAt: "2026-07-10T00:00:00.000Z"
            },
            activations: [
              {
                id: "act_1",
                licenseId: "lic_1",
                anonymousDeviceId: "device_paid",
                firstSeenAt: "2026-07-10T00:00:00.000Z",
                lastSeenAt: "2026-07-10T01:00:00.000Z",
                riskSignals: {},
                createdAt: "2026-07-10T00:00:00.000Z",
                updatedAt: "2026-07-10T01:00:00.000Z"
              }
            ],
            validationLogs: [
              {
                id: "log_1",
                licenseId: "lic_1",
                productId: "stacio",
                result: "valid",
                appVersion: "0.13.2-Beta",
                buildNumber: "12",
                createdAt: "2026-07-10T01:00:00.000Z"
              }
            ],
            auditLogs: [
              {
                id: "audit_1",
                action: "license.created",
                targetType: "license",
                targetId: "lic_1",
                createdAt: "2026-07-10T00:00:00.000Z"
              }
            ]
          }
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" }
        }
      )
    );

    await expect(opsClient.licenseDetail("lic_1")).resolves.toEqual(
      expect.objectContaining({
        customer: expect.objectContaining({ email: "ada@example.com" }),
        activations: expect.arrayContaining([
          expect.objectContaining({ anonymousDeviceId: "device_paid" })
        ]),
        validationLogs: expect.arrayContaining([
          expect.objectContaining({ result: "valid", appVersion: "0.13.2-Beta" })
        ])
      })
    );

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/licenses/lic_1",
      expect.objectContaining({
        method: "GET"
      })
    );
  });

  it("batch creates licenses through the product-scoped admin API", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          data: {
            items: [
              {
                license: {
                  id: "lic_batch_1",
                  productId: "stacio",
                  customerName: "Team User",
                  customerEmail: "team@example.com",
                  plan: "team",
                  status: "active",
                  seats: 1,
                  devices: 0,
                  expiresAt: "2027-07-10T00:00:00.000Z",
                  createdAt: "2026-07-10T00:00:00.000Z"
                },
                licenseKey: "STACIO-BATCH-KEY",
                revealPolicy: "one_time"
              }
            ]
          }
        }),
        {
          status: 201,
          headers: { "Content-Type": "application/json" }
        }
      )
    );

    await expect(
      opsClient.batchCreateLicenses("stacio", {
        recipients: [
          {
            customerName: "Team User",
            customerEmail: "team@example.com",
            username: "team"
          }
        ],
        plan: "team",
        seats: 1,
        maxDevices: 3,
        offlineGraceDays: 30,
        expiresAt: "2027-07-10T00:00:00.000Z",
        entitlements: ["team_features"]
      })
    ).resolves.toEqual([
      expect.objectContaining({
        licenseKey: "STACIO-BATCH-KEY",
        revealPolicy: "one_time",
        license: expect.objectContaining({
          customerEmail: "team@example.com"
        })
      })
    ]);

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/licenses/batch",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          recipients: [
            {
              customerName: "Team User",
              customerEmail: "team@example.com",
              username: "team"
            }
          ],
          plan: "team",
          seats: 1,
          maxDevices: 3,
          offlineGraceDays: 30,
          expiresAt: "2027-07-10T00:00:00.000Z",
          entitlements: ["team_features"]
        })
      })
    );
  });

  it("supports the complete feedback workspace API surface", async () => {
    vi.stubEnv("VITE_STRICT_API", "true");
    const feedback = {
      id: "fb_1",
      productId: "stacio",
      title: "Login crash",
      description: "The app crashes after login.",
      type: "bug",
      status: "new",
      priority: "P1",
      source: "app",
      createdAt: "2026-07-10T00:00:00.000Z",
      updatedAt: "2026-07-10T00:00:00.000Z"
    };
    const issue = {
      id: "ghi_1",
      productId: "stacio",
      githubIssueId: "1001",
      number: 101,
      title: "Login crash",
      labels: ["bug"],
      state: "open",
      commentsCount: 0,
      url: "https://github.com/example/stacio/issues/101",
      syncedAt: "2026-07-10T00:00:00.000Z",
      createdAt: "2026-07-10T00:00:00.000Z",
      updatedAt: "2026-07-10T00:00:00.000Z"
    };
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true, data: [feedback] }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        ok: true,
        data: { ...feedback, comments: [], attachments: [], linkedGitHubIssues: [] }
      }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true, data: { ...feedback, status: "in_progress" } }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true, data: { id: "comment_1" } }), {
        status: 201,
        headers: { "Content-Type": "application/json" }
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true, data: { comment: { id: "comment_2" } } }), {
        status: 202,
        headers: { "Content-Type": "application/json" }
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true, data: issue }), {
        status: 201,
        headers: { "Content-Type": "application/json" }
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true, data: issue }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true, data: feedback }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true, data: { ...feedback, deletedAt: "2026-07-10T01:00:00.000Z" } }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      }));

    await opsClient.feedback("stacio", { search: "crash", priority: "P1" });
    await opsClient.feedbackDetail("stacio", "fb_1");
    await opsClient.updateFeedback("stacio", "fb_1", { status: "in_progress" });
    await opsClient.addFeedbackComment("stacio", "fb_1", {
      visibility: "internal",
      body: "Investigating."
    });
    await opsClient.sendFeedbackReply("stacio", "fb_1", "Please retry the new build.");
    await opsClient.linkFeedbackGitHubIssue("stacio", "fb_1", "ghi_1");
    await opsClient.unlinkFeedbackGitHubIssue("stacio", "fb_1", "ghi_1");
    await opsClient.redactFeedback("stacio", "fb_1", ["description"]);
    await opsClient.deleteFeedback("stacio", "fb_1");

    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "/api/v1/products/stacio/feedback?search=crash&priority=P1&page_size=100",
      expect.objectContaining({ method: "GET" })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      3,
      "/api/v1/products/stacio/feedback/fb_1",
      expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ status: "in_progress" })
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      4,
      "/api/v1/products/stacio/feedback/fb_1/comments",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ visibility: "internal", body: "Investigating." })
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      5,
      "/api/v1/products/stacio/feedback/fb_1/replies/send",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          confirmation: "SEND",
          body: "Please retry the new build.",
          mode: "queue"
        })
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      6,
      "/api/v1/products/stacio/feedback/fb_1/github-links",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ githubIssueId: "ghi_1" })
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      7,
      "/api/v1/products/stacio/feedback/fb_1/github-links/ghi_1",
      expect.objectContaining({
        method: "DELETE",
        body: JSON.stringify({ confirmation: "UNLINK" })
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      8,
      "/api/v1/products/stacio/feedback/fb_1/redact",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ confirmation: "REDACT", fields: ["description"] })
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      9,
      "/api/v1/products/stacio/feedback/fb_1",
      expect.objectContaining({
        method: "DELETE",
        body: JSON.stringify({ confirmation: "DELETE" })
      })
    );
  });

  it("publishes releases with explicit manual confirmation", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ ok: true, data: { id: "rel_1", status: "published" } }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    );

    await expect(opsClient.publishRelease("rel_1")).resolves.toEqual({ id: "rel_1", status: "published" });

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/releases/rel_1/publish",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ confirmation: "PUBLISH" })
      })
    );
  });

  it("lists persisted appcast snapshots for a release channel", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          data: [
            {
              id: "appcast_1",
              productId: "stacio",
              channelId: "channel_stacio_beta",
              channelName: "beta",
              releaseId: "rel_1",
              xml: "<rss>Stacio 0.14.0-Beta</rss>",
              objectKey: "products/stacio/releases/beta/appcast.xml",
              publishedAt: "2026-07-10T10:00:00.000Z",
              createdAt: "2026-07-10T10:00:00.000Z"
            }
          ]
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" }
        }
      )
    );

    await expect(opsClient.appcastEntries("stacio", "beta")).resolves.toEqual([
      expect.objectContaining({
        channelName: "beta",
        releaseId: "rel_1",
        objectKey: "products/stacio/releases/beta/appcast.xml"
      })
    ]);

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/appcast-entries?channel=beta&page_size=100",
      expect.objectContaining({
        method: "GET"
      })
    );
  });

  it("lists release artifact registration history", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          data: [
            {
              id: "artifact_1",
              productId: "stacio",
              releaseId: "rel_1",
              objectKey: "products/stacio/releases/beta/0.14.7-Beta/Stacio-0.14.7-Beta.dmg",
              url: "https://objects.example.com/Stacio-0.14.7-Beta.dmg",
              fileName: "Stacio-0.14.7-Beta.dmg",
              contentType: "application/x-apple-diskimage",
              sizeBytes: 4096,
              sha256: "a".repeat(64),
              signatureEvidence: {},
              createdAt: "2026-07-11T10:00:00.000Z"
            }
          ]
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" }
        }
      )
    );

    await expect(opsClient.releaseArtifacts("stacio", "rel_1")).resolves.toEqual([
      expect.objectContaining({
        releaseId: "rel_1",
        objectKey: "products/stacio/releases/beta/0.14.7-Beta/Stacio-0.14.7-Beta.dmg",
        fileName: "Stacio-0.14.7-Beta.dmg",
        sizeBytes: 4096
      })
    ]);

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/releases/rel_1/artifacts?page_size=100",
      expect.objectContaining({
        method: "GET"
      })
    );
  });

  it("checks release artifact download reachability through the admin API", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          data: {
            release: {
              id: "rel_1",
              productId: "stacio",
              version: "0.14.6-Internal",
              buildNumber: "26",
              channel: "internal",
              status: "draft",
              artifactName: "Stacio-0.14.6-Internal.dmg",
              createdAt: "2026-07-10T00:00:00.000Z"
            },
            downloadReachabilityEvidence: {
              status: "reachable",
              statusCode: 200,
              contentLength: 2048,
              summary: "Download URL responded to HEAD"
            }
          }
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" }
        }
      )
    );

    await expect(opsClient.checkReleaseDownload("stacio", "rel_1")).resolves.toEqual(
      expect.objectContaining({
        downloadReachabilityEvidence: expect.objectContaining({
          status: "reachable",
          statusCode: 200,
          contentLength: 2048
        })
      })
    );

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/releases/rel_1/check-download",
      expect.objectContaining({
        method: "POST"
      })
    );
  });

  it("updates release lifecycle with the required confirmation token", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ ok: true, data: { id: "rel_1", status: "paused" } }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    );

    await expect(opsClient.updateReleaseLifecycle("rel_1", "pause")).resolves.toEqual({ id: "rel_1", status: "paused" });

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/products/stacio/releases/rel_1/lifecycle",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ action: "pause", confirmation: "PAUSE" })
      })
    );
  });

  it("lists and creates release Agent requests through release-scoped endpoints", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: [
              {
                id: "agent_req_release_1",
                productId: "stacio",
                targetType: "release",
                targetId: "rel_1",
                requestType: "release_notes",
                agentHint: "codex",
                prompt: "Draft release notes",
                status: "queued",
                metadata: {},
                createdAt: "2026-07-10T01:00:00.000Z",
                updatedAt: "2026-07-10T01:00:00.000Z"
              }
            ]
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        )
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: {
              id: "agent_req_release_2",
              productId: "stacio",
              targetType: "release",
              targetId: "rel_1",
              requestType: "release_risk",
              agentHint: "claude",
              prompt: "Draft release risk",
              status: "queued",
              metadata: {},
              createdAt: "2026-07-10T02:00:00.000Z",
              updatedAt: "2026-07-10T02:00:00.000Z"
            }
          }),
          {
            status: 201,
            headers: { "Content-Type": "application/json" }
          }
        )
      );

    await expect(opsClient.releaseAgentRequests("stacio", "rel_1")).resolves.toEqual([
      expect.objectContaining({
        id: "agent_req_release_1",
        targetType: "release",
        targetId: "rel_1",
        requestType: "release_notes",
        status: "Queued"
      })
    ]);
    await expect(
      opsClient.createReleaseAgentRequest("stacio", "rel_1", {
        requestType: "release_risk",
        agentHint: "claude",
        prompt: "Draft release risk"
      })
    ).resolves.toEqual(
      expect.objectContaining({
        id: "agent_req_release_2",
        requestType: "release_risk",
        status: "Queued"
      })
    );

    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "/api/v1/products/stacio/releases/rel_1/agent-requests?page_size=100",
      expect.objectContaining({
        method: "GET"
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "/api/v1/products/stacio/releases/rel_1/agent-requests",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          requestType: "release_risk",
          agentHint: "claude",
          prompt: "Draft release risk"
        })
      })
    );
  });

  it("creates and updates reusable product configurations", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: {
              product: {
                id: "portdesk",
                name: "PortDesk",
                platform: "macOS",
                bundleId: "com.zerxlab.portdesk",
                supportEmail: "support@example.com",
                currentStableVersion: "",
                currentBetaVersion: "",
                licensePolicy: {},
                emailBrand: {},
                status: "active"
              },
              feedbackApiKey: "pfk_created"
            }
          }),
          {
            status: 201,
            headers: { "Content-Type": "application/json" }
          }
        )
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: {
              id: "portdesk",
              name: "PortDesk",
              platform: "macOS",
              bundleId: "com.zerxlab.portdesk",
              supportEmail: "help@example.com",
              currentStableVersion: "",
              currentBetaVersion: "",
              licensePolicy: {},
              emailBrand: {},
              status: "active"
            }
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        )
      );

    const input = {
      id: "portdesk",
      name: "PortDesk",
      platform: "macOS",
      bundleId: "com.zerxlab.portdesk",
      supportEmail: "support@example.com"
    };

    await expect(opsClient.createProduct(input)).resolves.toEqual(
      expect.objectContaining({
        feedbackApiKey: "pfk_created",
        product: expect.objectContaining({ id: "portdesk" })
      })
    );
    await expect(opsClient.updateProduct("portdesk", { supportEmail: "help@example.com" })).resolves.toEqual(
      expect.objectContaining({
        id: "portdesk",
        supportEmail: "help@example.com"
      })
    );

    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "/api/v1/products",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify(input)
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "/api/v1/products/portdesk",
      expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ supportEmail: "help@example.com" })
      })
    );
  });

  it("archives products and rotates feedback keys with typed confirmations", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ ok: true, data: { id: "stacio", status: "archived" } }), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
      )
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ ok: true, data: { feedbackApiKey: "pfk_rotated" } }), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
      );

    await expect(opsClient.archiveProduct("stacio")).resolves.toEqual({ id: "stacio", status: "archived" });
    await expect(opsClient.rotateFeedbackApiKey("stacio")).resolves.toEqual({ feedbackApiKey: "pfk_rotated" });

    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "/api/v1/products/stacio/archive",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ confirmation: "ARCHIVE" })
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "/api/v1/products/stacio/feedback-api-key/rotate",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ confirmation: "ROTATE" })
      })
    );
  });

  it("does not silently fall back to mock data when strict API mode is enabled", async () => {
    vi.stubEnv("VITE_STRICT_API", "true");
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ ok: false, error: { message: "Backend unavailable" } }), {
        status: 503,
        headers: { "Content-Type": "application/json" }
      })
    );

    await expect(opsClient.settingsSummary()).rejects.toThrow("Backend unavailable");
  });

  it("uses mock fallback only when demo mode is explicit or test fallback is enabled", async () => {
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("Network down"));

    await expect(opsClient.settingsSummary()).resolves.toEqual(
      expect.objectContaining({
        productId: "stacio"
      })
    );
  });

  it("keeps real empty API lists empty in strict API mode", async () => {
    vi.stubEnv("VITE_STRICT_API", "true");
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ ok: true, data: [] }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    );

    await expect(opsClient.licenses()).resolves.toEqual([]);
  });

  it("creates, updates, and archives plans through product-scoped APIs", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: {
              id: "plan_enterprise",
              productId: "stacio",
              name: "Enterprise",
              maxDevices: 100,
              maxSeats: 50,
              trialDays: 30,
              offlineGraceDays: 60,
              allowedChannels: ["stable", "beta"],
              entitlements: ["pro_features"],
              status: "active",
              createdAt: "2026-07-10T00:00:00.000Z",
              updatedAt: "2026-07-10T00:00:00.000Z"
            }
          }),
          {
            status: 201,
            headers: { "Content-Type": "application/json" }
          }
        )
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: {
              id: "plan_enterprise",
              productId: "stacio",
              name: "Enterprise",
              maxDevices: 100,
              maxSeats: 75,
              trialDays: 30,
              offlineGraceDays: 60,
              allowedChannels: ["stable", "beta"],
              entitlements: ["pro_features", "sso"],
              status: "active",
              createdAt: "2026-07-10T00:00:00.000Z",
              updatedAt: "2026-07-10T00:00:00.000Z"
            }
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        )
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: {
              id: "plan_enterprise",
              status: "archived"
            }
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        )
      );

    const input = {
      id: "plan_enterprise",
      name: "Enterprise",
      maxDevices: 100,
      maxSeats: 50,
      trialDays: 30,
      offlineGraceDays: 60,
      allowedChannels: ["stable", "beta"],
      entitlements: ["pro_features"]
    };
    await expect(opsClient.createPlan("stacio", input)).resolves.toEqual(
      expect.objectContaining({ id: "plan_enterprise" })
    );
    await expect(
      opsClient.updatePlan("stacio", "plan_enterprise", {
        maxSeats: 75,
        entitlements: ["pro_features", "sso"]
      })
    ).resolves.toEqual(expect.objectContaining({ maxSeats: 75 }));
    await expect(opsClient.archivePlan("stacio", "plan_enterprise")).resolves.toEqual(
      expect.objectContaining({ status: "archived" })
    );

    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "/api/v1/products/stacio/plans",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify(input)
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "/api/v1/products/stacio/plans/plan_enterprise",
      expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({
          maxSeats: 75,
          entitlements: ["pro_features", "sso"]
        })
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      3,
      "/api/v1/products/stacio/plans/plan_enterprise/archive",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ confirmation: "ARCHIVE" })
      })
    );
  });

  it("manages channel changes, history, and rollback through product-scoped APIs", async () => {
    const channel = {
      id: "channel_canary",
      productId: "stacio",
      name: "canary",
      allowedPlanIds: ["plan_internal"],
      rolloutPercentage: 100,
      autoDownloadAllowed: false,
      forceUpdatePrompt: false,
      status: "active",
      createdAt: "2026-07-10T00:00:00.000Z",
      updatedAt: "2026-07-10T00:00:00.000Z"
    };
    const history = [
      {
        id: "audit_channel_1",
        action: "channel.updated",
        targetType: "channel",
        targetId: "channel_canary",
        beforeValue: { rolloutPercentage: 100 },
        afterValue: { rolloutPercentage: 20 },
        createdAt: "2026-07-10T00:00:00.000Z"
      }
    ];
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ ok: true, data: channel }), {
          status: 201,
          headers: { "Content-Type": "application/json" }
        })
      )
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            data: { ...channel, rolloutPercentage: 20 }
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        )
      )
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ ok: true, data: history }), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
      )
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ ok: true, data: channel }), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
      );

    const input = {
      name: "canary",
      allowedPlanIds: ["plan_internal"],
      rolloutPercentage: 100,
      autoDownloadAllowed: false,
      forceUpdatePrompt: false
    };
    await expect(opsClient.createChannel("stacio", input)).resolves.toEqual(channel);
    await expect(
      opsClient.updateChannel("stacio", "channel_canary", {
        rolloutPercentage: 20
      })
    ).resolves.toEqual(expect.objectContaining({ rolloutPercentage: 20 }));
    await expect(
      opsClient.channelHistory("stacio", "channel_canary")
    ).resolves.toEqual(history);
    await expect(
      opsClient.rollbackChannel("stacio", "channel_canary", "audit_channel_1")
    ).resolves.toEqual(channel);

    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "/api/v1/products/stacio/channels",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify(input)
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "/api/v1/products/stacio/channels/channel_canary",
      expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ rolloutPercentage: 20 })
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      3,
      "/api/v1/products/stacio/channels/channel_canary/history",
      expect.objectContaining({ method: "GET" })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      4,
      "/api/v1/products/stacio/channels/channel_canary/rollback",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({
          historyId: "audit_channel_1",
          confirmation: "ROLLBACK"
        })
      })
    );
  });
});
