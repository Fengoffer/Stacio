import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import { PGlite } from "@electric-sql/pglite";
import { drizzle } from "drizzle-orm/pglite";
import { afterEach, describe, expect, it, vi } from "vitest";
import { hashPassword } from "../src/auth/password.js";
import { createPostgresAuthStore, developmentOwnerCredentials } from "../src/auth/store.js";
import { userRoles, users } from "../src/db/schema.js";
import { seedDatabase } from "../src/db/seed.js";
import { createPostgresStore } from "../src/data/postgresStore.js";
import type { OpsDatabase } from "../src/db/database.js";
import * as schema from "../src/db/schema.js";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

const portdeskPayload = {
  id: "portdesk",
  name: "PortDesk",
  platform: "macOS",
  bundleId: "com.zerxlab.portdesk",
  supportEmail: "support@example.com",
  githubOwner: "zerx-lab",
  githubRepository: "portdesk",
  updateBaseUrl: "https://updates.example.com/portdesk",
  appcastBaseUrl: "https://updates.example.com/portdesk",
  objectStoragePrefix: "products/portdesk",
  licensePolicy: {
    defaultOfflineGraceDays: 14
  },
  emailBrand: {
    name: "PortDesk",
    accentColor: "#15A05C"
  }
};

async function syncGitHubIssue(
  server: ReturnType<typeof buildServer>,
  headers: Record<string, string>,
  productId: string,
  issueId: string,
  number: number
) {
  const response = await server.inject({
    method: "POST",
    url: `/api/v1/products/${productId}/github/sync`,
    headers,
    payload: {
      trigger: "manual",
      issues: [
        {
          githubIssueId: issueId,
          number,
          title: `GitHub issue ${number}`,
          body: `Imported issue ${number}`,
          labels: ["bug"],
          author: "octocat",
          state: "open",
          commentsCount: 1,
          url: `https://github.com/example/${productId}/issues/${number}`
        }
      ]
    }
  });
  expect(response.statusCode).toBe(200);
  return response.json().data.issues[0] as { id: string };
}

async function bootstrapPostgresDatabase() {
  const client = new PGlite();
  const migrationsDirectory = resolve(process.cwd(), "apps/api/drizzle");
  const migrationFiles = readdirSync(migrationsDirectory)
    .filter((file) => file.endsWith(".sql"))
    .sort();
  for (const migrationFile of migrationFiles) {
    const migrationSql = readFileSync(resolve(migrationsDirectory, migrationFile), "utf8").replaceAll(
      "--> statement-breakpoint",
      ""
    );
    await client.exec(migrationSql);
  }

  const database = drizzle(client, { schema }) as unknown as OpsDatabase;
  await seedDatabase(database);
  await database.insert(users).values({
    id: "usr_development_owner",
    email: developmentOwnerCredentials.email,
    name: "Development Owner",
    passwordHash: await hashPassword(developmentOwnerCredentials.password),
    status: "active"
  });
  await database.insert(userRoles).values({
    id: "user_role_development_owner",
    userId: "usr_development_owner",
    roleId: "role_owner"
  });

  return { client, database };
}

