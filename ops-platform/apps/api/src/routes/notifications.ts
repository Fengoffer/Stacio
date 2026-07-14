import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { OpsStore } from "../data/store.js";
import type { OpsJobQueue } from "../jobs/queue.js";
import { sendSmtpMail, SmtpConfigurationError } from "../services/smtpMailer.js";
import { notificationQuietHoursDelay } from "../services/notificationPolicy.js";
import { buildNotificationTemplatePayload } from "../services/notificationTemplateContext.js";
import { renderTemplate } from "../services/templateRenderer.js";
import { paginate, paginationQuerySchema } from "./pagination.js";

const templateSchema = z.object({
  type: z.string().min(1).max(80),
  subjectTemplate: z.string().min(1).max(500),
  htmlTemplate: z.string().min(1).max(50_000),
  textTemplate: z.string().max(50_000).optional(),
  status: z.enum(["active", "disabled"]).optional()
});

const previewSchema = z.object({
  productId: z.string().min(1).max(64).optional(),
  subjectTemplate: z.string().min(1).max(500),
  htmlTemplate: z.string().min(1).max(50_000),
  textTemplate: z.string().max(50_000).optional(),
  payload: z.record(z.string(), z.unknown()).default({})
});

const notificationSchema = z.object({
  type: z.string().min(1).max(80),
  recipient: z.string().email(),
  payload: z.record(z.string(), z.unknown()).default({}),
  priority: z.enum(["low", "normal", "high", "urgent"]).optional(),
  status: z.enum(["queued", "sent", "failed", "draft"]).optional(),
  scheduledAt: z.string().datetime().optional()
});

const notificationListQuerySchema = paginationQuerySchema.extend({
  type: z.string().trim().optional(),
  status: z.enum(["queued", "sent", "failed", "draft"]).optional(),
  priority: z.enum(["low", "normal", "high", "urgent"]).optional(),
  search: z.string().trim().optional()
});

const notificationTemplateListQuerySchema = paginationQuerySchema;
const notificationDeliveryListQuerySchema = paginationQuerySchema;

const dailyFeedbackDigestSchema = z.object({
  recipient: z.string().email(),
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional()
});

const licenseExpiringReminderSchema = z.object({
  days: z.number().int().positive().max(120).default(30),
  referenceDate: z.string().datetime().optional()
});

const notificationPolicySchema = z.object({
  quietHoursEnabled: z.boolean(),
  quietHoursStart: z.string().regex(/^\d{2}:\d{2}$/),
  quietHoursEnd: z.string().regex(/^\d{2}:\d{2}$/),
  quietHoursTimeZone: z.string().trim().min(1).max(80)
});

const sendNotificationSchema = z.object({
  mode: z.enum(["sync", "queue"]).default("sync"),
  dryRun: z.boolean().optional(),
  confirmation: z.string().optional()
});

const priorityRank: Record<string, number> = {
  P0: 0,
  P1: 1,
  P2: 2,
  P3: 3
};
const dayMs = 86_400_000;

function digestDate(value?: string) {
  return value ?? new Date().toISOString().slice(0, 10);
}

async function buildDailyFeedbackDigestPayload(store: OpsStore, productId: string, date: string) {
  const feedback = (await store.listFeedback(productId)).filter((item) => item.createdAt.startsWith(date));
  const newCount = feedback.filter((item) => item.status === "new").length;
  const unhandledCount = feedback.filter((item) => !["resolved", "closed", "duplicate"].includes(item.status)).length;
  const p0p1Count = feedback.filter((item) => ["P0", "P1"].includes(item.priority)).length;
  const resolvedCount = feedback.filter((item) => ["resolved", "closed"].includes(item.status)).length;
  const topFeedback = [...feedback]
    .sort((left, right) => (priorityRank[left.priority] ?? 99) - (priorityRank[right.priority] ?? 99))
    .slice(0, 5)
    .map((item) => ({
      id: item.id,
      title: item.title,
      type: item.type,
      priority: item.priority,
      status: item.status,
      source: item.source,
      appVersion: item.appVersion,
      contactEmail: item.contactEmail
    }));

  return {
    date,
    summary: `${date} 共 ${feedback.length} 条反馈，${newCount} 条新反馈，${p0p1Count} 条 P0/P1，${resolvedCount} 条已解决。`,
    metrics: {
      totalCount: feedback.length,
      newCount,
      unhandledCount,
      p0p1Count,
      resolvedCount
    },
    topFeedback
  };
}

