import { createHash } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { FeedbackItem, GitHubIssueItem } from "../data/types.js";
import type {
  FeedbackRedactionField,
  OpsStore,
  UpdateFeedbackInput
} from "../data/store.js";
import type { OpsJobQueue } from "../jobs/queue.js";
import { notificationQuietHoursDelay } from "../services/notificationPolicy.js";
import type { PublicRateLimiter } from "../services/publicRateLimiter.js";
import { paginate, paginationQuerySchema } from "./pagination.js";

const feedbackTypes = [
  "bug",
  "feature",
  "question",
  "crash",
  "update_issue",
  "license_issue",
  "billing_issue",
  "other"
] as const;
const feedbackStatuses = [
  "new",
  "triaged",
  "in_progress",
  "waiting_for_user",
  "resolved",
  "closed",
  "duplicate"
] as const;
const feedbackPriorities = ["P0", "P1", "P2", "P3"] as const;

const createFeedbackSchema = z.object({
  title: z.string().trim().min(1).max(240),
  description: z.string().trim().min(1).max(50_000),
  type: z.enum(feedbackTypes).optional(),
  contactEmail: z.string().email().optional(),
  appVersion: z.string().max(80).optional(),
  buildNumber: z.string().max(80).optional(),
  osVersion: z.string().max(160).optional(),
  anonymousDeviceId: z.string().max(160).optional(),
  licenseState: z.string().trim().max(80).optional(),
  licenseKeyHash: z.string().max(255).optional(),
  diagnosticsSummary: z.record(z.string(), z.unknown()).optional()
});

const feedbackQuerySchema = paginationQuerySchema.extend({
  search: z.string().trim().optional(),
  type: z.enum(feedbackTypes).optional(),
  status: z.enum(feedbackStatuses).optional(),
  priority: z.enum(feedbackPriorities).optional(),
  source: z.enum(["app", "github", "admin"]).optional(),
  version: z.string().trim().optional(),
  licenseState: z.string().trim().optional(),
  createdFrom: z.string().trim().optional(),
  createdTo: z.string().trim().optional(),
  sort: z.enum(["newest", "priority", "last_activity", "version"]).default("newest")
});

const updateFeedbackSchema = z
  .object({
    status: z.enum(feedbackStatuses).optional(),
    priority: z.enum(feedbackPriorities).optional(),
    assignedUserId: z.string().max(64).nullable().optional(),
    duplicateOfId: z.string().max(64).nullable().optional(),
    relatedReleaseId: z.string().max(64).nullable().optional(),
    aiSummary: z.string().max(20_000).nullable().optional(),
    aiClassification: z.string().max(80).nullable().optional(),
    aiSuggestedPriority: z.enum(feedbackPriorities).nullable().optional()
  })
  .refine((value) => Object.keys(value).length > 0, "At least one field is required");

const batchUpdateSchema = z.object({
  feedbackIds: z.array(z.string().min(1)).min(1).max(200),
  changes: updateFeedbackSchema
});

const createCommentSchema = z.object({
  visibility: z.enum(["internal", "public"]),
  body: z.string().trim().min(1).max(50_000)
});

const createAttachmentSchema = z.object({
  objectKey: z.string().trim().min(1).max(2_000),
  fileName: z.string().trim().min(1).max(500),
  contentType: z.string().trim().min(1).max(255),
  sizeBytes: z.number().int().nonnegative(),
  sha256: z.string().regex(/^[a-f0-9]{64}$/i).optional()
});

const redactionFields = [
  "title",
  "description",
  "contactEmail",
  "diagnosticsSummary",
  "appVersion",
  "buildNumber",
  "osVersion",
  "licenseState",
  "licenseKeyHash",
  "anonymousDeviceId"
] as const satisfies readonly FeedbackRedactionField[];

const redactFeedbackSchema = z.object({
  confirmation: z.string().optional(),
  fields: z.array(z.enum(redactionFields)).min(1)
});