describe("feedback closure workflow", () => {
  let postgresClient: PGlite | undefined;

  afterEach(async () => {
    await postgresClient?.close();
    postgresClient = undefined;
  });

  it("manages attachments, redaction, GitHub links, customer replies, soft deletion and audit records", async () => {
    const jobQueue = {
      enqueueNotificationSend: vi.fn(async (payload: unknown) => ({
        id: "job_feedback_reply_1",
        name: "notification.send" as const,
        payload
      })),
      enqueueGitHubPull: vi.fn()
    };
    const server = buildServer({ jobQueue });
    const headers = await ownerAuthorization(server);

    await server.inject({
      method: "PUT",
      url: "/api/v1/products/stacio/notification-templates/customer_feedback_reply",
      headers,
      payload: {
        subjectTemplate: "Stacio 回复: {{feedback.title}}",
        htmlTemplate: "<p>{{reply.body}}</p>",
        textTemplate: "{{reply.body}}"
      }
    });

    const draftResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/comments",
      headers,
      payload: {
        visibility: "public",
        body: "这是客户可见回复草稿，但不能自动发送。"
      }
    });
    expect(draftResponse.statusCode).toBe(201);
    expect(draftResponse.json().data).toEqual(
      expect.objectContaining({
        visibility: "public",
        deliveryStatus: "draft"
      })
    );
    expect(jobQueue.enqueueNotificationSend).not.toHaveBeenCalled();
    expect(
      (
        await server.inject({
          method: "GET",
          url: "/api/v1/products/stacio/notifications",
          headers
        })
      )
        .json()
        .data.filter((item: { type: string }) => item.type === "customer_feedback_reply")
    ).toHaveLength(0);

    const sendWithoutConfirmation = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/replies/send",
      headers,
      payload: {
        body: "缺少确认，不允许发送。"
      }
    });
    expect(sendWithoutConfirmation.statusCode).toBe(409);

    const sendResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/replies/send",
      headers,
      payload: {
        confirmation: "SEND",
        body: "我们已经确认这个问题，会在下个版本修复。",
        mode: "queue",
        dryRun: true
      }
    });
    expect(sendResponse.statusCode).toBe(202);
    expect(sendResponse.json().data).toEqual(
      expect.objectContaining({
        comment: expect.objectContaining({
          visibility: "public",
          notificationId: expect.stringMatching(/^ntf_/),
          deliveryStatus: "queued"
        }),
        notification: expect.objectContaining({
          type: "customer_feedback_reply",
          recipient: "ops-user@example.com",
          status: "queued"
        }),
        job: expect.objectContaining({
          id: "job_feedback_reply_1",
          name: "notification.send"
        })
      })
    );
    expect(jobQueue.enqueueNotificationSend).toHaveBeenCalledWith({
      productId: "stacio",
      notificationId: sendResponse.json().data.notification.id,
      requestedBy: expect.any(String),
      dryRun: true
    });

    const attachmentResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/attachments",
      headers,
      payload: {
        objectKey: "products/stacio/feedback/fb_001/diagnostics.log",
        fileName: "diagnostics.log",
        contentType: "text/plain",
        sizeBytes: 1200,
        sha256: "a".repeat(64)
      }
    });
    expect(attachmentResponse.statusCode).toBe(201);
    const attachmentId = attachmentResponse.json().data.id as string;

    const redactAttachmentWithoutConfirmation = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/feedback/fb_001/attachments/${attachmentId}/redact`,
      headers,
      payload: {}
    });
    expect(redactAttachmentWithoutConfirmation.statusCode).toBe(409);

    const redactedAttachment = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/feedback/fb_001/attachments/${attachmentId}/redact`,
      headers,
      payload: {
        confirmation: "REDACT"
      }
    });
    expect(redactedAttachment.statusCode).toBe(200);
    expect(redactedAttachment.json().data).toEqual(
      expect.objectContaining({
        id: attachmentId,
        objectKey: `redacted://feedback-attachment/${attachmentId}`,
        fileName: "[redacted attachment]",
        contentType: "application/octet-stream",
        sizeBytes: 0,
        redactedAt: expect.any(String)
      })
    );

    const deleteAttachmentWithoutConfirmation = await server.inject({
      method: "DELETE",
      url: `/api/v1/products/stacio/feedback/fb_001/attachments/${attachmentId}`,
      headers,
      payload: {}
    });
    expect(deleteAttachmentWithoutConfirmation.statusCode).toBe(409);

    const deletedAttachment = await server.inject({
      method: "DELETE",
      url: `/api/v1/products/stacio/feedback/fb_001/attachments/${attachmentId}`,
      headers,
      payload: {
        confirmation: "DELETE"
      }
    });
    expect(deletedAttachment.statusCode).toBe(200);
    expect(deletedAttachment.json().data).toEqual(
      expect.objectContaining({
        id: attachmentId,
        deletedAt: expect.any(String)
      })
    );

    const stacioIssue = await syncGitHubIssue(server, headers, "stacio", "manual-link-1", 301);
    const linkedIssue = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/github-links",
      headers,
      payload: {
        githubIssueId: stacioIssue.id
      }
    });
    expect(linkedIssue.statusCode).toBe(201);

    const duplicateLink = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/github-links",
      headers,
      payload: {
        githubIssueId: stacioIssue.id
      }
    });
    expect(duplicateLink.statusCode).toBe(409);

    await server.inject({
      method: "POST",
      url: "/api/v1/products",
      headers,
      payload: portdeskPayload
    });
    const portdeskIssue = await syncGitHubIssue(server, headers, "portdesk", "manual-link-2", 401);
    const crossProductLink = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/github-links",
      headers,
      payload: {
        githubIssueId: portdeskIssue.id
      }
    });
    expect(crossProductLink.statusCode).toBe(404);

    const detailWithLinks = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers
    });
    expect(detailWithLinks.statusCode).toBe(200);
    expect(detailWithLinks.json().data).toEqual(
      expect.objectContaining({
        comments: expect.arrayContaining([
          expect.objectContaining({ deliveryStatus: "draft" }),
          expect.objectContaining({ deliveryStatus: "queued" })
        ]),
        attachments: [],
        linkedGitHubIssues: [
          expect.objectContaining({
            id: stacioIssue.id,
            number: 301
          })
        ]
      })
    );

    const unlinkWithoutConfirmation = await server.inject({
      method: "DELETE",
      url: `/api/v1/products/stacio/feedback/fb_001/github-links/${stacioIssue.id}`,
      headers,
      payload: {}
    });
    expect(unlinkWithoutConfirmation.statusCode).toBe(409);

    const unlinkedIssue = await server.inject({
      method: "DELETE",
      url: `/api/v1/products/stacio/feedback/fb_001/github-links/${stacioIssue.id}`,
      headers,
      payload: {
        confirmation: "UNLINK"
      }
    });
    expect(unlinkedIssue.statusCode).toBe(200);

    const redactionWithoutConfirmation = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/redact",
      headers,
      payload: {
        fields: ["description"]
      }
    });
    expect(redactionWithoutConfirmation.statusCode).toBe(409);

    const redactedFeedback = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/redact",
      headers,
      payload: {
        confirmation: "REDACT",
        fields: ["title", "description", "contactEmail", "diagnosticsSummary"]
      }
    });
    expect(redactedFeedback.statusCode).toBe(200);
    expect(redactedFeedback.json().data).toEqual(
      expect.objectContaining({
        title: "[redacted feedback title]",
        description: "[redacted feedback description]",
        contactEmail: "redacted@example.invalid",
        diagnosticsSummary: {
          redacted: true
        }
      })
    );

    const deleteWithoutConfirmation = await server.inject({
      method: "DELETE",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers,
      payload: {}
    });
    expect(deleteWithoutConfirmation.statusCode).toBe(409);

    const deletedFeedback = await server.inject({
      method: "DELETE",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers,
      payload: {
        confirmation: "DELETE"
      }
    });
    expect(deletedFeedback.statusCode).toBe(200);
    expect(deletedFeedback.json().data).toEqual(
      expect.objectContaining({
        id: "fb_001",
        deletedAt: expect.any(String)
      })
    );

    const listAfterDelete = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback",
      headers
    });
    expect(listAfterDelete.json().data.map((item: { id: string }) => item.id)).not.toContain("fb_001");

    const detailAfterDelete = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers
    });
    expect(detailAfterDelete.statusCode).toBe(404);

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio",
      headers
    });
    const actions = auditResponse.json().data.map((item: { action: string }) => item.action);
    expect(actions).toEqual(
      expect.arrayContaining([
        "feedback.reply_draft_created",
        "feedback.reply_queued",
        "feedback_attachment.registered",
        "feedback_attachment.redacted",
        "feedback_attachment.deleted",
        "feedback.github_linked",
        "feedback.github_unlinked",
        "feedback.redacted",
        "feedback.deleted"
      ])
    );
  });

  it("rejects confirmed customer replies when feedback has no valid contact email", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);
    const keyResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback-api-key/rotate",
      headers,
      payload: {
        confirmation: "ROTATE"
      }
    });
    const feedbackApiKey = keyResponse.json().data.feedbackApiKey as string;
    const feedbackResponse = await server.inject({
      method: "POST",
      url: "/api/v1/public/products/stacio/feedback",
      headers: {
        "x-product-api-key": feedbackApiKey
      },
      payload: {
        title: "No contact email",
        description: "This submitter did not provide an email address.",
        type: "question"
      }
    });
    expect(feedbackResponse.statusCode).toBe(201);

    const sendResponse = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/feedback/${feedbackResponse.json().data.id}/replies/send`,
      headers,
      payload: {
        confirmation: "SEND",
        body: "This should not be queued."
      }
    });

    expect(sendResponse.statusCode).toBe(422);
    expect(sendResponse.json().error.code).toBe("CONTACT_EMAIL_REQUIRED");
  });

  it("persists feedback attachments, links, reply notification state and soft deletion in PostgreSQL", async () => {
    const bootstrapped = await bootstrapPostgresDatabase();
    postgresClient = bootstrapped.client;
    const jobQueue = {
      enqueueNotificationSend: vi.fn(async (payload: unknown) => ({
        id: "job_pg_feedback_reply",
        name: "notification.send" as const,
        payload
      })),
      enqueueGitHubPull: vi.fn()
    };
    const server = buildServer({
      store: createPostgresStore(bootstrapped.database),
      authStore: createPostgresAuthStore(bootstrapped.database),
      jobQueue
    });
    const headers = await ownerAuthorization(server);

    const attachmentResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/attachments",
      headers,
      payload: {
        objectKey: "products/stacio/feedback/fb_001/postgres.log",
        fileName: "postgres.log",
        contentType: "text/plain",
        sizeBytes: 2048
      }
    });
    expect(attachmentResponse.statusCode).toBe(201);

    const issue = await syncGitHubIssue(server, headers, "stacio", "postgres-link-1", 501);
    const linkResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/github-links",
      headers,
      payload: {
        githubIssueId: issue.id
      }
    });
    expect(linkResponse.statusCode).toBe(201);

    const replyResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/replies/send",
      headers,
      payload: {
        confirmation: "SEND",
        body: "PostgreSQL persisted reply.",
        mode: "queue"
      }
    });
    expect(replyResponse.statusCode).toBe(202);

    const reloadedServer = buildServer({
      store: createPostgresStore(bootstrapped.database),
      authStore: createPostgresAuthStore(bootstrapped.database),
      jobQueue
    });
    const reloadedHeaders = await ownerAuthorization(reloadedServer);
    const detailResponse = await reloadedServer.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers: reloadedHeaders
    });
    expect(detailResponse.statusCode).toBe(200);
    expect(detailResponse.json().data).toEqual(
      expect.objectContaining({
        attachments: [
          expect.objectContaining({
            fileName: "postgres.log",
            sizeBytes: 2048
          })
        ],
        linkedGitHubIssues: expect.arrayContaining([
          expect.objectContaining({
            id: issue.id,
            number: 501
          })
        ]),
        comments: expect.arrayContaining([
          expect.objectContaining({
            body: "PostgreSQL persisted reply.",
            notificationId: expect.stringMatching(/^ntf_/),
            deliveryStatus: "queued"
          })
        ])
      })
    );

    const deleteResponse = await reloadedServer.inject({
      method: "DELETE",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers: reloadedHeaders,
      payload: {
        confirmation: "DELETE"
      }
    });
    expect(deleteResponse.statusCode).toBe(200);

    const hiddenListResponse = await reloadedServer.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback",
      headers: reloadedHeaders
    });
    expect(hiddenListResponse.json().data.map((item: { id: string }) => item.id)).not.toContain("fb_001");

    const hiddenDetailResponse = await reloadedServer.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback/fb_001",
      headers: reloadedHeaders
    });
    expect(hiddenDetailResponse.statusCode).toBe(404);
  });
});
