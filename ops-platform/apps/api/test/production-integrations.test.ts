import { afterEach, describe, expect, it, vi } from "vitest";
import type { OpsJobQueue } from "../src/jobs/queue.js";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

function notificationJobQueue() {
  const enqueueNotificationSend = vi.fn(async (payload: unknown) => ({
    id: `job_notification_${String(enqueueNotificationSend.mock.calls.length)}`,
    name: "notification.send" as const,
    payload
  }));
  const jobQueue: OpsJobQueue = {
    enqueueNotificationSend,
    async enqueueGitHubPull(payload) {
      return {
        id: "job_github_unused",
        name: "github.pull",
        payload
      };
    }
  };
  return { jobQueue, enqueueNotificationSend };
}

describe("production integration surfaces", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("renders and sends notification email through the SMTP dry-run path", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const templateResponse = await server.inject({
      method: "PUT",
      url: "/api/v1/products/stacio/notification-templates/feedback_reply",
      headers,
      payload: {
        subjectTemplate: "Stacio 回复: {{feedback.title}}",
        htmlTemplate: "<p>{{reply.body}}</p>",
        textTemplate: "{{reply.body}}"
      }
    });
    expect(templateResponse.statusCode).toBe(200);

    const notificationResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/notifications",
      headers,
      payload: {
        type: "feedback_reply",
        recipient: "user@example.com",
        priority: "normal",
        payload: {
          feedback: { title: "远端编辑器保存失败" },
          reply: { body: "我们已经收到反馈，会继续跟进。" }
        }
      }
    });
    expect(notificationResponse.statusCode).toBe(201);
    const notificationId = notificationResponse.json().data.id;

    const sendResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/notifications/${notificationId}/send`,
      headers,
      payload: { dryRun: true }
    });

    expect(sendResponse.statusCode).toBe(200);
    expect(sendResponse.json().data).toEqual(
      expect.objectContaining({
        delivery: expect.objectContaining({
          status: "dry_run"
        }),
        rendered: {
          subject: "Stacio 回复: 远端编辑器保存失败",
          html: "<p>我们已经收到反馈，会继续跟进。</p>",
          text: "我们已经收到反馈，会继续跟进。"
        },
        smtp: expect.objectContaining({
          status: "dry_run"
        })
      })
    );

    const listResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/notifications",
      headers
    });
    expect(listResponse.json().data.find((item: { id: string }) => item.id === notificationId)).toEqual(
      expect.objectContaining({
        status: "queued"
      })
    );
  });

  it("pulls real GitHub API issue payloads and syncs them into feedback", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);
    const fetchMock = vi.fn(async () => {
      return new Response(
        JSON.stringify([
          {
            id: 12345,
            number: 77,
            title: "Pulled GitHub issue",
            body: "Imported by pull endpoint",
            labels: [{ name: "bug" }, { name: "priority:p1" }],
            user: { login: "octocat" },
            state: "open",
            comments: 2,
            html_url: "https://github.com/stacio/desktop/issues/77",
            created_at: "2026-07-10T00:00:00.000Z",
            updated_at: "2026-07-10T00:30:00.000Z"
          },
          {
            id: 12346,
            number: 78,
            title: "Pull request should be ignored",
            state: "open",
            html_url: "https://github.com/stacio/desktop/pull/78",
            pull_request: {}
          }
        ]),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    });
    vi.stubGlobal("fetch", fetchMock);

    const response = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/github/pull",
      headers,
      payload: {
        owner: "stacio",
        repository: "desktop",
        state: "all",
        labels: ["bug"],
        perPage: 25
      }
    });

    expect(response.statusCode).toBe(200);
    expect(fetchMock).toHaveBeenCalledOnce();
    expect(response.json().data).toEqual(
      expect.objectContaining({
        run: expect.objectContaining({
          fetchedCount: 1,
          changedCount: 1
        }),
        feedbackCreated: [
          expect.objectContaining({
            title: "Pulled GitHub issue",
            priority: "P1",
            source: "github"
          })
        ]
      })
    );
  });

  it("records failed GitHub pull attempts and queues the admin failure email", async () => {
    const { jobQueue, enqueueNotificationSend } = notificationJobQueue();
    const server = buildServer({ jobQueue });
    const headers = await ownerAuthorization(server);
    vi.stubGlobal("fetch", vi.fn(async () => new Response("Forbidden", { status: 403 })));

    const response = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/github/pull",
      headers,
      payload: {
        owner: "stacio",
        repository: "desktop"
      }
    });

    expect(response.statusCode).toBe(502);

    const runsResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/github/sync-runs",
      headers
    });
    expect(runsResponse.statusCode).toBe(200);
    expect(runsResponse.json().data).toEqual([
      expect.objectContaining({
        trigger: "manual",
        status: "failed",
        fetchedCount: 0,
        changedCount: 0,
        error: "GitHub API returned 403"
      })
    ]);

    const notificationsResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/notifications",
      headers
    });
    expect(notificationsResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          type: "admin_github_sync_failure",
          recipient: "support@stacio.dev",
          priority: "high",
          status: "queued",
          payload: expect.objectContaining({
            error: "GitHub API returned 403",
            statusCode: 403,
            owner: "stacio",
            repository: "desktop"
          })
        })
      ])
    );
    const failureNotification = notificationsResponse
      .json()
      .data.find((item: { type: string }) => item.type === "admin_github_sync_failure");
    expect(enqueueNotificationSend).toHaveBeenCalledWith({
      productId: "stacio",
      notificationId: failureNotification.id,
      requestedBy: "usr_development_owner",
      dryRun: false
    });
  });

  it("creates object-storage upload URLs without exposing credentials", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/storage/presign-upload",
      headers,
      payload: {
        category: "release_artifact",
        refId: "rel_001",
        fileName: "Stacio 0.14 Beta.dmg",
        contentType: "application/x-apple-diskimage",
        sizeBytes: 123456,
        dryRun: true
      }
    });

    expect(response.statusCode).toBe(200);
    expect(response.json().data).toEqual(
      expect.objectContaining({
        bucket: "stacio-ops",
        method: "PUT",
        dryRun: true,
        headers: {
          "Content-Type": "application/x-apple-diskimage"
        }
      })
    );
    expect(response.json().data.uploadUrl).toMatch(/^mock:\/\/object-storage\/stacio-ops\//);
    expect(response.json().data.objectKey).toContain("release_artifact/rel_001");
    expect(response.json().data.objectKey).toContain("Stacio-0.14-Beta.dmg");
    expect(JSON.stringify(response.json().data)).not.toContain("SECRET");
  });

  it("presigns reusable object-storage categories required by the PRD", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const categories = [
      "release_notes",
      "appcast_file",
      "diagnostics_summary",
      "offline_license",
      "email_asset"
    ];

    for (const category of categories) {
      const response = await server.inject({
        method: "POST",
        url: "/api/v1/products/stacio/storage/presign-upload",
        headers,
        payload: {
          category,
          refId: "asset_ref",
          fileName: `${category}.json`,
          contentType: "application/json",
          sizeBytes: 2048,
          dryRun: true
        }
      });

      expect(response.statusCode).toBe(200);
      expect(response.json().data).toEqual(
        expect.objectContaining({
          objectKey: expect.stringContaining(`${category}/asset_ref`),
          dryRun: true
        })
      );
    }
  });
});
