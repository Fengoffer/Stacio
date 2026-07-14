import { describe, expect, it, vi } from "vitest";
import { createMemoryStore } from "../src/data/store.js";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

describe("feedback management workflow", () => {
  it("searches, updates, comments, batches and audits feedback", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const filteredResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback?priority=P1&search=%E8%BF%9C%E7%AB%AF&sort=priority",
      headers
    });
    expect(filteredResponse.statusCode).toBe(200);
    expect(filteredResponse.json().data).toEqual([
      expect.objectContaining({
        id: "fb_001",
        priority: "P1"
      })
    ]);

    const syncResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/github/sync",
      headers,
      payload: {
        trigger: "manual",
        issues: [
          {
            githubIssueId: "github-search-777",
            number: 777,
            title: "Linked issue only searchable by number",
            body: "This imported issue title and body intentionally omit the numeric marker.",
            labels: ["bug"],
            author: "octocat",
            state: "open",
            commentsCount: 1,
            url: "https://github.com/stacio/desktop/issues/777"
          }
        ]
      }
    });
    expect(syncResponse.statusCode).toBe(200);

    const issueNumberSearchResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback?search=777",
      headers
    });
    expect(issueNumberSearchResponse.statusCode).toBe(200);
    expect(issueNumberSearchResponse.json().data).toEqual([
      expect.objectContaining({
        source: "github",
        title: "Linked issue only searchable by number"
      })
    ]);

    const updateResponse = await server.inject({
      method: "PATCH",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers,
      payload: {
        status: "in_progress",
        priority: "P0",
        assignedUserId: "usr_development_owner"
      }
    });
    expect(updateResponse.statusCode).toBe(200);
    expect(updateResponse.json().data).toEqual(
      expect.objectContaining({
        status: "in_progress",
        priority: "P0",
        assignedUserId: "usr_development_owner"
      })
    );

    const internalCommentResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/comments",
      headers,
      payload: {
        visibility: "internal",
        body: "已复现，等待修复分支。"
      }
    });
    expect(internalCommentResponse.statusCode).toBe(201);
    expect(internalCommentResponse.json().data).toEqual(
      expect.objectContaining({
        visibility: "internal",
        deliveryStatus: "not_applicable"
      })
    );

    const publicDraftResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/comments",
      headers,
      payload: {
        visibility: "public",
        body: "我们已经确认问题，修复完成后会通过邮件通知。"
      }
    });
    expect(publicDraftResponse.statusCode).toBe(201);
    expect(publicDraftResponse.json().data).toEqual(
      expect.objectContaining({
        visibility: "public",
        deliveryStatus: "draft"
      })
    );

    const batchResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/batch",
      headers,
      payload: {
        feedbackIds: ["fb_001", "fb_002", "missing"],
        changes: {
          status: "triaged"
        }
      }
    });
    expect(batchResponse.statusCode).toBe(200);
    expect(batchResponse.json().data).toEqual(
      expect.objectContaining({
        requestedCount: 3,
        updatedCount: 2
      })
    );

    const detailResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers
    });
    expect(detailResponse.statusCode).toBe(200);
    expect(detailResponse.json().data.comments).toHaveLength(2);
    expect(detailResponse.json().data.auditEvents).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "feedback.updated",
          targetType: "feedback",
          targetId: "fb_001"
        }),
        expect.objectContaining({
          action: "feedback.internal_note_created",
          targetType: "feedback",
          targetId: "fb_001"
        })
      ])
    );

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio",
      headers
    });
    const actions = auditResponse.json().data.map((item: { action: string }) => item.action);
    expect(actions).toEqual(
      expect.arrayContaining([
        "feedback.updated",
        "feedback.internal_note_created",
        "feedback.reply_draft_created",
        "feedback.batch_updated"
      ])
    );
  });

  it("keeps newest sorting based on creation time and last activity sorting based on updates", async () => {
    const store = createMemoryStore();
    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);

    vi.useFakeTimers({ toFake: ["Date"] });
    try {
      vi.setSystemTime(new Date("2026-07-10T10:00:00.000Z"));
      const newlySubmitted = await store.createFeedback("stacio", {
        title: "Newly submitted crash",
        description: "A fresh report should stay first in newest sorting.",
        type: "crash"
      });
      expect(newlySubmitted).toBeDefined();

      vi.setSystemTime(new Date("2026-07-10T11:00:00.000Z"));
      await store.updateFeedback("stacio", "fb_001", {
        status: "in_progress"
      });

      const newestResponse = await server.inject({
        method: "GET",
        url: "/api/v1/products/stacio/feedback?sort=newest",
        headers
      });
      expect(newestResponse.statusCode).toBe(200);
      expect(newestResponse.json().data.map((item: { id: string }) => item.id).slice(0, 2)).toEqual([
        newlySubmitted?.id,
        "fb_001"
      ]);

      const lastActivityResponse = await server.inject({
        method: "GET",
        url: "/api/v1/products/stacio/feedback?sort=last_activity",
        headers
      });
      expect(lastActivityResponse.statusCode).toBe(200);
      expect(lastActivityResponse.json().data.map((item: { id: string }) => item.id).slice(0, 2)).toEqual([
        "fb_001",
        newlySubmitted?.id
      ]);
    } finally {
      vi.useRealTimers();
    }
  });

  it("validates and audits marking feedback as duplicate", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const selfDuplicateResponse = await server.inject({
      method: "PATCH",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers,
      payload: {
        status: "duplicate",
        duplicateOfId: "fb_001"
      }
    });
    expect(selfDuplicateResponse.statusCode).toBe(409);
    expect(selfDuplicateResponse.json().error.code).toBe("INVALID_DUPLICATE_TARGET");

    const missingDuplicateResponse = await server.inject({
      method: "PATCH",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers,
      payload: {
        status: "duplicate",
        duplicateOfId: "fb_missing"
      }
    });
    expect(missingDuplicateResponse.statusCode).toBe(404);
    expect(missingDuplicateResponse.json().error.code).toBe("DUPLICATE_TARGET_NOT_FOUND");

    const markedResponse = await server.inject({
      method: "PATCH",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers,
      payload: {
        status: "duplicate",
        duplicateOfId: "fb_002"
      }
    });
    expect(markedResponse.statusCode).toBe(200);
    expect(markedResponse.json().data).toEqual(
      expect.objectContaining({
        id: "fb_001",
        status: "duplicate",
        duplicateOfId: "fb_002"
      })
    );

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio",
      headers
    });
    expect(auditResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "feedback.marked_duplicate",
          targetId: "fb_001",
          afterValue: expect.objectContaining({
            duplicateOfId: "fb_002"
          })
        })
      ])
    );
  });

  it("validates and audits linking feedback to a related release", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const missingReleaseResponse = await server.inject({
      method: "PATCH",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers,
      payload: {
        relatedReleaseId: "rel_missing"
      }
    });
    expect(missingReleaseResponse.statusCode).toBe(404);
    expect(missingReleaseResponse.json().error.code).toBe("RELATED_RELEASE_NOT_FOUND");

    const linkedResponse = await server.inject({
      method: "PATCH",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers,
      payload: {
        relatedReleaseId: "rel_002"
      }
    });
    expect(linkedResponse.statusCode).toBe(200);
    expect(linkedResponse.json().data).toEqual(
      expect.objectContaining({
        id: "fb_001",
        relatedReleaseId: "rel_002"
      })
    );

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio",
      headers
    });
    expect(auditResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "feedback.related_release_linked",
          targetId: "fb_001",
          afterValue: expect.objectContaining({
            relatedReleaseId: "rel_002"
          })
        })
      ])
    );
  });

  it("audits single feedback owner assignment", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const assignedResponse = await server.inject({
      method: "PATCH",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers,
      payload: {
        assignedUserId: "usr_development_owner"
      }
    });
    expect(assignedResponse.statusCode).toBe(200);
    expect(assignedResponse.json().data).toEqual(
      expect.objectContaining({
        id: "fb_001",
        assignedUserId: "usr_development_owner"
      })
    );

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio",
      headers
    });
    expect(auditResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "feedback.assigned",
          targetId: "fb_001",
          beforeValue: expect.not.objectContaining({
            assignedUserId: "usr_development_owner"
          }),
          afterValue: expect.objectContaining({
            assignedUserId: "usr_development_owner"
          })
        })
      ])
    );
  });
});
