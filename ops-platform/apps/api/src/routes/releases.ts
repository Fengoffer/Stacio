import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { OpsStore } from "../data/store.js";
import type { ReleaseItem } from "../data/types.js";
import type { OpsJobQueue } from "../jobs/queue.js";
import { generateAppcastXml } from "../services/appcast.js";
import { paginate, paginationQuerySchema } from "./pagination.js";

const packageSignatureEvidenceSchema = z
  .object({
    status: z.enum(["passed", "failed", "not_available"]),
    tool: z.string().max(120).optional(),
    checkedAt: z.string().datetime().optional(),
    signer: z.string().max(300).optional(),
    summary: z.string().max(2000).optional()
  })
  .strict();

const downloadReachabilityEvidenceSchema = z
  .object({
    status: z.enum(["reachable", "unreachable", "not_checked"]),
    checkedAt: z.string().datetime().optional(),
    statusCode: z.number().int().min(100).max(599).optional(),
    contentLength: z.number().int().nonnegative().optional(),
    error: z.string().max(1000).optional(),
    summary: z.string().max(2000).optional()
  })
  .strict();

const createReleaseSchema = z.object({
  channel: z.enum(["stable", "beta", "dev", "internal"]),
  version: z.string().min(1).max(80),
  buildNumber: z.string().min(1).max(80),
  minimumSystemVersion: z.string().max(80).optional(),
  artifactName: z.string().min(1),
  artifactUrl: z.string().url().optional(),
  artifactObjectKey: z.string().max(1000).optional(),
  artifactType: z.string().max(80).optional(),
  artifactSize: z.number().int().positive().optional(),
  artifactSha256: z.string().regex(/^[a-fA-F0-9]{64}$/).optional(),
  sparkleEdDsaSignature: z.string().optional(),
  releaseNotes: z.string().optional(),
  aiReleaseSummary: z.string().optional(),
  aiRiskSummary: z.string().optional(),
  packageSignatureEvidence: packageSignatureEvidenceSchema.optional(),
  downloadReachabilityEvidence: downloadReachabilityEvidenceSchema.optional()
});

const updateReleaseDraftSchema = z
  .object({
    minimumSystemVersion: z.string().max(80).optional(),
    artifactName: z.string().min(1).optional(),
    artifactUrl: z.string().url().optional(),
    artifactObjectKey: z.string().max(1000).optional(),
    artifactType: z.string().max(80).optional(),
    artifactSize: z.number().int().positive().optional(),
    artifactSha256: z.string().regex(/^[a-fA-F0-9]{64}$/).optional(),
    sparkleEdDsaSignature: z.string().optional(),
    releaseNotes: z.string().optional(),
    aiReleaseSummary: z.string().optional(),
    aiRiskSummary: z.string().optional(),
    packageSignatureEvidence: packageSignatureEvidenceSchema.optional(),
    downloadReachabilityEvidence: downloadReachabilityEvidenceSchema.optional()
  })
  .strict()
  .refine((value) => Object.keys(value).length > 0, {
    message: "At least one draft field is required"
  });

const publishSchema = z.object({
  confirmation: z.literal("PUBLISH")
});

const retryPublicationSchema = z.object({
  confirmation: z.literal("RETRY_SYNC")
});

const releaseLifecycleSchema = z.object({
  action: z.enum(["pause", "resume", "withdraw"]),
  confirmation: z.string().optional()
});

const appcastEntryQuerySchema = paginationQuerySchema.extend({
  channel: z.string().max(80).optional()
});

const releaseListQuerySchema = paginationQuerySchema.extend({
  channel: z.string().max(80).optional(),
  status: z.string().max(80).optional()
});

const lifecycleConfirmation = {
  pause: "PAUSE",
  resume: "RESUME",
  withdraw: "WITHDRAW"
} as const;

const lifecycleStatus = {
  pause: "paused",
  resume: "published",
  withdraw: "withdrawn"
} as const;

function objectRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

async function queueAdminOtaNotification(
  store: OpsStore,
  productId: string,
  input: {
    type: "admin_ota_publish_success" | "admin_ota_publish_failure";
    release: ReleaseItem;
    payload: Record<string, unknown>;
  }
) {
  const product = await store.findProduct(productId);
  if (!product) {
    return undefined;
  }
  return store.createNotification(productId, {
    type: input.type,
    recipient: product.supportEmail,
    priority: "high",
    status: "queued",
    payload: {
      releaseId: input.release.id,
      version: input.release.version,
      buildNumber: input.release.buildNumber,
      channel: input.release.channel,
      ...input.payload
    }
  });
}

