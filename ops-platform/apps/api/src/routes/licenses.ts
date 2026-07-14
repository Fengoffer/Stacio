import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { OpsStore } from "../data/store.js";
import type { OpsJobQueue } from "../jobs/queue.js";
import { licenseKeyPrefix } from "../services/licenseKeys.js";
import { notificationQuietHoursDelay } from "../services/notificationPolicy.js";
import { signOfflineLicenseToken } from "../services/offlineLicenseToken.js";
import { paginate, paginationQuerySchema } from "./pagination.js";

const validateLicenseSchema = z.object({
  licenseKey: z.string().min(4),
  email: z.string().email(),
  username: z.string().min(1),
  appVersion: z.string().optional(),
  buildNumber: z.string().optional(),
  anonymousDeviceId: z.string().optional(),
  machineFingerprintHash: z.string().optional()
});

type LicenseValidationInput = z.infer<typeof validateLicenseSchema>;
type LicenseValidationFailure = Awaited<ReturnType<OpsStore["validateLicense"]>>;

const createLicenseSchema = z.object({
  customerName: z.string().min(1).max(160),
  customerEmail: z.string().email(),
  username: z.string().max(160).optional(),
  plan: z.enum(["free", "pro", "team", "internal"]),
  seats: z.number().int().positive().optional(),
  maxDevices: z.number().int().positive().optional(),
  entitlements: z.array(z.string()).optional(),
  offlineGraceDays: z.number().int().positive().max(365).optional(),
  expiresAt: z.string().datetime(),
  status: z.enum(["active", "trial", "expired", "suspended", "revoked"]).optional()
});

const batchCreateLicenseSchema = createLicenseSchema
  .omit({
    customerName: true,
    customerEmail: true,
    username: true
  })
  .extend({
    recipients: z
      .array(
        z.object({
          customerName: z.string().min(1).max(160),
          customerEmail: z.string().email(),
          username: z.string().max(160).optional()
        })
      )
      .min(1)
      .max(100)
  });

const updateLicenseSchema = z.object({
  plan: z.enum(["free", "pro", "team", "internal"]).optional(),
  status: z.enum(["active", "trial", "expired", "suspended", "revoked"]).optional(),
  seats: z.number().int().positive().optional(),
  maxDevices: z.number().int().nonnegative().optional(),
  entitlements: z.array(z.string()).optional(),
  offlineGraceDays: z.number().int().positive().max(365).optional(),
  expiresAt: z.string().datetime().optional(),
  confirmation: z.string().optional()
});

const resetActivationsSchema = z.object({
  confirmation: z.literal("RESET")
});

const sendLicenseEmailSchema = z.object({
  licenseKey: z.string().min(4),
  confirmation: z.string().optional(),
  dryRun: z.boolean().optional()
});

const batchSendLicenseEmailSchema = z.object({
  items: z
    .array(
      z.object({
        licenseId: z.string().min(1),
        licenseKey: z.string().min(4)
      })
    )
    .min(1)
    .max(100),
  confirmation: z.string().optional(),
  dryRun: z.boolean().optional()
});

const licenseListQuerySchema = paginationQuerySchema.extend({
  status: z.enum(["active", "trial", "expired", "suspended", "revoked"]).optional(),
  plan: z.enum(["free", "pro", "team", "internal"]).optional(),
  search: z.string().trim().optional()
});

function requiredLicenseConfirmation(status: string | undefined) {
  if (status === "revoked") return "REVOKE";
  if (status === "suspended") return "SUSPEND";
  return undefined;
}

async function queueAdminLicenseAnomalyNotification(
  store: OpsStore,
  productId: string,
  recipient: string,
  input: LicenseValidationInput,
  validation: LicenseValidationFailure
) {
  const reason = validation.reason ?? "invalid";
  const payload: Record<string, unknown> = {
    licenseId: validation.license?.id ?? "unmatched",
    reason,
    keyPrefix: licenseKeyPrefix(input.licenseKey),
    email: input.email,
    username: input.username
  };
  if (input.appVersion) payload.appVersion = input.appVersion;
  if (input.buildNumber) payload.buildNumber = input.buildNumber;
  if (input.anonymousDeviceId) payload.anonymousDeviceId = input.anonymousDeviceId;
  if (input.machineFingerprintHash) payload.machineFingerprintHash = input.machineFingerprintHash;
  if (validation.license) {
    payload.customerName = validation.license.customerName;
    payload.plan = validation.license.plan;
    payload.status = validation.license.status;
    payload.expiresAt = validation.license.expiresAt;
  }

  return store.createNotification(productId, {
    type: "admin_license_anomaly",
    recipient,
    priority: reason === "expired" ? "normal" : "high",
    status: "queued",
    payload
  });
}