const confirmationSchema = z.object({
  confirmation: z.string().optional()
});

const githubLinkSchema = z.object({
  githubIssueId: z.string().trim().min(1).max(64)
});

const sendReplySchema = z.object({
  confirmation: z.string().optional(),
  body: z.string().trim().min(1).max(50_000),
  mode: z.enum(["queue"]).default("queue"),
  dryRun: z.boolean().optional()
});

function filterFeedback(
  items: FeedbackItem[],
  query: z.infer<typeof feedbackQuerySchema>,
  linkedGitHubIssuesByFeedbackId: Map<string, GitHubIssueItem[]> = new Map()
) {
  const search = query.search?.toLowerCase();
  const createdFrom = query.createdFrom ? dateBoundary(query.createdFrom, "start") : undefined;
  const createdTo = query.createdTo ? dateBoundary(query.createdTo, "end") : undefined;
  const filtered = items.filter((item) => {
    if (query.type && item.type !== query.type) return false;
    if (query.status && item.status !== query.status) return false;
    if (query.priority && item.priority !== query.priority) return false;
    if (query.source && item.source !== query.source) return false;
    if (query.version && item.appVersion !== query.version) return false;
    if (query.licenseState && item.licenseState !== query.licenseState) return false;
    const createdAt = new Date(item.createdAt).getTime();
    if (createdFrom !== undefined && createdAt < createdFrom) return false;
    if (createdTo !== undefined && createdAt > createdTo) return false;
    if (
      search &&
      ![
        item.title,
        item.description,
        item.contactEmail,
        item.appVersion,
        item.id,
        ...((linkedGitHubIssuesByFeedbackId.get(item.id) ?? []).flatMap((issue) => [
          String(issue.number),
          issue.title,
          issue.githubIssueId,
          issue.url
        ]))
      ]
        .filter(Boolean)
        .some((value) => value?.toLowerCase().includes(search))
    ) {
      return false;
    }
    return true;
  });

  const priorityRank: Record<FeedbackItem["priority"], number> = {
    P0: 0,
    P1: 1,
    P2: 2,
    P3: 3
  };
  return filtered.sort((left, right) => {
    if (query.sort === "priority") {
      return priorityRank[left.priority] - priorityRank[right.priority] || right.updatedAt.localeCompare(left.updatedAt);
    }
    if (query.sort === "version") {
      return (right.appVersion ?? "").localeCompare(left.appVersion ?? "") || right.updatedAt.localeCompare(left.updatedAt);
    }
    if (query.sort === "last_activity") {
      return right.updatedAt.localeCompare(left.updatedAt);
    }
    return right.createdAt.localeCompare(left.createdAt);
  });
}

function dateBoundary(value: string, edge: "start" | "end") {
  const source = /^\d{4}-\d{2}-\d{2}$/.test(value)
    ? `${value}T${edge === "start" ? "00:00:00.000" : "23:59:59.999"}Z`
    : value;
  const timestamp = new Date(source).getTime();
  return Number.isNaN(timestamp) ? undefined : timestamp;
}