function licenseDaysRemaining(expiresAt: string, referenceDate: Date) {
  return Math.ceil((new Date(expiresAt).getTime() - referenceDate.getTime()) / dayMs);
}

async function enqueueNotificationSend(
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

export async function registerNotificationRoutes(server: FastifyInstance, store: OpsStore, jobQueue?: OpsJobQueue) {
  server.get<{ Params: { productId: string } }>(
    "/api/v1/products/:productId/notification-policy",
    {
      preHandler: server.authorize("products:read")
    },
    async (request, reply) => {
      const policy = await store.notificationPolicy(request.params.productId);
      if (!policy) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Product not found" } });
      }
      return { ok: true, data: policy };
    }
  );

  server.patch<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId/notification-policy",
    {
      preHandler: server.authorize("products:write")
    },
    async (request, reply) => {
      const parsed = notificationPolicySchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid notification policy",
            details: parsed.error.flatten()
          }
        });
      }

      const before = await store.notificationPolicy(request.params.productId);
      const policy = await store.updateNotificationPolicy(request.params.productId, parsed.data);
      if (!policy) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Product not found" } });
      }

      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "notification_policy.updated",
        targetType: "notification_policy",
        targetId: request.params.productId,
        productId: request.params.productId,
        beforeValue: before
          ? {
              quietHoursEnabled: before.quietHoursEnabled,
              quietHoursStart: before.quietHoursStart,
              quietHoursEnd: before.quietHoursEnd,
              quietHoursTimeZone: before.quietHoursTimeZone
            }
          : undefined,
        afterValue: {
          quietHoursEnabled: policy.quietHoursEnabled,
          quietHoursStart: policy.quietHoursStart,
          quietHoursEnd: policy.quietHoursEnd,
          quietHoursTimeZone: policy.quietHoursTimeZone
        }
      });

      return { ok: true, data: policy };
    }
  );

  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/notification-templates",
    {
      preHandler: server.authorize("products:read")
    },
    async (request, reply) => {
      const parsedQuery = notificationTemplateListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid notification template query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const page = paginate(await store.listNotificationTemplates(request.params.productId), parsedQuery.data);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.put<{ Params: { productId: string; type: string }; Body: unknown }>(
    "/api/v1/products/:productId/notification-templates/:type",
    {
      preHandler: server.authorize("products:write")
    },
    async (request, reply) => {
      const parsed = templateSchema.safeParse({
        ...(request.body as Record<string, unknown>),
        type: request.params.type
      });
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid notification template",
            details: parsed.error.flatten()
          }
        });
      }
      const template = await store.upsertNotificationTemplate(request.params.productId, parsed.data);
      if (!template) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Product not found" } });
      }
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "notification_template.upserted",
        targetType: "notification_template",
        targetId: template.id,
        productId: request.params.productId,
        afterValue: {
          type: template.type,
          status: template.status
        }
      });
      return { ok: true, data: template };
    }
  );

  server.post<{ Body: unknown }>(
    "/api/v1/notification-templates/preview",
    {
      preHandler: server.authorize("products:read")
    },
    async (request, reply) => {
      const parsed = previewSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid notification preview",
            details: parsed.error.flatten()
          }
        });
      }
      const templatePayload = parsed.data.productId
        ? await buildNotificationTemplatePayload(store, parsed.data.productId, parsed.data.payload)
        : parsed.data.payload;
      return {
        ok: true,
        data: {
          subject: renderTemplate(parsed.data.subjectTemplate, templatePayload),
          html: renderTemplate(parsed.data.htmlTemplate, templatePayload),
          text: parsed.data.textTemplate ? renderTemplate(parsed.data.textTemplate, templatePayload) : undefined
        }
      };
    }
  );

  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/notifications",
    {
      preHandler: server.authorize("products:read")
    },
    async (request, reply) => {
      const parsedQuery = notificationListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid notification query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const query = parsedQuery.data;
      const search = query.search?.toLowerCase();
      const notifications = (await store.listNotifications(request.params.productId)).filter((notification) => {
        if (query.type && notification.type !== query.type) return false;
        if (query.status && notification.status !== query.status) return false;
        if (query.priority && notification.priority !== query.priority) return false;
        if (
          search &&
          ![notification.id, notification.type, notification.recipient, JSON.stringify(notification.payload ?? {})]
            .filter(Boolean)
            .some((value) => value?.toLowerCase().includes(search))
        ) {
          return false;
        }
        return true;
      });
      const page = paginate(notifications, query);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId/notifications",
    {
      preHandler: server.authorize("products:write")
    },
    async (request, reply) => {
      const parsed = notificationSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid notification",
            details: parsed.error.flatten()
          }
        });
      }
      const notification = await store.createNotification(request.params.productId, parsed.data);
      if (!notification) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Product not found" } });
      }
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "notification.queued",
        targetType: "notification",
        targetId: notification.id,
        productId: request.params.productId,
        afterValue: {
          type: notification.type,
          recipient: notification.recipient,
          priority: notification.priority
        }
      });
      return reply.code(201).send({ ok: true, data: notification });
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId/notifications/daily-feedback-digest",
    {
      preHandler: server.authorize("products:write")
    },
    async (request, reply) => {
      const parsed = dailyFeedbackDigestSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid daily feedback digest payload",
            details: parsed.error.flatten()
          }
        });
      }

      const date = digestDate(parsed.data.date);
      const payload = await buildDailyFeedbackDigestPayload(store, request.params.productId, date);
      const notification = await store.createNotification(request.params.productId, {
        type: "admin_daily_feedback_digest",
        recipient: parsed.data.recipient,
        payload,
        priority: "normal",
        status: "queued"
      });
      if (!notification) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Product not found" } });
      }

      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "notification.digest_created",
        targetType: "notification",
        targetId: notification.id,
        productId: request.params.productId,
        afterValue: {
          type: notification.type,
          recipient: notification.recipient,
          date,
          totalCount: payload.metrics.totalCount
        }
      });
      const notificationPolicy = await store.notificationPolicy(request.params.productId);
      await enqueueNotificationSend(jobQueue, notification, notificationPolicy);

      return reply.code(201).send({
        ok: true,
        data: notification,
        policy: {
          emailSent: false,
          queuedOnly: true,
          quietHoursEligible: true
        }
      });
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId/notifications/license-expiring",
    {
      preHandler: server.authorize("products:write")
    },
    async (request, reply) => {
      const parsed = licenseExpiringReminderSchema.safeParse(request.body ?? {});
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid license expiring reminder payload",
            details: parsed.error.flatten()
          }
        });
      }

      const product = await store.findProduct(request.params.productId);
      if (!product) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Product not found" } });
      }

      const referenceDate = parsed.data.referenceDate ? new Date(parsed.data.referenceDate) : new Date();
      const cutoffDate = new Date(referenceDate.getTime() + parsed.data.days * dayMs);
      const licenses = await store.listLicenses(request.params.productId);
      const existingExpiringNotifications = (await store.listNotifications(request.params.productId)).filter(
        (notification) => notification.type === "customer_license_expiring" && notification.status !== "failed"
      );
      const expiringLicenses = licenses.filter((license) => {
        if (!["active", "trial"].includes(license.status)) return false;
        const expiresAt = new Date(license.expiresAt).getTime();
        return expiresAt >= referenceDate.getTime() && expiresAt <= cutoffDate.getTime();
      });

      const created = [];
      const skipped = [];
      for (const license of expiringLicenses) {
        const existingNotification = existingExpiringNotifications.find(
          (notification) =>
            notification.payload.licenseId === license.id &&
            notification.payload.expiresAt === license.expiresAt
        );
        if (existingNotification) {
          skipped.push({
            licenseId: license.id,
            recipient: license.customerEmail,
            reason: "already_queued",
            notificationId: existingNotification.id
          });
          continue;
        }
        const notification = await store.createNotification(request.params.productId, {
          type: "customer_license_expiring",
          recipient: license.customerEmail,
          priority: "normal",
          status: "queued",
          payload: {
            licenseId: license.id,
            customerName: license.customerName,
            email: license.customerEmail,
            plan: license.plan,
            status: license.status,
            expiresAt: license.expiresAt,
            daysRemaining: licenseDaysRemaining(license.expiresAt, referenceDate)
          }
        });
        if (notification) {
          created.push(notification);
        }
      }

      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "notification.license_expiring_created",
        targetType: "notification_batch",
        targetId: request.params.productId,
        productId: request.params.productId,
        afterValue: {
          days: parsed.data.days,
          referenceDate: referenceDate.toISOString(),
          cutoffDate: cutoffDate.toISOString(),
          scannedCount: licenses.length,
          createdCount: created.length,
          skippedCount: skipped.length,
          licenseIds: created.map((notification) => notification.payload.licenseId)
        }
      });
      const notificationPolicy = await store.notificationPolicy(request.params.productId);
      for (const notification of created) {
        await enqueueNotificationSend(jobQueue, notification, notificationPolicy);
      }

      return reply.code(201).send({
        ok: true,
        data: {
          scannedCount: licenses.length,
          createdCount: created.length,
          skippedCount: skipped.length,
          window: {
            referenceDate: referenceDate.toISOString(),
            days: parsed.data.days,
            cutoffDate: cutoffDate.toISOString()
          },
          created,
          skipped
        },
        policy: {
          emailSent: false,
          queuedOnly: true,
          customerVisible: true
        }
      });
    }
  );

  server.post<{ Params: { productId: string; notificationId: string }; Body: unknown }>(
    "/api/v1/products/:productId/notifications/:notificationId/send",
    {
      preHandler: server.authorize("products:write")
    },
    async (request, reply) => {
      const parsed = sendNotificationSchema.safeParse(request.body ?? {});
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid notification send payload",
            details: parsed.error.flatten()
          }
        });
      }

      if (parsed.data.dryRun !== true && parsed.data.confirmation !== "SEND") {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "MANUAL_CONFIRMATION_REQUIRED",
            message: "Customer-visible notification delivery requires confirmation: SEND"
          }
        });
      }

      if (parsed.data.mode === "queue") {
        if (!jobQueue) {
          return reply.code(503).send({
            ok: false,
            error: {
              code: "JOB_QUEUE_NOT_CONFIGURED",
              message: "Job queue is not configured"
            }
          });
        }
        const notification = (await store.listNotifications(request.params.productId)).find(
          (item) => item.id === request.params.notificationId
        );
        if (!notification) {
          return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Notification not found" } });
        }
        const payload = {
          productId: request.params.productId,
          notificationId: request.params.notificationId,
          requestedBy: request.authPrincipal?.id,
          dryRun: parsed.data.dryRun
        };
        const notificationPolicy = await store.notificationPolicy(request.params.productId);
        const quietHoursDelay = parsed.data.dryRun === true
          ? undefined
          : notificationQuietHoursDelay(notification, new Date(), notificationPolicy);
        const job = quietHoursDelay
          ? await jobQueue.enqueueNotificationSend(payload, quietHoursDelay)
          : await jobQueue.enqueueNotificationSend(payload);
        await store.createAuditLog({
          actorType: "user",
          actorId: request.authPrincipal?.id,
          action: "notification.send_enqueued",
          targetType: "notification",
          targetId: notification.id,
          productId: request.params.productId,
          afterValue: {
            jobId: job.id,
            dryRun: parsed.data.dryRun,
            ...(quietHoursDelay
              ? {
                  quietHoursApplied: true,
                  delayMs: quietHoursDelay.delayMs,
                  scheduledFor: quietHoursDelay.scheduledFor
                }
              : {})
          }
        });
        return reply.code(202).send({
          ok: true,
          data: job
        });
      }

      const notification = (await store.listNotifications(request.params.productId)).find(
        (item) => item.id === request.params.notificationId
      );
      if (!notification) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Notification not found" } });
      }

      const template = (await store.listNotificationTemplates(request.params.productId)).find(
        (item) => item.type === notification.type && item.status === "active"
      );
      if (!template) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Active template not found" } });
      }

      const deliveries = await store.listNotificationDeliveries(notification.id);
      const templatePayload = await buildNotificationTemplatePayload(
        store,
        request.params.productId,
        notification.payload
      );
      const rendered = {
        subject: renderTemplate(template.subjectTemplate, templatePayload),
        html: renderTemplate(template.htmlTemplate, templatePayload),
        text: template.textTemplate ? renderTemplate(template.textTemplate, templatePayload) : undefined
      };

      try {
        const result = await sendSmtpMail(
          {
            to: notification.recipient,
            ...rendered
          },
          { dryRun: parsed.data.dryRun }
        );
        const delivery = await store.createNotificationDelivery(notification.id, {
          provider: result.provider,
          attempt: deliveries.length + 1,
          status: result.status,
          providerMessageId: result.providerMessageId,
          sentAt: result.status === "sent" ? new Date().toISOString() : undefined
        });
        await store.createAuditLog({
          actorType: "user",
          actorId: request.authPrincipal?.id,
          action: result.status === "sent" ? "notification.sent" : "notification.dry_run",
          targetType: "notification",
          targetId: notification.id,
          productId: request.params.productId,
          afterValue: {
            recipient: notification.recipient,
            type: notification.type,
            deliveryId: delivery?.id
          }
        });
        return {
          ok: true,
          data: {
            notification,
            delivery,
            rendered,
            smtp: {
              status: result.status,
              providerMessageId: result.providerMessageId
            }
          }
        };
      } catch (error) {
        const message = error instanceof Error ? error.message : "Unknown SMTP error";
        const delivery = await store.createNotificationDelivery(notification.id, {
          provider: "smtp",
          attempt: deliveries.length + 1,
          status: "failed",
          error: message
        });
        await store.createAuditLog({
          actorType: "user",
          actorId: request.authPrincipal?.id,
          action: "notification.send_failed",
          targetType: "notification",
          targetId: notification.id,
          productId: request.params.productId,
          afterValue: {
            recipient: notification.recipient,
            type: notification.type,
            deliveryId: delivery?.id,
            error: message
          }
        });
        return reply.code(error instanceof SmtpConfigurationError ? 503 : 502).send({
          ok: false,
          error: {
            code: error instanceof SmtpConfigurationError ? "SMTP_NOT_CONFIGURED" : "SMTP_SEND_FAILED",
            message
          },
          data: {
            delivery
          }
        });
      }
    }
  );

  server.get<{ Params: { productId: string; notificationId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/notifications/:notificationId/deliveries",
    {
      preHandler: server.authorize("products:read")
    },
    async (request, reply) => {
      const parsedQuery = notificationDeliveryListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid notification delivery query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const notification = (await store.listNotifications(request.params.productId)).find(
        (item) => item.id === request.params.notificationId
      );
      if (!notification) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Notification not found"
          }
        });
      }
      const page = paginate(await store.listNotificationDeliveries(notification.id), parsedQuery.data);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );
}