async function queueCustomerLicenseLifecycleNotification(
  store: OpsStore,
  productId: string,
  license: {
    id: string;
    customerName: string;
    customerEmail: string;
    plan: string;
    status: string;
    expiresAt: string;
  }
) {
  if (license.status !== "suspended" && license.status !== "revoked") {
    return undefined;
  }
  return store.createNotification(productId, {
    type: license.status === "revoked" ? "customer_license_revoked" : "customer_license_suspended",
    recipient: license.customerEmail,
    priority: license.status === "revoked" ? "high" : "normal",
    status: "queued",
    payload: {
      licenseId: license.id,
      customerName: license.customerName,
      email: license.customerEmail,
      plan: license.plan,
      status: license.status,
      expiresAt: license.expiresAt,
      reason:
        license.status === "revoked"
          ? "License was revoked by an administrator."
          : "License was suspended by an administrator."
    }
  });
}

async function queueCustomerLicenseIssuedNotification(
  store: OpsStore,
  productId: string,
  license: {
    id: string;
    customerName: string;
    customerEmail: string;
    username?: string;
    plan: string;
    expiresAt: string;
  },
  licenseKey: string
) {
  return store.createNotification(productId, {
    type: "customer_license_issued",
    recipient: license.customerEmail,
    priority: "normal",
    status: "queued",
    payload: {
      licenseId: license.id,
      customerName: license.customerName,
      email: license.customerEmail,
      username: license.username,
      plan: license.plan,
      expiresAt: license.expiresAt,
      licenseKey
    }
  });
}