function stableStringify(value: unknown): string {
  if (Array.isArray(value)) {
    return `[${value.map(stableStringify).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, entry]) => `${JSON.stringify(key)}:${stableStringify(entry)}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function idempotencyKeyFromHeaders(headers: Record<string, string | string[] | undefined>) {
  const value = headers["x-idempotency-key"];
  if (Array.isArray(value)) return value[0]?.trim();
  return value?.trim();
}

function publicFeedbackRequestHash(productId: string, payload: unknown) {
  return createHash("sha256")
    .update(`POST:/api/v1/public/products/${productId}/feedback:${stableStringify(payload)}`)
    .digest("hex");
}

async function auditFeedbackChange(
  store: OpsStore,
  request: {
    authPrincipal: { id: string } | null;
    ip: string;
    headers: Record<string, string | string[] | undefined>;
  },
  action: string,
  productId: string,
  targetId: string,
  beforeValue?: Record<string, unknown>,
  afterValue?: Record<string, unknown>
) {
  await store.createAuditLog({
    actorType: "user",
    actorId: request.authPrincipal?.id,
    action,
    targetType: "feedback",
    targetId,
    productId,
    beforeValue,
    afterValue,
    ipAddress: request.ip,
    userAgent: request.headers["user-agent"] as string | undefined
  });
}

async function enqueueCreatedNotification(
  jobQueue: OpsJobQueue | undefined,
  notification: { id: string; productId: string; type: string; priority: "low" | "normal" | "high" | "urgent" },
  notificationPolicy?: Parameters<typeof notificationQuietHoursDelay>[2]
) {
  if (!jobQueue) return;
  const payload = {
    productId: notification.productId,
    notificationId: notification.id,
    dryRun: false
  };
  const quietHoursDelay = notificationQuietHoursDelay(notification, new Date(), notificationPolicy);
  if (quietHoursDelay) {
    await jobQueue.enqueueNotificationSend(payload, quietHoursDelay);
    return;
  }
  await jobQueue.enqueueNotificationSend(payload);
}

async function queueFeedbackNotifications(
  store: OpsStore,
  jobQueue: OpsJobQueue | undefined,
  productId: string,
  feedback: FeedbackItem
) {
  const product = await store.findProduct(productId);
  if (!product) return;
  const notificationPolicy = await store.notificationPolicy(productId);

  const payload = {
    productName: product.name,
    feedbackId: feedback.id,
    feedbackTitle: feedback.title,
    contactEmail: feedback.contactEmail,
    priority: feedback.priority,
    type: feedback.type,
    appVersion: feedback.appVersion,
    buildNumber: feedback.buildNumber,
    source: feedback.source
  };

  if (feedback.contactEmail) {
    const customerNotification = await store.createNotification(productId, {
      type: "customer_feedback_received",
      recipient: feedback.contactEmail,
      priority: "normal",
      payload
    });
    if (customerNotification) {
      await enqueueCreatedNotification(jobQueue, customerNotification, notificationPolicy);
    }
  }

  const adminNotification = await store.createNotification(productId, {
    type: "admin_new_feedback",
    recipient: product.supportEmail,
    priority: "normal",
    payload
  });
  if (adminNotification) {
    await enqueueCreatedNotification(jobQueue, adminNotification, notificationPolicy);
  }

  const shouldAlert =
    ["P0", "P1"].includes(feedback.priority) &&
    ["bug", "crash", "update_issue"].includes(feedback.type);
  if (shouldAlert) {
    const alertNotification = await store.createNotification(productId, {
      type: "admin_p0_p1_bug_alert",
      recipient: product.supportEmail,
      priority: "high",
      payload
    });
    if (alertNotification) {
      await enqueueCreatedNotification(jobQueue, alertNotification, notificationPolicy);
    }
  }
}

async function queueFeedbackWebhook(
  jobQueue: OpsJobQueue | undefined,
  productId: string,
  feedback: FeedbackItem
) {
  if (!jobQueue?.enqueueWebhookDispatch) return;
  await jobQueue.enqueueWebhookDispatch({
    productId,
    eventType: "feedback.created",
    eventId: feedback.id,
    payload: {
      feedback: {
        id: feedback.id,
        title: feedback.title,
        description: feedback.description,
        type: feedback.type,
        priority: feedback.priority,
        status: feedback.status,
        source: feedback.source,
        contactEmail: feedback.contactEmail,
        appVersion: feedback.appVersion,
        buildNumber: feedback.buildNumber,
        osVersion: feedback.osVersion,
        licenseState: feedback.licenseState,
        anonymousDeviceId: feedback.anonymousDeviceId,
        createdAt: feedback.createdAt
      }
    }
  });
}

export async function registerFeedbackRoutes(
  server: FastifyInstance,
  store: OpsStore,
  publicRateLimiter: PublicRateLimiter,
  jobQueue?: OpsJobQueue
) {
  server.get<{
    Params: { productId: string };
    Querystring: Record<string, string | undefined>;
  }>(
    "/api/v1/products/:productId/feedback",
    {
      preHandler: server.authorize("feedback:read")
    },
    async (request, reply) => {
      const parsedQuery = feedbackQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid feedback query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      if (!(await store.findProduct(request.params.productId))) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Product not found"
          }
        });
      }

      const items = await store.listFeedback(request.params.productId);
      const linkedGitHubIssuesByFeedbackId = parsedQuery.data.search
        ? new Map(
            await Promise.all(
              items.map(async (item) => [
                item.id,
                await store.listLinkedGitHubIssues(request.params.productId, item.id)
              ] as const)
            )
          )
        : new Map<string, GitHubIssueItem[]>();

      const filtered = filterFeedback(items, parsedQuery.data, linkedGitHubIssuesByFeedbackId);
      const page = paginate(filtered, parsedQuery.data);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.post<{
    Params: { productId: string };
    Body: unknown;
  }>(
    "/api/v1/products/:productId/feedback/batch",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = batchUpdateSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid batch update",
            details: parsed.error.flatten()
          }
        });
      }

      const updated: FeedbackItem[] = [];
      for (const feedbackId of parsed.data.feedbackIds) {
        const before = await store.findFeedback(request.params.productId, feedbackId);
        if (!before) continue;
        const item = await store.updateFeedback(
          request.params.productId,
          feedbackId,
          parsed.data.changes as UpdateFeedbackInput
        );
        if (!item) continue;
        updated.push(item);
        await auditFeedbackChange(
          store,
          request,
          "feedback.batch_updated",
          request.params.productId,
          feedbackId,
          before as unknown as Record<string, unknown>,
          item as unknown as Record<string, unknown>
        );
      }

      return {
        ok: true,
        data: {
          requestedCount: parsed.data.feedbackIds.length,
          updatedCount: updated.length,
          items: updated
        }
      };
    }
  );

  server.get<{ Params: { productId: string; feedbackId: string } }>(
    "/api/v1/products/:productId/feedback/:feedbackId",
    {
      preHandler: server.authorize("feedback:read")
    },
    async (request, reply) => {
      const item = await store.findFeedback(request.params.productId, request.params.feedbackId);
      if (!item) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Feedback not found"
          }
        });
      }
      return {
        ok: true,
        data: {
          ...item,
          comments: await store.listFeedbackComments(item.id),
          attachments: await store.listFeedbackAttachments(item.id),
          linkedGitHubIssues: await store.listLinkedGitHubIssues(
            request.params.productId,
            item.id
          ),
          auditEvents: (await store.listAuditLogs(request.params.productId)).filter(
            (event) => event.targetType === "feedback" && event.targetId === item.id
          )
        }
      };
    }
  );

  server.patch<{ Params: { productId: string; feedbackId: string }; Body: unknown }>(
    "/api/v1/products/:productId/feedback/:feedbackId",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = updateFeedbackSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid feedback update",
            details: parsed.error.flatten()
          }
        });
      }
      const before = await store.findFeedback(request.params.productId, request.params.feedbackId);
      if (!before) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Feedback not found"
          }
        });
      }
      if (parsed.data.status === "duplicate" && !parsed.data.duplicateOfId) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "DUPLICATE_TARGET_REQUIRED",
            message: "A duplicate target is required when marking feedback as duplicate"
          }
        });
      }
      if (parsed.data.duplicateOfId) {
        if (parsed.data.duplicateOfId === request.params.feedbackId) {
          return reply.code(409).send({
            ok: false,
            error: {
              code: "INVALID_DUPLICATE_TARGET",
              message: "Feedback cannot be marked as a duplicate of itself"
            }
          });
        }
        const duplicateTarget = await store.findFeedback(
          request.params.productId,
          parsed.data.duplicateOfId
        );
        if (!duplicateTarget) {
          return reply.code(404).send({
            ok: false,
            error: {
              code: "DUPLICATE_TARGET_NOT_FOUND",
              message: "Duplicate target feedback not found"
            }
          });
        }
      }
      if (parsed.data.relatedReleaseId) {
        const relatedRelease = (await store.listReleases(request.params.productId)).find(
          (release) => release.id === parsed.data.relatedReleaseId
        );
        if (!relatedRelease) {
          return reply.code(404).send({
            ok: false,
            error: {
              code: "RELATED_RELEASE_NOT_FOUND",
              message: "Related release not found"
            }
          });
        }
      }
      const beforeSnapshot = structuredClone(before) as unknown as Record<string, unknown>;
      const item = await store.updateFeedback(
        request.params.productId,
        request.params.feedbackId,
        parsed.data as UpdateFeedbackInput
      );
      if (!item) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Feedback not found"
          }
        });
      }
      await auditFeedbackChange(
        store,
        request,
        parsed.data.status === "duplicate" && parsed.data.duplicateOfId
          ? "feedback.marked_duplicate"
          : parsed.data.relatedReleaseId !== undefined
            ? "feedback.related_release_linked"
            : parsed.data.assignedUserId !== undefined && Object.keys(parsed.data).length === 1
              ? "feedback.assigned"
          : "feedback.updated",
        request.params.productId,
        item.id,
        beforeSnapshot,
        item as unknown as Record<string, unknown>
      );
      return {
        ok: true,
        data: item
      };
    }
  );

  server.post<{ Params: { productId: string; feedbackId: string }; Body: unknown }>(
    "/api/v1/products/:productId/feedback/:feedbackId/comments",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = createCommentSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid feedback comment",
            details: parsed.error.flatten()
          }
        });
      }
      const feedback = await store.findFeedback(request.params.productId, request.params.feedbackId);
      if (!feedback) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Feedback not found"
          }
        });
      }

      const comment = await store.createFeedbackComment(feedback.id, {
        authorType: "user",
        authorId: request.authPrincipal?.id,
        visibility: parsed.data.visibility,
        body: parsed.data.body,
        deliveryStatus: parsed.data.visibility === "public" ? "draft" : "not_applicable"
      });
      if (!comment) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Feedback not found"
          }
        });
      }

      await auditFeedbackChange(
        store,
        request,
        parsed.data.visibility === "public" ? "feedback.reply_draft_created" : "feedback.internal_note_created",
        request.params.productId,
        feedback.id,
        undefined,
        {
          commentId: comment.id,
          visibility: comment.visibility
        }
      );
      return reply.code(201).send({
        ok: true,
        data: comment
      });
    }
  );

  server.post<{ Params: { productId: string; feedbackId: string }; Body: unknown }>(
    "/api/v1/products/:productId/feedback/:feedbackId/replies/send",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = sendReplySchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid feedback reply",
            details: parsed.error.flatten()
          }
        });
      }
      if (parsed.data.confirmation !== "SEND") {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CONFIRMATION_REQUIRED",
            message: "Type SEND to confirm this customer reply"
          }
        });
      }
      const feedback = await store.findFeedback(
        request.params.productId,
        request.params.feedbackId
      );
      if (!feedback) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Feedback not found" }
        });
      }
      const email = z.string().email().safeParse(feedback.contactEmail);
      if (!email.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "CONTACT_EMAIL_REQUIRED",
            message: "Feedback has no valid customer email"
          }
        });
      }
      if (!jobQueue) {
        return reply.code(503).send({
          ok: false,
          error: {
            code: "QUEUE_UNAVAILABLE",
            message: "Notification queue is unavailable"
          }
        });
      }

      const notification = await store.createNotification(request.params.productId, {
        type: "customer_feedback_reply",
        recipient: email.data,
        priority: feedback.priority === "P0" || feedback.priority === "P1" ? "high" : "normal",
        status: "queued",
        payload: {
          productId: request.params.productId,
          feedback: {
            id: feedback.id,
            title: feedback.title
          },
          reply: {
            body: parsed.data.body
          }
        }
      });
      if (!notification) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Product not found" }
        });
      }
      const comment = await store.createFeedbackComment(feedback.id, {
        authorType: "user",
        authorId: request.authPrincipal?.id,
        visibility: "public",
        body: parsed.data.body,
        notificationId: notification.id,
        deliveryStatus: "queued"
      });
      if (!comment) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Feedback not found" }
        });
      }
      const job = await jobQueue.enqueueNotificationSend({
        productId: request.params.productId,
        notificationId: notification.id,
        requestedBy: request.authPrincipal?.id,
        dryRun: parsed.data.dryRun
      });
      await auditFeedbackChange(
        store,
        request,
        "feedback.reply_queued",
        request.params.productId,
        feedback.id,
        undefined,
        {
          commentId: comment.id,
          notificationId: notification.id,
          jobId: job.id,
          dryRun: parsed.data.dryRun
        }
      );
      return reply.code(202).send({
        ok: true,
        data: {
          comment,
          notification,
          job
        }
      });
    }
  );

  server.post<{ Params: { productId: string; feedbackId: string }; Body: unknown }>(
    "/api/v1/products/:productId/feedback/:feedbackId/attachments",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = createAttachmentSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid feedback attachment",
            details: parsed.error.flatten()
          }
        });
      }
      const attachment = await store.createFeedbackAttachment(
        request.params.productId,
        request.params.feedbackId,
        parsed.data
      );
      if (!attachment) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Feedback not found" }
        });
      }
      await auditFeedbackChange(
        store,
        request,
        "feedback_attachment.registered",
        request.params.productId,
        request.params.feedbackId,
        undefined,
        {
          attachmentId: attachment.id,
          objectKey: attachment.objectKey,
          fileName: attachment.fileName,
          sizeBytes: attachment.sizeBytes
        }
      );
      return reply.code(201).send({ ok: true, data: attachment });
    }
  );

  server.post<{
    Params: { productId: string; feedbackId: string; attachmentId: string };
    Body: unknown;
  }>(
    "/api/v1/products/:productId/feedback/:feedbackId/attachments/:attachmentId/redact",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = confirmationSchema.safeParse(request.body ?? {});
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: { code: "VALIDATION_ERROR", message: "Invalid confirmation" }
        });
      }
      if (parsed.data.confirmation !== "REDACT") {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CONFIRMATION_REQUIRED",
            message: "Type REDACT to confirm attachment redaction"
          }
        });
      }
      const before = (await store.listFeedbackAttachments(request.params.feedbackId)).find(
        (item) => item.id === request.params.attachmentId
      );
      const attachment = await store.redactFeedbackAttachment(
        request.params.productId,
        request.params.feedbackId,
        request.params.attachmentId
      );
      if (!attachment) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Feedback attachment not found" }
        });
      }
      await auditFeedbackChange(
        store,
        request,
        "feedback_attachment.redacted",
        request.params.productId,
        request.params.feedbackId,
        before as unknown as Record<string, unknown> | undefined,
        attachment as unknown as Record<string, unknown>
      );
      return { ok: true, data: attachment };
    }
  );

  server.delete<{
    Params: { productId: string; feedbackId: string; attachmentId: string };
    Body: unknown;
  }>(
    "/api/v1/products/:productId/feedback/:feedbackId/attachments/:attachmentId",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = confirmationSchema.safeParse(request.body ?? {});
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: { code: "VALIDATION_ERROR", message: "Invalid confirmation" }
        });
      }
      if (parsed.data.confirmation !== "DELETE") {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CONFIRMATION_REQUIRED",
            message: "Type DELETE to confirm attachment deletion"
          }
        });
      }
      const before = (await store.listFeedbackAttachments(request.params.feedbackId)).find(
        (item) => item.id === request.params.attachmentId
      );
      const attachment = await store.deleteFeedbackAttachment(
        request.params.productId,
        request.params.feedbackId,
        request.params.attachmentId
      );
      if (!attachment) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Feedback attachment not found" }
        });
      }
      await auditFeedbackChange(
        store,
        request,
        "feedback_attachment.deleted",
        request.params.productId,
        request.params.feedbackId,
        before as unknown as Record<string, unknown> | undefined,
        attachment as unknown as Record<string, unknown>
      );
      return { ok: true, data: attachment };
    }
  );

  server.post<{ Params: { productId: string; feedbackId: string }; Body: unknown }>(
    "/api/v1/products/:productId/feedback/:feedbackId/redact",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = redactFeedbackSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid feedback redaction",
            details: parsed.error.flatten()
          }
        });
      }
      if (parsed.data.confirmation !== "REDACT") {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CONFIRMATION_REQUIRED",
            message: "Type REDACT to confirm feedback redaction"
          }
        });
      }
      const before = await store.findFeedback(
        request.params.productId,
        request.params.feedbackId
      );
      const beforeValue = before
        ? (structuredClone(before) as unknown as Record<string, unknown>)
        : undefined;
      const item = await store.redactFeedback(
        request.params.productId,
        request.params.feedbackId,
        parsed.data.fields
      );
      if (!item) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Feedback not found" }
        });
      }
      await auditFeedbackChange(
        store,
        request,
        "feedback.redacted",
        request.params.productId,
        request.params.feedbackId,
        beforeValue,
        item as unknown as Record<string, unknown>
      );
      return { ok: true, data: item };
    }
  );

  server.delete<{ Params: { productId: string; feedbackId: string }; Body: unknown }>(
    "/api/v1/products/:productId/feedback/:feedbackId",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = confirmationSchema.safeParse(request.body ?? {});
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: { code: "VALIDATION_ERROR", message: "Invalid confirmation" }
        });
      }
      if (parsed.data.confirmation !== "DELETE") {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CONFIRMATION_REQUIRED",
            message: "Type DELETE to confirm feedback deletion"
          }
        });
      }
      const before = await store.findFeedback(
        request.params.productId,
        request.params.feedbackId
      );
      const beforeValue = before
        ? (structuredClone(before) as unknown as Record<string, unknown>)
        : undefined;
      const item = await store.deleteFeedback(
        request.params.productId,
        request.params.feedbackId
      );
      if (!item) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Feedback not found" }
        });
      }
      await auditFeedbackChange(
        store,
        request,
        "feedback.deleted",
        request.params.productId,
        request.params.feedbackId,
        beforeValue,
        item as unknown as Record<string, unknown>
      );
      return { ok: true, data: item };
    }
  );

  server.post<{ Params: { productId: string; feedbackId: string }; Body: unknown }>(
    "/api/v1/products/:productId/feedback/:feedbackId/github-links",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = githubLinkSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid GitHub issue link",
            details: parsed.error.flatten()
          }
        });
      }
      const issue = await store.linkGitHubIssue(
        request.params.productId,
        request.params.feedbackId,
        parsed.data.githubIssueId,
        request.authPrincipal?.id
      );
      if (issue === "conflict") {
        return reply.code(409).send({
          ok: false,
          error: { code: "CONFLICT", message: "GitHub issue is already linked" }
        });
      }
      if (!issue) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Feedback or GitHub issue not found" }
        });
      }
      await auditFeedbackChange(
        store,
        request,
        "feedback.github_linked",
        request.params.productId,
        request.params.feedbackId,
        undefined,
        { githubIssueId: issue.id, number: issue.number }
      );
      return reply.code(201).send({ ok: true, data: issue });
    }
  );

  server.delete<{
    Params: { productId: string; feedbackId: string; githubIssueId: string };
    Body: unknown;
  }>(
    "/api/v1/products/:productId/feedback/:feedbackId/github-links/:githubIssueId",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = confirmationSchema.safeParse(request.body ?? {});
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: { code: "VALIDATION_ERROR", message: "Invalid confirmation" }
        });
      }
      if (parsed.data.confirmation !== "UNLINK") {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CONFIRMATION_REQUIRED",
            message: "Type UNLINK to confirm GitHub unlink"
          }
        });
      }
      const issue = await store.unlinkGitHubIssue(
        request.params.productId,
        request.params.feedbackId,
        request.params.githubIssueId
      );
      if (!issue) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Feedback link not found" }
        });
      }
      await auditFeedbackChange(
        store,
        request,
        "feedback.github_unlinked",
        request.params.productId,
        request.params.feedbackId,
        { githubIssueId: issue.id, number: issue.number },
        undefined
      );
      return { ok: true, data: issue };
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/public/products/:productId/feedback",
    async (request, reply) => {
      const apiKey = request.headers["x-product-api-key"];
      if (
        typeof apiKey !== "string" ||
        !(await store.verifyProductFeedbackApiKey(request.params.productId, apiKey))
      ) {
        return reply.code(401).send({
          ok: false,
          error: {
            code: "UNAUTHORIZED",
            message: "A valid product API key is required"
          }
        });
      }

      const parsed = createFeedbackSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid feedback payload",
            details: parsed.error.flatten()
          }
        });
      }

      const idempotencyKey = idempotencyKeyFromHeaders(request.headers);
      if (idempotencyKey && idempotencyKey.length > 200) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "X-Idempotency-Key must be 200 characters or fewer"
          }
        });
      }
      const idempotencyScope = `public-feedback:${request.params.productId}`;
      const requestHash = publicFeedbackRequestHash(request.params.productId, parsed.data);
      if (idempotencyKey) {
        const existing = await store.findIdempotencyRecord(idempotencyScope, idempotencyKey);
        if (existing) {
          if (existing.requestHash !== requestHash) {
            return reply.code(409).send({
              ok: false,
              error: {
                code: "IDEMPOTENCY_CONFLICT",
                message: "Idempotency key was already used with a different payload"
              }
            });
          }
          return reply.code(existing.statusCode).send(existing.responseBody);
        }
      }

      const rateLimit = publicRateLimiter.consume([request.params.productId, apiKey, request.ip]);
      reply.header("X-RateLimit-Remaining", String(rateLimit.remaining));
      if (!rateLimit.allowed) {
        reply.header("Retry-After", String(rateLimit.retryAfterSeconds));
        return reply.code(429).send({
          ok: false,
          error: {
            code: "RATE_LIMITED",
            message: "Too many feedback submissions. Try again later."
          }
        });
      }

      const item = await store.createFeedback(request.params.productId, parsed.data);
      if (!item) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Product not found"
          }
        });
      }

      await store.createAuditLog({
        actorType: "public",
        action: "feedback.created",
        targetType: "feedback",
        targetId: item.id,
        productId: request.params.productId,
        ipAddress: request.ip,
        userAgent: request.headers["user-agent"],
        afterValue: {
          title: item.title,
          type: item.type,
          priority: item.priority,
          source: item.source
        }
      });

      await queueFeedbackNotifications(store, jobQueue, request.params.productId, item);
      await queueFeedbackWebhook(jobQueue, request.params.productId, item);

      const responseBody = {
        ok: true,
        data: item,
        message: "Feedback received."
      };
      if (idempotencyKey) {
        await store.createIdempotencyRecord({
          scope: idempotencyScope,
          key: idempotencyKey,
          requestHash,
          statusCode: 201,
          responseBody,
          expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString()
        });
      }

      return reply.code(201).send(responseBody);
    }
  );
}