async function enqueueAdminOtaNotificationSend(
  jobQueue: OpsJobQueue | undefined,
  notification: { id: string; productId: string }
) {
  if (!jobQueue) return;
  await jobQueue.enqueueNotificationSend({
    productId: notification.productId,
    notificationId: notification.id,
    dryRun: false
  });
}

async function queueReleaseWebhook(
  jobQueue: OpsJobQueue | undefined,
  productId: string,
  release: ReleaseItem,
  requestedBy?: string
) {
  if (!jobQueue?.enqueueWebhookDispatch) return;
  await jobQueue.enqueueWebhookDispatch({
    productId,
    eventType: "release.published",
    eventId: release.id,
    requestedBy,
    payload: {
      release: {
        id: release.id,
        channel: release.channel,
        version: release.version,
        buildNumber: release.buildNumber,
        status: release.status,
        artifactName: release.artifactName,
        artifactUrl: release.artifactUrl,
        artifactSize: release.artifactSize,
        sparkleEdDsaSignature: release.sparkleEdDsaSignature,
        publishedAt: release.publishedAt,
        publishedBy: release.publishedBy
      }
    }
  });
}

async function probeDownloadReachability(release: ReleaseItem) {
  if (!release.artifactUrl) {
    return {
      status: "not_checked" as const,
      checkedAt: new Date().toISOString(),
      error: "Artifact URL is missing",
      summary: "Download URL was not checked because no Artifact URL is registered"
    };
  }

  try {
    const response = await fetch(release.artifactUrl, {
      method: "HEAD",
      signal: AbortSignal.timeout(5000)
    });
    const contentLengthHeader = response.headers.get("content-length");
    const contentLength = contentLengthHeader ? Number.parseInt(contentLengthHeader, 10) : undefined;
    const sizeMatches =
      release.artifactSize === undefined ||
      contentLength === undefined ||
      contentLength === release.artifactSize;
    const reachable = response.ok && sizeMatches;
    return {
      status: reachable ? ("reachable" as const) : ("unreachable" as const),
      checkedAt: new Date().toISOString(),
      statusCode: response.status,
      ...(Number.isFinite(contentLength) ? { contentLength } : {}),
      ...(sizeMatches ? {} : { error: "Content-Length does not match registered artifact size" }),
      summary: reachable ? "Download URL responded to HEAD" : "Download URL HEAD check failed"
    };
  } catch (error) {
    return {
      status: "unreachable" as const,
      checkedAt: new Date().toISOString(),
      error: error instanceof Error ? error.message : "Download URL HEAD check failed",
      summary: "Download URL HEAD check failed"
    };
  }
}

