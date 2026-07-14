import { afterEach, describe, expect, it, vi } from "vitest";
import type { OpsJobQueue } from "../src/jobs/queue.js";
import { createMemoryStore } from "../src/data/store.js";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

describe("GitHub sync, notifications, and Agent API", () => {
  it("syncs GitHub issues into the feedback inbox and audits the sync", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const syncResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/github/sync",
      headers,
      payload: {
        trigger: "manual",
        issues: [
          {
            githubIssueId: "987654321",
            number: 42,
            title: "GitHub synced bug",
            body: "Imported from GitHub Issues.",
            labels: ["bug", "p1"],
            author: "github-user",
            state: "open",
            commentsCount: 3,
            url: "https://github.com/example/stacio/issues/42",
            githubCreatedAt: "2026-07-10T00:00:00.000Z",
            githubUpdatedAt: "2026-07-10T01:00:00.000Z"
          }
        ]
      }
    });
    expect(syncResponse.statusCode).toBe(200);
    expect(syncResponse.json().data).toEqual(
      expect.objectContaining({
        run: expect.objectContaining({
          fetchedCount: 1,
          changedCount: 1
        }),
        feedbackCreated: [
          expect.objectContaining({
            title: "GitHub synced bug",
            source: "github",
            type: "bug",
            priority: "P1"
          })
        ]
      })
    );

    const issuesResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/github/issues",
      headers
    });
    expect(issuesResponse.json().data).toEqual([
      expect.objectContaining({
        number: 42,
        linkedFeedbackId: expect.stringMatching(/^fb_/)
      })
    ]);

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio",
      headers
    });
    expect(auditResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "github.sync"
        })
      ])
    );
  });

  it("requires manual confirmation before posting an admin reply to a GitHub issue", async () => {
    vi.stubEnv("GITHUB_OWNER", "example");
    vi.stubEnv("GITHUB_REPOSITORY", "stacio");
    vi.stubEnv("GITHUB_TOKEN", "github-token");
    vi.stubEnv("GITHUB_API_BASE_URL", "https://api.github.test");
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          id: 777,
          html_url: "https://github.com/example/stacio/issues/42#issuecomment-777",
          body: "Thanks, we have reproduced this issue."
        }),
        {
          status: 201,
          headers: { "Content-Type": "application/json" }
        }
      )
    );
    vi.stubGlobal("fetch", fetchMock);

    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const syncResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/github/sync",
      headers,
      payload: {
        trigger: "manual",
        issues: [
          {
            githubIssueId: "987654321",
            number: 42,
            title: "GitHub synced bug",
            body: "Imported from GitHub Issues.",
            labels: ["bug", "p1"],
            author: "github-user",
            state: "open",
            commentsCount: 3,
            url: "https://github.com/example/stacio/issues/42",
            githubCreatedAt: "2026-07-10T00:00:00.000Z",
            githubUpdatedAt: "2026-07-10T01:00:00.000Z"
          }
        ]
      }
    });
    const issueId = syncResponse.json().data.issues[0].id;

    const unconfirmedResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/github/issues/${issueId}/comments`,
      headers,
      payload: {
        body: "Thanks, we have reproduced this issue.",
        confirmation: "SEND"
      }
    });
    expect(unconfirmedResponse.statusCode).toBe(409);
    expect(fetchMock).not.toHaveBeenCalled();

    const commentResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/github/issues/${issueId}/comments`,
      headers,
      payload: {
        body: "Thanks, we have reproduced this issue.",
        confirmation: "POST"
      }
    });

    expect(commentResponse.statusCode).toBe(201);
    expect(commentResponse.json()).toEqual(
      expect.objectContaining({
        data: expect.objectContaining({
          commentId: "777",
          url: "https://github.com/example/stacio/issues/42#issuecomment-777"
        }),
        policy: {
          publicGitHubReplySent: true,
          requiredConfirmation: "POST"
        }
      })
    );
    expect(fetchMock).toHaveBeenCalledWith(
      "https://api.github.test/repos/example/stacio/issues/42/comments",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ body: "Thanks, we have reproduced this issue." }),
        headers: expect.objectContaining({
          Authorization: "Bearer github-token"
        })
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
          action: "github.issue_comment.created",
          targetId: issueId
        })
      ])
    );
  });

  it("requires manual confirmation before changing GitHub labels or closing an issue", async () => {
    vi.stubEnv("GITHUB_OWNER", "example");
    vi.stubEnv("GITHUB_REPOSITORY", "stacio");
    vi.stubEnv("GITHUB_TOKEN", "github-token");
    vi.stubEnv("GITHUB_API_BASE_URL", "https://api.github.test");
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            id: 987654321,
            number: 42,
            title: "GitHub synced bug",
            body: "Imported from GitHub Issues.",
            labels: [{ name: "bug" }, { name: "priority:p0" }],
            user: { login: "github-user" },
            state: "open",
            comments: 3,
            html_url: "https://github.com/example/stacio/issues/42",
            created_at: "2026-07-10T00:00:00.000Z",
            updated_at: "2026-07-10T02:00:00.000Z",
            closed_at: null
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
            id: 987654321,
            number: 42,
            title: "GitHub synced bug",
            body: "Imported from GitHub Issues.",
            labels: [{ name: "bug" }, { name: "priority:p0" }],
            user: { login: "github-user" },
            state: "closed",
            comments: 3,
            html_url: "https://github.com/example/stacio/issues/42",
            created_at: "2026-07-10T00:00:00.000Z",
            updated_at: "2026-07-10T03:00:00.000Z",
            closed_at: "2026-07-10T03:00:00.000Z"
          }),
          {
            status: 200,
            headers: { "Content-Type": "application/json" }
          }
        )
      );
    vi.stubGlobal("fetch", fetchMock);

    const server = buildServer();
    const headers = await ownerAuthorization(server);
    const syncResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/github/sync",
      headers,
      payload: {
        trigger: "manual",
        issues: [
          {
            githubIssueId: "987654321",
            number: 42,
            title: "GitHub synced bug",
            body: "Imported from GitHub Issues.",
            labels: ["bug", "p1"],
            author: "github-user",
            state: "open",
            commentsCount: 3,
            url: "https://github.com/example/stacio/issues/42",
            githubCreatedAt: "2026-07-10T00:00:00.000Z",
            githubUpdatedAt: "2026-07-10T01:00:00.000Z"
          }
        ]
      }
    });
    const issueId = syncResponse.json().data.issues[0].id;

    const unconfirmedLabelsResponse = await server.inject({
      method: "PATCH",
      url: `/api/v1/products/stacio/github/issues/${issueId}`,
      headers,
      payload: {
        labels: ["bug", "priority:p0"],
        confirmation: "POST"
      }
    });
    expect(unconfirmedLabelsResponse.statusCode).toBe(409);
    expect(fetchMock).not.toHaveBeenCalled();

    const labelsResponse = await server.inject({
      method: "PATCH",
      url: `/api/v1/products/stacio/github/issues/${issueId}`,
      headers,
      payload: {
        labels: ["bug", "priority:p0"],
        confirmation: "APPLY_LABELS"
      }
    });
    expect(labelsResponse.statusCode).toBe(200);
    expect(labelsResponse.json()).toEqual(
      expect.objectContaining({
        data: expect.objectContaining({
          labels: ["bug", "priority:p0"],
          state: "open"
        }),
        policy: {
          publicGitHubIssueChanged: true,
          requiredConfirmation: "APPLY_LABELS"
        }
      })
    );

    const closeResponse = await server.inject({
      method: "PATCH",
      url: `/api/v1/products/stacio/github/issues/${issueId}`,
      headers,
      payload: {
        state: "closed",
        confirmation: "CLOSE"
      }
    });
    expect(closeResponse.statusCode).toBe(200);
    expect(closeResponse.json().data).toEqual(
      expect.objectContaining({
        state: "closed",
        githubClosedAt: "2026-07-10T03:00:00.000Z"
      })
    );

    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "https://api.github.test/repos/example/stacio/issues/42",
      expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ labels: ["bug", "priority:p0"] }),
        headers: expect.objectContaining({
          Authorization: "Bearer github-token"
        })
      })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "https://api.github.test/repos/example/stacio/issues/42",
      expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ state: "closed" })
      })
    );

    const issuesResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/github/issues",
      headers
    });
    expect(issuesResponse.json().data).toEqual([
      expect.objectContaining({
        id: issueId,
        labels: ["bug", "priority:p0"],
        state: "closed"
      })
    ]);

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio",
      headers
    });
    expect(auditResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "github.issue_labels.updated",
          targetId: issueId
        }),
        expect.objectContaining({
          action: "github.issue.closed",
          targetId: issueId
        })
      ])
    );
  });

  it("lets scoped agents read synced GitHub issues without posting public comments", async () => {
    vi.stubEnv(
      "AGENT_API_KEYS_JSON",
      JSON.stringify([
        {
          id: "agent_issue_reader",
          key: "issue-reader-key",
          productIds: ["stacio"],
          scopes: ["issues:read"]
        }
      ])
    );
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const syncResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/github/sync",
      headers,
      payload: {
        trigger: "manual",
        issues: [
          {
            githubIssueId: "987654321",
            number: 42,
            title: "GitHub synced bug",
            body: "Imported from GitHub Issues.",
            labels: ["bug", "p1"],
            author: "github-user",
            state: "open",
            commentsCount: 3,
            url: "https://github.com/example/stacio/issues/42",
            githubCreatedAt: "2026-07-10T00:00:00.000Z",
            githubUpdatedAt: "2026-07-10T01:00:00.000Z"
          }
        ]
      }
    });
    expect(syncResponse.statusCode).toBe(200);

    const issuesResponse = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/github/issues",
      headers: {
        authorization: "Bearer issue-reader-key"
      }
    });

    expect(issuesResponse.statusCode).toBe(200);
    expect(issuesResponse.json()).toEqual(
      expect.objectContaining({
        data: expect.arrayContaining([
          expect.objectContaining({
            number: 42,
            title: "GitHub synced bug",
            state: "open"
          })
        ]),
        policy: {
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false,
          licenseKeyRevealed: false
        }
      })
    );
  });

  it("lets agents read triage and write analysis without high-risk actions", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);
    const agentHeaders = {
      authorization: "Bearer development-agent-key"
    };

    const queueResponse = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/feedback/triage-queue",
      headers: agentHeaders
    });
    expect(queueResponse.statusCode).toBe(200);
    expect(queueResponse.json().data.length).toBeGreaterThan(0);

    const analysisResponse = await server.inject({
      method: "POST",
      url: "/api/agent/v1/products/stacio/feedback/fb_001/analysis",
      headers: agentHeaders,
      payload: {
        agentIdentity: "codex-test",
        provider: "openai",
        model: "gpt-test",
        analysisType: "feedback_triage",
        inputReferences: {
          feedbackId: "fb_001"
        },
        outputBody: {
          summary: "保存失败可能与重连后的 revision 有关。",
          classification: "bug",
          prioritySuggestion: "P1",
          replyDraft: "我们已经定位方向，会继续跟进。"
        },
        confidence: "medium"
      }
    });
    expect(analysisResponse.statusCode).toBe(201);
    expect(analysisResponse.json()).toEqual(
      expect.objectContaining({
        policy: {
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false
        }
      })
    );

    const detailResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers
    });
    expect(detailResponse.json().data).toEqual(
      expect.objectContaining({
        aiSummary: "保存失败可能与重连后的 revision 有关。",
        aiClassification: "bug",
        aiSuggestedPriority: "P1"
      })
    );
  });

  it("lets scoped agents write feedback reply drafts without sending customer-visible email", async () => {
    vi.stubEnv(
      "AGENT_API_KEYS_JSON",
      JSON.stringify([
        {
          id: "agent_reply_drafter",
          key: "reply-draft-key",
          productIds: ["stacio"],
          scopes: ["feedback:write_draft"]
        }
      ])
    );
    const server = buildServer();

    const draftResponse = await server.inject({
      method: "POST",
      url: "/api/agent/v1/products/stacio/feedback/fb_001/reply-drafts",
      headers: {
        authorization: "Bearer reply-draft-key"
      },
      payload: {
        agentIdentity: "codex-reply-agent",
        replyDraft: "我们已经收到这个保存失败问题，会优先排查远端编辑器链路。",
        tone: "supportive",
        inputReferences: {
          feedbackId: "fb_001"
        }
      }
    });

    expect(draftResponse.statusCode).toBe(201);
    expect(draftResponse.json()).toEqual(
      expect.objectContaining({
        data: expect.objectContaining({
          targetType: "feedback",
          targetId: "fb_001",
          analysisType: "feedback_reply_draft",
          outputBody: expect.objectContaining({
            replyDraft: "我们已经收到这个保存失败问题，会优先排查远端编辑器链路。",
            tone: "supportive"
          })
        }),
        policy: {
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false,
          feedbackDeleted: false
        }
      })
    );
  });

  it("lets scoped agents create notification drafts without delivering mail", async () => {
    vi.stubEnv(
      "AGENT_API_KEYS_JSON",
      JSON.stringify([
        {
          id: "agent_notification_drafter",
          key: "notification-draft-key",
          productIds: ["stacio"],
          scopes: ["notifications:write_draft"]
        }
      ])
    );
    const store = createMemoryStore();
    const server = buildServer({ store });

    const draftResponse = await server.inject({
      method: "POST",
      url: "/api/agent/v1/products/stacio/notifications/drafts",
      headers: {
        authorization: "Bearer notification-draft-key"
      },
      payload: {
        type: "customer_feedback_reply",
        recipient: "tester@example.com",
        priority: "normal",
        payload: {
          productName: "Stacio",
          reply: "我们已经收到你的反馈。"
        }
      }
    });

    expect(draftResponse.statusCode).toBe(201);
    const notification = draftResponse.json().data;
    expect(draftResponse.json()).toEqual(
      expect.objectContaining({
        data: expect.objectContaining({
          type: "customer_feedback_reply",
          recipient: "tester@example.com",
          status: "draft"
        }),
        policy: {
          customerVisibleEmailSent: false,
          notificationSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false
        }
      })
    );
    expect(await store.listNotificationDeliveries(notification.id)).toEqual([]);
  });

  it("lets agents propose actions for human review without executing them", async () => {
    vi.stubEnv(
      "AGENT_API_KEYS_JSON",
      JSON.stringify([
        {
          id: "agent_action_proposer",
          key: "action-proposer-key",
          productIds: ["stacio"],
          scopes: ["actions:propose"]
        }
      ])
    );
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const proposeResponse = await server.inject({
      method: "POST",
      url: "/api/agent/v1/products/stacio/proposed-actions",
      headers: {
        authorization: "Bearer action-proposer-key"
      },
      payload: {
        agentIdentity: "codex-action-agent",
        provider: "openai",
        model: "gpt-test",
        targetType: "feedback",
        targetId: "fb_001",
        actionType: "feedback.update_status",
        payload: {
          status: "in_progress",
          priority: "P1"
        },
        rationale: "用户反馈影响远端编辑器保存链路，建议进入处理状态。",
        confidence: "medium",
        inputReferences: {
          feedbackId: "fb_001"
        }
      }
    });

    expect(proposeResponse.statusCode).toBe(201);
    const proposedAction = proposeResponse.json().data;
    expect(proposeResponse.json()).toEqual(
      expect.objectContaining({
        data: expect.objectContaining({
          id: expect.stringMatching(/^act_/),
          actionType: "feedback.update_status",
          status: "pending",
          targetType: "feedback",
          targetId: "fb_001",
          payload: {
            status: "in_progress",
            priority: "P1"
          },
          analysis: expect.objectContaining({
            analysisType: "proposed_action",
            agentIdentity: "codex-action-agent"
          })
        }),
        policy: {
          actionExecuted: false,
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false,
          feedbackDeleted: false
        }
      })
    );

    const listResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/proposed-actions",
      headers
    });
    expect(listResponse.statusCode).toBe(200);
    expect(listResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: proposedAction.id,
          actionType: "feedback.update_status",
          status: "pending"
        })
      ])
    );

    const reviewResponse = await server.inject({
      method: "PATCH",
      url: `/api/v1/products/stacio/proposed-actions/${proposedAction.id}`,
      headers,
      payload: {
        status: "accepted"
      }
    });
    expect(reviewResponse.statusCode).toBe(200);
    expect(reviewResponse.json()).toEqual(
      expect.objectContaining({
        data: expect.objectContaining({
          id: proposedAction.id,
          status: "accepted"
        }),
        policy: {
          actionExecuted: false,
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false,
          feedbackDeleted: false
        }
      })
    );

    const feedbackResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers
    });
    expect(feedbackResponse.json().data).toEqual(
      expect.objectContaining({
        status: "new",
        priority: "P1"
      })
    );
  });

  it("executes accepted low-risk feedback proposed actions after explicit admin confirmation", async () => {
    vi.stubEnv(
      "AGENT_API_KEYS_JSON",
      JSON.stringify([
        {
          id: "agent_action_proposer",
          key: "action-proposer-key",
          productIds: ["stacio"],
          scopes: ["actions:propose"]
        }
      ])
    );
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const proposeResponse = await server.inject({
      method: "POST",
      url: "/api/agent/v1/products/stacio/proposed-actions",
      headers: {
        authorization: "Bearer action-proposer-key"
      },
      payload: {
        agentIdentity: "codex-action-agent",
        targetType: "feedback",
        targetId: "fb_001",
        actionType: "feedback.update_status",
        payload: {
          status: "in_progress"
        },
        rationale: "该反馈影响核心远端编辑器保存链路，建议进入处理中。",
        confidence: "medium"
      }
    });
    expect(proposeResponse.statusCode).toBe(201);
    const proposedAction = proposeResponse.json().data;

    const reviewResponse = await server.inject({
      method: "PATCH",
      url: `/api/v1/products/stacio/proposed-actions/${proposedAction.id}`,
      headers,
      payload: {
        status: "accepted"
      }
    });
    expect(reviewResponse.statusCode).toBe(200);

    const unconfirmedExecuteResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/proposed-actions/${proposedAction.id}/execute`,
      headers,
      payload: {
        confirmation: "RUN"
      }
    });
    expect(unconfirmedExecuteResponse.statusCode).toBe(409);
    expect(unconfirmedExecuteResponse.json()).toEqual(
      expect.objectContaining({
        error: expect.objectContaining({
          code: "ACTION_EXECUTION_CONFIRMATION_REQUIRED"
        }),
        policy: expect.objectContaining({
          actionExecuted: false,
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false,
          feedbackDeleted: false
        })
      })
    );

    const unchangedFeedbackResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers
    });
    expect(unchangedFeedbackResponse.json().data).toEqual(
      expect.objectContaining({
        status: "new"
      })
    );

    const executeResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/proposed-actions/${proposedAction.id}/execute`,
      headers,
      payload: {
        confirmation: "EXECUTE"
      }
    });
    expect(executeResponse.statusCode).toBe(200);
    expect(executeResponse.json()).toEqual(
      expect.objectContaining({
        data: expect.objectContaining({
          action: expect.objectContaining({
            id: proposedAction.id,
            status: "executed",
            actionType: "feedback.update_status"
          }),
          result: expect.objectContaining({
            targetType: "feedback",
            targetId: "fb_001",
            changes: {
              status: "in_progress"
            }
          })
        }),
        policy: {
          actionExecuted: true,
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false,
          feedbackDeleted: false
        }
      })
    );

    const duplicateExecuteResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/proposed-actions/${proposedAction.id}/execute`,
      headers,
      payload: {
        confirmation: "EXECUTE"
      }
    });
    expect(duplicateExecuteResponse.statusCode).toBe(409);
    expect(duplicateExecuteResponse.json()).toEqual(
      expect.objectContaining({
        error: expect.objectContaining({
          code: "ACTION_ALREADY_EXECUTED"
        }),
        policy: expect.objectContaining({
          actionExecuted: false,
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false,
          feedbackDeleted: false
        })
      })
    );

    const feedbackResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers
    });
    expect(feedbackResponse.json().data).toEqual(
      expect.objectContaining({
        status: "in_progress"
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
          action: "ai_proposed_action.executed",
          targetId: proposedAction.id
        })
      ])
    );
  });

  it("lets agents read feedback details with comments, attachments, linked GitHub issues, and prior analysis", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);
    const agentHeaders = {
      authorization: "Bearer development-agent-key"
    };

    const commentResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/comments",
      headers,
      payload: {
        authorType: "user",
        visibility: "internal",
        body: "重连后保存失败，先请 Agent 看是否和 revision 缓存有关。"
      }
    });
    expect(commentResponse.statusCode).toBe(201);

    const attachmentResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/attachments",
      headers,
      payload: {
        objectKey: "products/stacio/feedback/fb_001/diagnostics.json",
        fileName: "diagnostics.json",
        contentType: "application/json",
        sizeBytes: 2048
      }
    });
    expect(attachmentResponse.statusCode).toBe(201);

    const syncResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/github/sync",
      headers,
      payload: {
        trigger: "manual",
        issues: [
          {
            githubIssueId: "987654321",
            number: 42,
            title: "GitHub synced bug",
            body: "Imported from GitHub Issues.",
            labels: ["bug", "p1"],
            author: "github-user",
            state: "open",
            commentsCount: 3,
            url: "https://github.com/example/stacio/issues/42",
            githubCreatedAt: "2026-07-10T00:00:00.000Z",
            githubUpdatedAt: "2026-07-10T01:00:00.000Z"
          }
        ]
      }
    });
    const githubIssueId = syncResponse.json().data.issues[0].id;
    const linkResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/github-links",
      headers,
      payload: {
        githubIssueId
      }
    });
    expect(linkResponse.statusCode).toBe(201);

    const analysisResponse = await server.inject({
      method: "POST",
      url: "/api/agent/v1/products/stacio/feedback/fb_001/analysis",
      headers: agentHeaders,
      payload: {
        agentIdentity: "codex-test",
        analysisType: "feedback_triage",
        outputBody: {
          summary: "重连后保存失败可能和 revision 缓存有关。",
          classification: "bug",
          prioritySuggestion: "P1",
          replyDraft: "我们已经定位到远端编辑器保存链路。"
        },
        confidence: "0.82"
      }
    });
    expect(analysisResponse.statusCode).toBe(201);

    const detailResponse = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/feedback/fb_001",
      headers: agentHeaders
    });

    expect(detailResponse.statusCode).toBe(200);
    expect(detailResponse.json()).toEqual(
      expect.objectContaining({
        data: expect.objectContaining({
          feedback: expect.objectContaining({
            id: "fb_001",
            title: "远端编辑器保存后偶发失败"
          }),
          comments: expect.arrayContaining([
            expect.objectContaining({
              visibility: "internal",
              body: "重连后保存失败，先请 Agent 看是否和 revision 缓存有关。"
            })
          ]),
          attachments: expect.arrayContaining([
            expect.objectContaining({
              fileName: "diagnostics.json"
            })
          ]),
          linkedGitHubIssues: expect.arrayContaining([
            expect.objectContaining({
              number: 42
            })
          ]),
          aiAnalysis: expect.arrayContaining([
            expect.objectContaining({
              agentIdentity: "codex-test",
              adoptionState: "pending"
            })
          ])
        }),
        policy: {
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false,
          feedbackDeleted: false
        }
      })
    );
  });

  it("lets scoped agents read customer lists and details without mutating customer-visible state", async () => {
    vi.stubEnv(
      "AGENT_API_KEYS_JSON",
      JSON.stringify([
        {
          id: "agent_customer_reader",
          key: "customer-reader-key",
          productIds: ["stacio"],
          scopes: ["customers:read"]
        }
      ])
    );
    const server = buildServer();
    const agentHeaders = {
      authorization: "Bearer customer-reader-key"
    };

    const listResponse = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/customers",
      headers: agentHeaders
    });

    expect(listResponse.statusCode).toBe(200);
    expect(listResponse.json()).toEqual(
      expect.objectContaining({
        data: expect.arrayContaining([
          expect.objectContaining({
            id: expect.stringMatching(/^cust_/),
            email: "tester@example.com",
            name: "Internal Tester"
          })
        ]),
        policy: {
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false,
          licenseKeyRevealed: false
        }
      })
    );

    const customerId = listResponse.json().data[0].id;
    const detailResponse = await server.inject({
      method: "GET",
      url: `/api/agent/v1/products/stacio/customers/${customerId}`,
      headers: agentHeaders
    });

    expect(detailResponse.statusCode).toBe(200);
    expect(detailResponse.json()).toEqual(
      expect.objectContaining({
        data: expect.objectContaining({
          customer: expect.objectContaining({
            id: customerId
          }),
          licenses: expect.any(Array),
          feedback: expect.any(Array),
          notifications: expect.any(Array),
          notes: expect.any(Array),
          activationCount: expect.any(Number),
          auditLogs: expect.any(Array)
        }),
        policy: {
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false,
          licenseKeyRevealed: false
        }
      })
    );
  });

  it("lets scoped agents read license summaries without exposing license keys", async () => {
    vi.stubEnv(
      "AGENT_API_KEYS_JSON",
      JSON.stringify([
        {
          id: "agent_license_reader",
          key: "license-reader-key",
          productIds: ["stacio"],
          scopes: ["licenses:read"]
        }
      ])
    );
    const server = buildServer();
    const agentHeaders = {
      authorization: "Bearer license-reader-key"
    };

    const listResponse = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/licenses",
      headers: agentHeaders
    });

    expect(listResponse.statusCode).toBe(200);
    expect(listResponse.json()).toEqual(
      expect.objectContaining({
        data: expect.arrayContaining([
          expect.objectContaining({
            id: expect.stringMatching(/^lic_/),
            customerEmail: expect.any(String),
            plan: expect.any(String),
            status: expect.any(String)
          })
        ]),
        policy: {
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false,
          licenseKeyRevealed: false
        }
      })
    );
    expect(JSON.stringify(listResponse.json().data)).not.toContain("licenseKey");

    vi.stubEnv(
      "AGENT_API_KEYS_JSON",
      JSON.stringify([
        {
          id: "agent_feedback_only",
          key: "feedback-only-key",
          productIds: ["stacio"],
          scopes: ["feedback:read"]
        }
      ])
    );
    const deniedServer = buildServer();
    const deniedResponse = await deniedServer.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/licenses",
      headers: {
        authorization: "Bearer feedback-only-key"
      }
    });
    expect(deniedResponse.statusCode).toBe(403);
    expect(deniedResponse.json().error.code).toBe("AGENT_SCOPE_DENIED");
  });

  it("lets admins review AI analysis and apply accepted feedback suggestions without risky side effects", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);
    const agentHeaders = {
      authorization: "Bearer development-agent-key"
    };

    const analysisResponse = await server.inject({
      method: "POST",
      url: "/api/agent/v1/products/stacio/feedback/fb_001/analysis",
      headers: agentHeaders,
      payload: {
        agentIdentity: "codex-test",
        analysisType: "feedback_triage",
        outputBody: {
          summary: "AI 建议采纳后的摘要。",
          classification: "bug",
          prioritySuggestion: "P0",
          replyDraft: "我们会优先排查这个问题。"
        }
      }
    });
    const analysisId = analysisResponse.json().data.id;

    const reviewResponse = await server.inject({
      method: "PATCH",
      url: `/api/v1/products/stacio/ai-analysis/${analysisId}`,
      headers,
      payload: {
        adoptionState: "accepted"
      }
    });

    expect(reviewResponse.statusCode).toBe(200);
    expect(reviewResponse.json()).toEqual(
      expect.objectContaining({
        data: expect.objectContaining({
          id: analysisId,
          adoptionState: "accepted"
        }),
        policy: {
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false
        }
      })
    );

    const detailResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers
    });
    expect(detailResponse.json().data).toEqual(
      expect.objectContaining({
        aiSummary: "AI 建议采纳后的摘要。",
        aiClassification: "bug",
        aiSuggestedPriority: "P0"
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
          action: "ai_analysis.reviewed",
          targetId: analysisId
        })
      ])
    );
  });

  it("lets agents draft release analysis without publishing OTA", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);
    const agentHeaders = {
      authorization: "Bearer development-agent-key"
    };

    const createReleaseResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/releases",
      headers,
      payload: {
        channel: "beta",
        version: "0.15.0-Beta",
        buildNumber: "30",
        artifactName: "Stacio-0.15.0-Beta.dmg"
      }
    });
    expect(createReleaseResponse.statusCode).toBe(201);
    const releaseId = createReleaseResponse.json().data.id;

    const draftsResponse = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/releases/drafts",
      headers: agentHeaders
    });
    expect(draftsResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: releaseId,
          status: "draft"
        })
      ])
    );

    const analysisResponse = await server.inject({
      method: "POST",
      url: `/api/agent/v1/products/stacio/releases/${releaseId}/analysis`,
      headers: agentHeaders,
      payload: {
        agentIdentity: "claude-release-agent",
        analysisType: "release_risk_summary",
        outputBody: {
          summary: "AI release summary",
          releaseNotesDraft: "Draft notes",
          riskSummary: "Manual validation is still required."
        }
      }
    });
    expect(analysisResponse.statusCode).toBe(201);
    expect(analysisResponse.json()).toEqual(
      expect.objectContaining({
        policy: {
          otaPublished: false,
          channelChanged: false,
          customerVisibleEmailSent: false
        }
      })
    );

    const listResponse = await server.inject({
      method: "GET",
      url: `/api/v1/products/stacio/ai-analysis?targetType=release&targetId=${releaseId}`,
      headers
    });
    expect(listResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          targetType: "release",
          targetId: releaseId,
          analysisType: "release_risk_summary"
        })
      ])
    );

    const analysisId = analysisResponse.json().data.id;
    const reviewResponse = await server.inject({
      method: "PATCH",
      url: `/api/v1/products/stacio/ai-analysis/${analysisId}`,
      headers,
      payload: {
        adoptionState: "accepted"
      }
    });
    expect(reviewResponse.statusCode).toBe(200);
    expect(reviewResponse.json()).toEqual(
      expect.objectContaining({
        policy: {
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false
        }
      })
    );

    const releasesResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/releases",
      headers
    });
    expect(releasesResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: releaseId,
          status: "draft",
          releaseNotes: "Draft notes",
          aiReleaseSummary: "AI release summary",
          aiRiskSummary: "Manual validation is still required."
        })
      ])
    );
  });

  it("queues release Agent requests for release notes and risk drafts", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);
    const agentHeaders = {
      authorization: "Bearer development-agent-key"
    };

    const createReleaseResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/releases",
      headers,
      payload: {
        channel: "beta",
        version: "0.15.1-Beta",
        buildNumber: "31",
        artifactName: "Stacio-0.15.1-Beta.dmg"
      }
    });
    expect(createReleaseResponse.statusCode).toBe(201);
    const releaseId = createReleaseResponse.json().data.id;

    const requestResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${releaseId}/agent-requests`,
      headers,
      payload: {
        requestType: "release_notes",
        agentHint: "codex",
        prompt: "请为 0.15.1-Beta 生成面向用户的发布说明草稿。"
      }
    });
    expect(requestResponse.statusCode).toBe(201);
    expect(requestResponse.json()).toEqual(
      expect.objectContaining({
        data: expect.objectContaining({
          targetType: "release",
          targetId: releaseId,
          requestType: "release_notes",
          agentHint: "codex",
          status: "queued"
        }),
        policy: expect.objectContaining({
          otaPublished: false,
          actionExecuted: false
        })
      })
    );

    const adminListResponse = await server.inject({
      method: "GET",
      url: `/api/v1/products/stacio/releases/${releaseId}/agent-requests`,
      headers
    });
    expect(adminListResponse.statusCode).toBe(200);
    expect(adminListResponse.json().data).toEqual([
      expect.objectContaining({
        id: requestResponse.json().data.id,
        requestType: "release_notes"
      })
    ]);

    const agentListResponse = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/releases/agent-requests?status=queued",
      headers: agentHeaders
    });
    expect(agentListResponse.statusCode).toBe(200);
    expect(agentListResponse.json()).toEqual(
      expect.objectContaining({
        data: expect.arrayContaining([
          expect.objectContaining({
            id: requestResponse.json().data.id,
            targetType: "release",
            targetId: releaseId,
            requestType: "release_notes"
          })
        ]),
        policy: expect.objectContaining({
          otaPublished: false,
          customerVisibleEmailSent: false
        })
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
          action: "agent_request.created",
          targetType: "agent_request",
          targetId: requestResponse.json().data.id
        })
      ])
    );
  });

  it("manages branded templates and records delivery history only through the send flow", async () => {
    const store = createMemoryStore();
    await store.updateProduct("stacio", {
      emailBrand: {
        name: "Stacio",
        senderName: "Zerx Lab Support",
        accentColor: "#123456",
        replyToEmail: "help@stacio.dev",
        footerText: "Sent by Zerx Lab"
      }
    });
    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);

    const templateResponse = await server.inject({
      method: "PUT",
      url: "/api/v1/products/stacio/notification-templates/customer_feedback_reply",
      headers,
      payload: {
        subjectTemplate: "{{brand.senderName}} feedback update: {{feedbackTitle}}",
        htmlTemplate: "<strong style=\"color:{{brand.accentColor}}\">{{brand.name}}</strong><p>{{reply}}</p>",
        textTemplate: "{{brand.footerText}}: {{reply}}"
      }
    });
    expect(templateResponse.statusCode).toBe(200);

    const previewResponse = await server.inject({
      method: "POST",
      url: "/api/v1/notification-templates/preview",
      headers,
      payload: {
        productId: "stacio",
        subjectTemplate: "{{brand.senderName}} feedback update: {{feedbackTitle}}",
        htmlTemplate: "<strong style=\"color:{{brand.accentColor}}\">{{brand.name}}</strong><p>{{reply}}</p>",
        payload: {
          feedbackTitle: "Save failed",
          reply: "We are looking into it."
        }
      }
    });
    expect(previewResponse.json().data).toEqual(
      expect.objectContaining({
        subject: "Zerx Lab Support feedback update: Save failed",
        html: "<strong style=\"color:#123456\">Stacio</strong><p>We are looking into it.</p>"
      })
    );

    const notificationResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/notifications",
      headers,
      payload: {
        type: "customer_feedback_reply",
        recipient: "user@example.com",
        priority: "normal",
        payload: {
          reply: "We are looking into it."
        }
      }
    });
    expect(notificationResponse.statusCode).toBe(201);
    const notificationId = notificationResponse.json().data.id;

    const forgedDeliveryResponse = await server.inject({
      method: "POST",
      url: `/api/v1/notifications/${notificationId}/deliveries`,
      headers,
      payload: {
        provider: "smtp",
        status: "sent",
        providerMessageId: "forged-message"
      }
    });
    expect(forgedDeliveryResponse.statusCode).toBe(404);

    const dryRunResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/notifications/${notificationId}/send`,
      headers,
      payload: {
        mode: "sync",
        dryRun: true
      }
    });
    expect(dryRunResponse.statusCode).toBe(200);
    expect(dryRunResponse.json().data.rendered).toEqual(
      expect.objectContaining({
        subject: "Zerx Lab Support feedback update: ",
        html: "<strong style=\"color:#123456\">Stacio</strong><p>We are looking into it.</p>",
        text: "Sent by Zerx Lab: We are looking into it."
      })
    );
    expect(await store.listNotificationDeliveries(notificationId)).toEqual([
      expect.objectContaining({
        status: "dry_run"
      })
    ]);

    const deliveriesResponse = await server.inject({
      method: "GET",
      url: `/api/v1/products/stacio/notifications/${notificationId}/deliveries`,
      headers
    });
    expect(deliveriesResponse.statusCode).toBe(200);
    expect(deliveriesResponse.json().data).toEqual([
      expect.objectContaining({
        notificationId,
        attempt: 1,
        status: "dry_run"
      })
    ]);

    const listResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/notifications",
      headers
    });
    expect(listResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: notificationId,
          status: "queued"
        })
      ])
    );
  });

  it("requires SEND confirmation before customer-visible notifications can be delivered", async () => {
    const jobQueue: OpsJobQueue = {
      async enqueueNotificationSend(payload) {
        return {
          id: "job_notification_confirmation",
          name: "notification.send",
          payload
        };
      },
      async enqueueGitHubPull(payload) {
        return {
          id: "job_github_unused",
          name: "github.pull",
          payload
        };
      }
    };
    const server = buildServer({ jobQueue });
    const headers = await ownerAuthorization(server);

    await server.inject({
      method: "PUT",
      url: "/api/v1/products/stacio/notification-templates/customer_feedback_reply",
      headers,
      payload: {
        subjectTemplate: "Stacio feedback update",
        htmlTemplate: "<p>{{reply}}</p>",
        textTemplate: "{{reply}}"
      }
    });
    const notificationResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/notifications",
      headers,
      payload: {
        type: "customer_feedback_reply",
        recipient: "user@example.com",
        payload: {
          reply: "We are looking into it."
        }
      }
    });
    const notificationId = notificationResponse.json().data.id;

    const rejected = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/notifications/${notificationId}/send`,
      headers,
      payload: {
        mode: "queue",
        dryRun: false
      }
    });
    expect(rejected.statusCode).toBe(409);
    expect(rejected.json()).toEqual(
      expect.objectContaining({
        error: expect.objectContaining({
          code: "MANUAL_CONFIRMATION_REQUIRED"
        })
      })
    );

    const accepted = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/notifications/${notificationId}/send`,
      headers,
      payload: {
        mode: "queue",
        dryRun: false,
        confirmation: "SEND"
      }
    });
    expect(accepted.statusCode).toBe(202);

    const dryRun = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/notifications/${notificationId}/send`,
      headers,
      payload: {
        mode: "queue",
        dryRun: true
      }
    });
    expect(dryRun.statusCode).toBe(202);
  });

  it("delays low-priority admin notifications during quiet hours but sends urgent admin alerts immediately", async () => {
    vi.stubEnv("NOTIFICATION_QUIET_HOURS_START", "22:00");
    vi.stubEnv("NOTIFICATION_QUIET_HOURS_END", "08:00");
    vi.stubEnv("NOTIFICATION_QUIET_HOURS_TIME_ZONE", "Asia/Shanghai");
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-07-10T14:30:00.000Z"));

    const enqueueNotificationSend = vi.fn(
      async (payload: unknown, options?: { delayMs?: number; scheduledFor?: string }) => ({
        id: options?.delayMs ? "job_notification_quiet" : "job_notification_immediate",
        name: "notification.send" as const,
        payload,
        delayMs: options?.delayMs,
        scheduledFor: options?.scheduledFor
      })
    );
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
    const server = buildServer({ jobQueue });
    const headers = await ownerAuthorization(server);

    const digestResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/notifications",
      headers,
      payload: {
        type: "admin_daily_feedback_digest",
        recipient: "ops@example.com",
        priority: "normal",
        payload: {
          summary: "Daily digest"
        }
      }
    });
    const digestId = digestResponse.json().data.id;

    const delayed = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/notifications/${digestId}/send`,
      headers,
      payload: {
        mode: "queue",
        dryRun: false,
        confirmation: "SEND"
      }
    });
    expect(delayed.statusCode).toBe(202);
    expect(enqueueNotificationSend).toHaveBeenCalledWith(
      expect.objectContaining({
        productId: "stacio",
        notificationId: digestId,
        dryRun: false
      }),
      {
        delayMs: 34_200_000,
        scheduledFor: "2026-07-11T00:00:00.000Z"
      }
    );

    const urgentResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/notifications",
      headers,
      payload: {
        type: "admin_p0_p1_bug_alert",
        recipient: "ops@example.com",
        priority: "urgent",
        payload: {
          feedbackTitle: "P0 crash"
        }
      }
    });
    const urgentId = urgentResponse.json().data.id;

    const immediate = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/notifications/${urgentId}/send`,
      headers,
      payload: {
        mode: "queue",
        dryRun: false,
        confirmation: "SEND"
      }
    });
    expect(immediate.statusCode).toBe(202);
    expect(enqueueNotificationSend).toHaveBeenLastCalledWith(
      expect.objectContaining({
        productId: "stacio",
        notificationId: urgentId,
        dryRun: false
      })
    );
  });
});