async function enqueueLicenseNotificationSend(
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

async function queueLicenseLifecycleWebhook(
  jobQueue: OpsJobQueue | undefined,
  productId: string,
  license: {
    id: string;
    customerName: string;
    customerEmail: string;
    username?: string;
    plan: string;
    status: string;
    seats: number;
    maxDevices?: number;
    expiresAt: string;
  },
  requestedBy?: string
) {
  if (!jobQueue?.enqueueWebhookDispatch) return;
  if (license.status !== "suspended" && license.status !== "revoked") return;
  await jobQueue.enqueueWebhookDispatch({
    productId,
    eventType: `license.${license.status}`,
    eventId: license.id,
    requestedBy,
    payload: {
      license: {
        id: license.id,
        customerName: license.customerName,
        customerEmail: license.customerEmail,
        username: license.username,
        plan: license.plan,
        status: license.status,
        seats: license.seats,
        maxDevices: license.maxDevices,
        expiresAt: license.expiresAt
      }
    }
  });
}

export async function registerLicenseRoutes(server: FastifyInstance, store: OpsStore, jobQueue?: OpsJobQueue) {
  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/licenses",
    {
      preHandler: server.authorize("licenses:read")
    },
    async (request, reply) => {
      const parsedQuery = licenseListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid license query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const product = await store.findProduct(request.params.productId);
      if (!product) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Product not found"
          }
        });
      }

      const query = parsedQuery.data;
      const search = query.search?.toLowerCase();
      const licenses = (await store.listLicenses(request.params.productId)).filter((license) => {
        if (query.status && license.status !== query.status) return false;
        if (query.plan && license.plan !== query.plan) return false;
        if (
          search &&
          ![license.id, license.customerName, license.customerEmail, license.username, license.plan]
            .filter(Boolean)
            .some((value) => value?.toLowerCase().includes(search))
        ) {
          return false;
        }
        return true;
      });
      const page = paginate(licenses, query);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.get<{ Params: { productId: string; licenseId: string } }>(
    "/api/v1/products/:productId/licenses/:licenseId",
    {
      preHandler: server.authorize("licenses:read")
    },
    async (request, reply) => {
      const detail = await store.licenseDetail(request.params.productId, request.params.licenseId);
      if (!detail) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "License not found"
          }
        });
      }
      return {
        ok: true,
        data: detail
      };
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId/licenses",
    {
      preHandler: server.authorize("licenses:write")
    },
    async (request, reply) => {
      const parsed = createLicenseSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid license payload",
            details: parsed.error.flatten()
          }
        });
      }

      const result = await store.createLicense(request.params.productId, parsed.data);
      if (!result) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Product not found" } });
      }
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "license.created",
        targetType: "license",
        targetId: result.license.id,
        productId: request.params.productId,
        afterValue: {
          email: result.license.customerEmail,
          plan: result.license.plan,
          status: result.license.status
        }
      });
      return reply.code(201).send({
        ok: true,
        data: {
          license: result.license,
          licenseKey: result.licenseKey,
          revealPolicy: "one_time"
        }
      });
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId/licenses/batch",
    {
      preHandler: server.authorize("licenses:write")
    },
    async (request, reply) => {
      const parsed = batchCreateLicenseSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid batch license payload",
            details: parsed.error.flatten()
          }
        });
      }

      const { recipients, ...sharedInput } = parsed.data;
      const items = [];
      for (const recipient of recipients) {
        const result = await store.createLicense(request.params.productId, {
          ...sharedInput,
          customerName: recipient.customerName,
          customerEmail: recipient.customerEmail,
          username: recipient.username
        });
        if (!result) {
          return reply.code(404).send({
            ok: false,
            error: {
              code: "NOT_FOUND",
              message: "Product not found"
            }
          });
        }
        items.push({
          license: result.license,
          licenseKey: result.licenseKey,
          revealPolicy: "one_time"
        });
      }

      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "license.batch_created",
        targetType: "license_batch",
        productId: request.params.productId,
        afterValue: {
          count: items.length,
          plan: sharedInput.plan,
          status: sharedInput.status ?? "active",
          expiresAt: sharedInput.expiresAt
        }
      });

      return reply.code(201).send({
        ok: true,
        data: {
          items
        }
      });
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId/licenses/batch-email",
    {
      preHandler: server.authorize("licenses:write")
    },
    async (request, reply) => {
      const parsed = batchSendLicenseEmailSchema.safeParse(request.body ?? {});
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid batch license email payload",
            details: parsed.error.flatten()
          }
        });
      }
      if (parsed.data.dryRun !== true && parsed.data.confirmation !== "SEND") {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "MANUAL_CONFIRMATION_REQUIRED",
            message: "Customer-visible batch license email delivery requires confirmation: SEND"
          }
        });
      }
      if (!jobQueue) {
        return reply.code(503).send({
          ok: false,
          error: {
            code: "JOB_QUEUE_NOT_CONFIGURED",
            message: "Job queue is not configured"
          }
        });
      }

      const licenses = await store.listLicenses(request.params.productId);
      const queued = [];
      const skipped = [];
      for (const item of parsed.data.items) {
        const license = licenses.find((candidate) => candidate.id === item.licenseId);
        if (!license) {
          skipped.push({
            licenseId: item.licenseId,
            reason: "not_found"
          });
          continue;
        }
        if (license.keyPrefix && license.keyPrefix !== licenseKeyPrefix(item.licenseKey)) {
          skipped.push({
            licenseId: item.licenseId,
            recipient: license.customerEmail,
            reason: "license_key_mismatch"
          });
          continue;
        }

        const notification = await queueCustomerLicenseIssuedNotification(
          store,
          request.params.productId,
          license,
          item.licenseKey
        );
        if (!notification) {
          skipped.push({
            licenseId: item.licenseId,
            recipient: license.customerEmail,
            reason: "product_not_found"
          });
          continue;
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
            licenseId: license.id
          }
        });
        const job = await jobQueue.enqueueNotificationSend({
          productId: request.params.productId,
          notificationId: notification.id,
          requestedBy: request.authPrincipal?.id,
          dryRun: parsed.data.dryRun === true
        });
        await store.createAuditLog({
          actorType: "user",
          actorId: request.authPrincipal?.id,
          action: "notification.send_enqueued",
          targetType: "notification",
          targetId: notification.id,
          productId: request.params.productId,
          afterValue: {
            jobId: job.id,
            dryRun: parsed.data.dryRun === true,
            licenseId: license.id
          }
        });
        queued.push({
          licenseId: license.id,
          recipient: license.customerEmail,
          notification,
          job
        });
      }

      return reply.code(202).send({
        ok: true,
        data: {
          requestedCount: parsed.data.items.length,
          queuedCount: queued.length,
          skippedCount: skipped.length,
          queued,
          skipped
        }
      });
    }
  );

  server.patch<{ Params: { productId: string; licenseId: string }; Body: unknown }>(
    "/api/v1/products/:productId/licenses/:licenseId",
    {
      preHandler: server.authorize("licenses:write")
    },
    async (request, reply) => {
      const parsed = updateLicenseSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid license update payload",
            details: parsed.error.flatten()
          }
        });
      }

      const requiredConfirmation = requiredLicenseConfirmation(parsed.data.status);
      if (requiredConfirmation && parsed.data.confirmation !== requiredConfirmation) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "LICENSE_CONFIRMATION_REQUIRED",
            message: `Type ${requiredConfirmation} to confirm this license lifecycle action`
          }
        });
      }

      const before = (await store.listLicenses(request.params.productId)).find((license) => license.id === request.params.licenseId);
      if (!before) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "License not found" } });
      }
      const beforeStatus = before.status;

      const { confirmation: _confirmation, ...updateInput } = parsed.data;
      const license = await store.updateLicense(request.params.productId, request.params.licenseId, updateInput);
      if (!license) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "License not found" } });
      }

      const action = license.status === "revoked" ? "license.revoked" : license.status === "suspended" ? "license.suspended" : "license.updated";
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action,
        targetType: "license",
        targetId: license.id,
        productId: request.params.productId,
        beforeValue: {
          plan: before.plan,
          status: before.status,
          expiresAt: before.expiresAt
        },
        afterValue: {
          plan: license.plan,
          status: license.status,
          seats: license.seats,
          maxDevices: license.maxDevices,
          expiresAt: license.expiresAt
        }
      });
      if (
        parsed.data.status &&
        ["suspended", "revoked"].includes(parsed.data.status) &&
        beforeStatus !== license.status
      ) {
        const notification = await queueCustomerLicenseLifecycleNotification(
          store,
          request.params.productId,
          license
        );
        if (notification) {
          await store.createAuditLog({
            actorType: "system",
            action: "notification.queued",
            targetType: "notification",
            targetId: notification.id,
            productId: request.params.productId,
            afterValue: {
              type: notification.type,
              recipient: notification.recipient,
              licenseId: license.id
            }
          });
          await enqueueLicenseNotificationSend(jobQueue, notification);
        }
        await queueLicenseLifecycleWebhook(
          jobQueue,
          request.params.productId,
          license,
          request.authPrincipal?.id
        );
      }

      return {
        ok: true,
        data: license
      };
    }
  );

  server.post<{ Params: { productId: string; licenseId: string }; Body: unknown }>(
    "/api/v1/products/:productId/licenses/:licenseId/reset-activations",
    {
      preHandler: server.authorize("licenses:write")
    },
    async (request, reply) => {
      const parsed = resetActivationsSchema.safeParse(request.body ?? {});
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "LICENSE_CONFIRMATION_REQUIRED",
            message: "Type RESET to confirm activation reset"
          }
        });
      }
      const before = (await store.listLicenses(request.params.productId)).find((license) => license.id === request.params.licenseId);
      if (!before) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "License not found" } });
      }
      const license = await store.resetLicenseActivations(request.params.productId, request.params.licenseId);
      if (!license) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "License not found" } });
      }
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "license.activations_reset",
        targetType: "license",
        targetId: license.id,
        productId: request.params.productId,
        beforeValue: {
          devices: before.devices
        },
        afterValue: {
          devices: license.devices
        }
      });
      return {
        ok: true,
        data: license
      };
    }
  );

  server.post<{ Params: { productId: string; licenseId: string }; Body: unknown }>(
    "/api/v1/products/:productId/licenses/:licenseId/email",
    {
      preHandler: server.authorize("licenses:write")
    },
    async (request, reply) => {
      const parsed = sendLicenseEmailSchema.safeParse(request.body ?? {});
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid license email payload",
            details: parsed.error.flatten()
          }
        });
      }
      if (parsed.data.dryRun !== true && parsed.data.confirmation !== "SEND") {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "MANUAL_CONFIRMATION_REQUIRED",
            message: "Customer-visible license email delivery requires confirmation: SEND"
          }
        });
      }
      if (!jobQueue) {
        return reply.code(503).send({
          ok: false,
          error: {
            code: "JOB_QUEUE_NOT_CONFIGURED",
            message: "Job queue is not configured"
          }
        });
      }

      const license = (await store.listLicenses(request.params.productId)).find(
        (item) => item.id === request.params.licenseId
      );
      if (!license) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "License not found" } });
      }
      if (license.keyPrefix && license.keyPrefix !== licenseKeyPrefix(parsed.data.licenseKey)) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "LICENSE_KEY_MISMATCH",
            message: "License key does not match this license"
          }
        });
      }

      const notification = await queueCustomerLicenseIssuedNotification(
        store,
        request.params.productId,
        license,
        parsed.data.licenseKey
      );
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
          licenseId: license.id
        }
      });
      const job = await jobQueue.enqueueNotificationSend({
        productId: request.params.productId,
        notificationId: notification.id,
        requestedBy: request.authPrincipal?.id,
        dryRun: parsed.data.dryRun === true
      });
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "notification.send_enqueued",
        targetType: "notification",
        targetId: notification.id,
        productId: request.params.productId,
        afterValue: {
          jobId: job.id,
          dryRun: parsed.data.dryRun === true,
          licenseId: license.id
        }
      });

      return reply.code(202).send({
        ok: true,
        data: {
          notification,
          job
        }
      });
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/public/products/:productId/licenses/validate",
    async (request, reply) => {
      const parsed = validateLicenseSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid license validation payload",
            details: parsed.error.flatten()
          }
        });
      }

      const product = await store.findProduct(request.params.productId);
      if (!product) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Product not found"
          }
        });
      }

      const validation = await store.validateLicense(request.params.productId, parsed.data);
      if (!validation.valid || !validation.license) {
        const notification = await queueAdminLicenseAnomalyNotification(
          store,
          request.params.productId,
          product.supportEmail,
          parsed.data,
          validation
        );
        if (notification) {
          await store.createAuditLog({
            actorType: "system",
            action: "notification.queued",
            targetType: "notification",
            targetId: notification.id,
            productId: request.params.productId,
            afterValue: {
              type: notification.type,
              recipient: notification.recipient,
              reason: validation.reason ?? "invalid",
              licenseId: validation.license?.id ?? "unmatched",
              keyPrefix: licenseKeyPrefix(parsed.data.licenseKey)
            }
          });
          const notificationPolicy = await store.notificationPolicy(request.params.productId);
          await enqueueLicenseNotificationSend(jobQueue, notification, notificationPolicy);
        }
        return {
          ok: true,
          data: {
            valid: false,
            reason: validation.reason ?? "invalid"
          }
        };
      }

      const offlineGraceSeconds = validation.offlineGraceSeconds ?? 1_209_600;
      const signedLicenseToken = signOfflineLicenseToken({
        licenseId: validation.license.id,
        productId: request.params.productId,
        email: validation.license.customerEmail,
        username: parsed.data.username,
        plan: validation.license.plan,
        entitlements: validation.license.entitlements ?? [],
        expiresAt: validation.license.expiresAt,
        offlineGraceSeconds,
        issuedAt: new Date().toISOString()
      });

      return {
        ok: true,
        data: {
          valid: true,
          status: validation.license.status,
          plan: validation.license.plan,
          entitlements: validation.license.entitlements ?? [],
          expiresAt: validation.license.expiresAt,
          offlineGraceSeconds,
          signedLicenseToken
        }
      };
    }
  );
}