export async function registerReleaseRoutes(server: FastifyInstance, store: OpsStore, jobQueue?: OpsJobQueue) {
  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/releases",
    {
      preHandler: server.authorize("releases:read")
    },
    async (request, reply) => {
      const parsedQuery = releaseListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid release query",
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

      const query = parsedQuery.data;
      const releases = (await store.listReleases(request.params.productId)).filter((release) => {
        if (query.channel && release.channel !== query.channel) return false;
        if (query.status && release.status !== query.status) return false;
        return true;
      });
      const page = paginate(releases, query);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/appcast-entries",
    {
      preHandler: server.authorize("releases:read")
    },
    async (request, reply) => {
      const parsed = appcastEntryQuerySchema.safeParse(request.query);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid appcast entry query",
            details: parsed.error.flatten()
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

      return {
        ok: true,
        ...paginate(
          await store.listAppcastEntries(request.params.productId, parsed.data.channel),
          parsed.data
        )
      };
    }
  );

  server.get<{ Params: { productId: string; releaseId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/releases/:releaseId/artifacts",
    {
      preHandler: server.authorize("releases:read")
    },
    async (request, reply) => {
      const parsedQuery = paginationQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid release artifact query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const release = (await store.listReleases(request.params.productId)).find(
        (item) => item.id === request.params.releaseId
      );
      if (!release) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Release not found"
          }
        });
      }

      return {
        ok: true,
        ...paginate(
          await store.listReleaseArtifacts(request.params.productId, request.params.releaseId),
          parsedQuery.data
        )
      };
    }
  );

  server.get<{ Params: { productId: string; releaseId: string } }>(
    "/api/v1/products/:productId/releases/:releaseId/publications",
    {
      preHandler: server.authorize("releases:read")
    },
    async (request, reply) => {
      const release = (await store.listReleases(request.params.productId)).find(
        (item) => item.id === request.params.releaseId
      );
      if (!release) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Release not found" }
        });
      }
      return {
        ok: true,
        data: await store.listReleasePublications(request.params.productId, request.params.releaseId)
      };
    }
  );

  server.post<{ Params: { productId: string; releaseId: string }; Body: unknown }>(
    "/api/v1/products/:productId/releases/:releaseId/publications/retry",
    {
      preHandler: server.authorize("releases:write")
    },
    async (request, reply) => {
      const parsed = retryPublicationSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "MANUAL_CONFIRMATION_REQUIRED",
            message: "Retrying release synchronization requires confirmation: RETRY_SYNC"
          }
        });
      }
      const release = (await store.listReleases(request.params.productId)).find(
        (item) => item.id === request.params.releaseId && item.status === "published"
      );
      if (!release) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Published release not found" }
        });
      }
      if (!jobQueue?.enqueueReleasePublication) {
        return reply.code(503).send({
          ok: false,
          error: { code: "PUBLICATION_QUEUE_UNAVAILABLE", message: "Release publication queue is unavailable" }
        });
      }
      const failedTargets = (await store.listReleasePublications(request.params.productId, release.id)).filter(
        (publication) => publication.status === "failed"
      );
      if (failedTargets.length === 0) {
        return reply.code(409).send({
          ok: false,
          error: { code: "NO_FAILED_PUBLICATIONS", message: "No failed publication target is available to retry" }
        });
      }

      await Promise.all(
        failedTargets.map((publication) =>
          store.updateReleasePublication(request.params.productId, release.id, publication.target, {
            status: "queued",
            lastError: null,
            startedAt: null,
            completedAt: null
          })
        )
      );
      let publicationJob;
      try {
        publicationJob = await jobQueue.enqueueReleasePublication({
          productId: request.params.productId,
          releaseId: release.id,
          requestedBy: request.authPrincipal?.id
        });
      } catch (error) {
        const message = error instanceof Error ? error.message : "Unknown queue error";
        await Promise.all(
          failedTargets.map((publication) =>
            store.updateReleasePublication(request.params.productId, release.id, publication.target, {
              status: "failed",
              lastError: `Manual retry could not be queued: ${message}`
            })
          )
        );
        throw error;
      }
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "release.publication_retry_queued",
        targetType: "release_publication",
        targetId: release.id,
        productId: request.params.productId,
        afterValue: {
          jobId: publicationJob.id,
          targets: failedTargets.map((publication) => publication.target)
        }
      });
      return {
        ok: true,
        data: {
          jobId: publicationJob.id,
          targets: failedTargets.map((publication) => publication.target)
        }
      };
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId/releases",
    {
      preHandler: server.authorize("releases:write")
    },
    async (request, reply) => {
      const parsed = createReleaseSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid release payload",
            details: parsed.error.flatten()
          }
        });
      }
      const release = await store.createRelease(request.params.productId, {
        ...parsed.data,
        createdBy: request.authPrincipal?.id
      });
      if (!release) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Product not found" } });
      }
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "release.created",
        targetType: "release",
        targetId: release.id,
        productId: request.params.productId,
        afterValue: {
          channel: release.channel,
          version: release.version,
          buildNumber: release.buildNumber
        }
      });
      return reply.code(201).send({ ok: true, data: release });
    }
  );

  server.patch<{ Params: { productId: string; releaseId: string }; Body: unknown }>(
    "/api/v1/products/:productId/releases/:releaseId/draft",
    {
      preHandler: server.authorize("releases:write")
    },
    async (request, reply) => {
      const parsed = updateReleaseDraftSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid release draft payload",
            details: parsed.error.flatten()
          }
        });
      }

      const before = (await store.listReleases(request.params.productId)).find(
        (item) => item.id === request.params.releaseId
      );
      if (!before) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Release not found" } });
      }
      if (["published", "paused", "withdrawn"].includes(before.status)) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "RELEASE_LOCKED",
            message: "Published, paused, and withdrawn releases cannot be edited as drafts"
          }
        });
      }

      const release = await store.updateReleaseDraft(request.params.productId, request.params.releaseId, parsed.data);
      if (!release) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "RELEASE_LOCKED",
            message: "Release draft could not be updated"
          }
        });
      }

      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "release.draft_updated",
        targetType: "release",
        targetId: release.id,
        productId: request.params.productId,
        beforeValue: {
          status: before.status,
          artifactUrl: before.artifactUrl,
          artifactSize: before.artifactSize,
          sparkleEdDsaSignature: before.sparkleEdDsaSignature,
          releaseNotes: before.releaseNotes,
          aiReleaseSummary: before.aiReleaseSummary,
          aiRiskSummary: before.aiRiskSummary,
          packageSignatureEvidence: before.preflightEvidence?.packageSignatureEvidence,
          downloadReachabilityEvidence: before.preflightEvidence?.downloadReachabilityEvidence
        },
        afterValue: {
          status: release.status,
          artifactUrl: release.artifactUrl,
          artifactSize: release.artifactSize,
          sparkleEdDsaSignature: release.sparkleEdDsaSignature,
          releaseNotes: release.releaseNotes,
          aiReleaseSummary: release.aiReleaseSummary,
          aiRiskSummary: release.aiRiskSummary,
          packageSignatureEvidence: release.preflightEvidence?.packageSignatureEvidence,
          downloadReachabilityEvidence: release.preflightEvidence?.downloadReachabilityEvidence
        }
      });

      return { ok: true, data: release };
    }
  );

  server.post<{ Params: { productId: string; releaseId: string } }>(
    "/api/v1/products/:productId/releases/:releaseId/validate",
    {
      preHandler: server.authorize("releases:write")
    },
    async (request, reply) => {
      const result = await store.validateRelease(request.params.productId, request.params.releaseId);
      if (!result) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Release not found" } });
      }
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "release.validation",
        targetType: "release",
        targetId: result.release.id,
        productId: request.params.productId,
        afterValue: {
          passed: result.passed,
          checks: result.checks
        }
      });
      if (!result.passed) {
        const notification = await queueAdminOtaNotification(store, request.params.productId, {
          type: "admin_ota_publish_failure",
          release: result.release,
          payload: {
            error: "Release preflight failed",
            failedChecks: result.checks.filter((check) => !check.passed)
          }
        });
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
              releaseId: result.release.id
            }
          });
          await enqueueAdminOtaNotificationSend(jobQueue, notification);
        }
      }
      return { ok: true, data: result };
    }
  );

  server.get<{ Params: { productId: string; releaseId: string } }>(
    "/api/v1/products/:productId/releases/:releaseId/appcast-diff",
    {
      preHandler: server.authorize("releases:read")
    },
    async (request, reply) => {
      const product = await store.findProduct(request.params.productId);
      if (!product) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Product not found" }
        });
      }
      const releases = await store.listReleases(request.params.productId);
      const release = releases.find((item) => item.id === request.params.releaseId);
      if (!release) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Release not found" }
        });
      }

      const previewReleases = releases.map((item) =>
        item.id === release.id ? { ...item, status: "published" as const } : item
      );
      const currentXml = generateAppcastXml(product.name, release.channel, releases);
      const previewXml = generateAppcastXml(product.name, release.channel, previewReleases);

      return {
        ok: true,
        data: {
          releaseId: release.id,
          channel: release.channel,
          addedItem: {
            version: release.version,
            buildNumber: release.buildNumber,
            artifactUrl: release.artifactUrl,
            artifactName: release.artifactName
          },
          currentItemCount: releases.filter(
            (item) => item.channel === release.channel && item.status === "published"
          ).length,
          previewItemCount: previewReleases.filter(
            (item) => item.channel === release.channel && item.status === "published"
          ).length,
          currentXml,
          previewXml
        }
      };
    }
  );

  server.post<{ Params: { productId: string; releaseId: string } }>(
    "/api/v1/products/:productId/releases/:releaseId/check-download",
    {
      preHandler: server.authorize("releases:write")
    },
    async (request, reply) => {
      const releases = await store.listReleases(request.params.productId);
      const before = releases.find((item) => item.id === request.params.releaseId);
      if (!before) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Release not found" } });
      }

      const downloadReachabilityEvidence = await probeDownloadReachability(before);
      const release = await store.updateReleaseDraft(request.params.productId, request.params.releaseId, {
        packageSignatureEvidence: objectRecord(before.preflightEvidence?.packageSignatureEvidence),
        downloadReachabilityEvidence
      });
      if (!release) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "RELEASE_LOCKED",
            message: "Published, paused, and withdrawn releases cannot be checked as drafts"
          }
        });
      }

      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "release.download_checked",
        targetType: "release",
        targetId: release.id,
        productId: request.params.productId,
        beforeValue: {
          downloadReachabilityEvidence: before.preflightEvidence?.downloadReachabilityEvidence
        },
        afterValue: {
          downloadReachabilityEvidence
        }
      });

      return {
        ok: true,
        data: {
          release,
          downloadReachabilityEvidence
        }
      };
    }
  );

  server.post<{ Params: { productId: string; releaseId: string }; Body: unknown }>(
    "/api/v1/products/:productId/releases/:releaseId/publish",
    {
      preHandler: server.authorize("releases:write")
    },
    async (request, reply) => {
      const parsed = publishSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "MANUAL_CONFIRMATION_REQUIRED",
            message: "Publishing requires confirmation: PUBLISH"
          }
        });
      }
      const release = await store.publishRelease(request.params.productId, request.params.releaseId, request.authPrincipal?.id);
      if (!release) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "RELEASE_NOT_READY",
            message: "Release must pass validation before publishing"
          }
        });
      }
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "release.publish",
        targetType: "release",
        targetId: release.id,
        productId: request.params.productId,
        afterValue: {
          channel: release.channel,
          version: release.version,
          publishedAt: release.publishedAt
        }
      });
      const publicationJob = await jobQueue?.enqueueReleasePublication?.({
        productId: request.params.productId,
        releaseId: release.id,
        requestedBy: request.authPrincipal?.id
      });
      if (publicationJob) {
        await store.createAuditLog({
          actorType: "system",
          action: "release.publication_queued",
          targetType: "release_publication",
          targetId: release.id,
          productId: request.params.productId,
          afterValue: {
            jobId: publicationJob.id,
            targetCount: 4
          }
        });
      }
      const notification = await queueAdminOtaNotification(store, request.params.productId, {
        type: "admin_ota_publish_success",
        release,
        payload: {
          publishedAt: release.publishedAt,
          publishedBy: release.publishedBy
        }
      });
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
            releaseId: release.id
          }
        });
        await enqueueAdminOtaNotificationSend(jobQueue, notification);
      }
      await queueReleaseWebhook(jobQueue, request.params.productId, release, request.authPrincipal?.id);
      return { ok: true, data: release };
    }
  );

  server.post<{ Params: { productId: string; releaseId: string }; Body: unknown }>(
    "/api/v1/products/:productId/releases/:releaseId/lifecycle",
    {
      preHandler: server.authorize("releases:write")
    },
    async (request, reply) => {
      const parsed = releaseLifecycleSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid release lifecycle payload",
            details: parsed.error.flatten()
          }
        });
      }

      const confirmation = lifecycleConfirmation[parsed.data.action];
      if (parsed.data.confirmation !== confirmation) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "RELEASE_CONFIRMATION_REQUIRED",
            message: `Release lifecycle action requires confirmation: ${confirmation}`
          }
        });
      }

      const before = (await store.listReleases(request.params.productId)).find((item) => item.id === request.params.releaseId);
      if (!before) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Release not found" } });
      }

      const release = await store.updateReleaseStatus(
        request.params.productId,
        request.params.releaseId,
        lifecycleStatus[parsed.data.action]
      );
      if (!release) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Release not found" } });
      }

      const actionName =
        parsed.data.action === "pause"
          ? "release.paused"
          : parsed.data.action === "resume"
            ? "release.resumed"
            : "release.withdrawn";
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: actionName,
        targetType: "release",
        targetId: release.id,
        productId: request.params.productId,
        beforeValue: {
          status: before.status
        },
        afterValue: {
          status: release.status,
          channel: release.channel,
          version: release.version
        }
      });

      return {
        ok: true,
        data: release
      };
    }
  );

  server.get<{ Params: { productId: string; channel: string } }>(
    "/updates/:productId/:channel/appcast.xml",
    async (request, reply) => {
      const product = await store.findProduct(request.params.productId);
      if (!product) {
        return reply.code(404).send("Product not found");
      }
      const releases = await store.listReleases(request.params.productId);
      reply.header("content-type", "application/xml; charset=utf-8");
      return generateAppcastXml(product.name, request.params.channel, releases);
    }
  );
}
