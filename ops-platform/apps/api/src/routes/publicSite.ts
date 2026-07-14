import type { FastifyInstance } from "fastify";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import type { OpsStore } from "../data/store.js";
import type { PublicRateLimiter } from "../services/publicRateLimiter.js";
import { websiteEventFromTelemetry } from "../services/websiteAnalytics.js";

const eventTypes = [
  "page_view",
  "download_requested",
  "download_redirected",
  "github_release_clicked",
  "github_asset_clicked"
] as const;

const releaseQuerySchema = z.object({
  channel: z.string().trim().max(80).optional()
});

const downloadQuerySchema = z.object({
  visitorId: z.string().trim().min(8).max(160),
  sessionId: z.string().trim().min(8).max(160).optional(),
  platform: z.string().trim().max(120).optional(),
  architecture: z.string().trim().max(80).optional()
});

const telemetrySchema = z.object({
  eventId: z.string().trim().regex(/^[a-zA-Z0-9_-]{8,96}$/),
  type: z.enum(eventTypes),
  path: z.string().trim().startsWith("/").max(2_000),
  visitorId: z.string().trim().min(8).max(160),
  sessionId: z.string().trim().min(8).max(160).optional(),
  releaseId: z.string().trim().max(64).optional(),
  platform: z.string().trim().max(120).optional(),
  architecture: z.string().trim().max(80).optional(),
  referrer: z.string().url().max(2_000).optional()
});

const analyticsQuerySchema = z.object({
  range: z.enum(["24h", "7d", "30d", "90d", "180d", "1y", "all"]).default("24h")
});

function rangeStart(range: z.infer<typeof analyticsQuerySchema>["range"]) {
  if (range === "all") {
    return undefined;
  }
  const milliseconds =
    range === "24h"
      ? 24 * 60 * 60 * 1_000
      : range === "7d"
        ? 7 * 24 * 60 * 60 * 1_000
        : range === "30d"
          ? 30 * 24 * 60 * 60 * 1_000
          : range === "90d"
            ? 90 * 24 * 60 * 60 * 1_000
            : range === "180d"
              ? 180 * 24 * 60 * 60 * 1_000
              : 365 * 24 * 60 * 60 * 1_000;
  return new Date(Date.now() - milliseconds).toISOString();
}

export async function registerPublicSiteRoutes(
  server: FastifyInstance,
  store: OpsStore,
  telemetryRateLimiter: PublicRateLimiter
) {
  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/v1/public/products/:productId/releases",
    async (request, reply) => {
      const query = releaseQuerySchema.safeParse(request.query);
      if (!query.success) {
        return reply.code(422).send({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid release query" } });
      }
      const product = await store.findProduct(request.params.productId);
      if (!product || product.status !== "active") {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Product not found" } });
      }
      const releases = (await store.listReleases(product.id))
        .filter((release) => release.status === "published" && (!query.data.channel || release.channel === query.data.channel))
        .sort((left, right) => (right.publishedAt ?? right.createdAt).localeCompare(left.publishedAt ?? left.createdAt))
        .map((release) => ({
          id: release.id,
          channel: release.channel,
          version: release.version,
          buildNumber: release.buildNumber,
          artifactName: release.artifactName,
          artifactSize: release.artifactSize,
          minimumSystemVersion: release.minimumSystemVersion,
          releaseNotes: release.releaseNotes,
          publishedAt: release.publishedAt,
          downloadAvailable: Boolean(release.artifactUrl?.startsWith("https://")),
          downloadUrl: `/api/v1/public/products/${encodeURIComponent(product.id)}/downloads/${encodeURIComponent(release.id)}`
        }));
      reply.header("cache-control", "public, max-age=60");
      return {
        ok: true,
        data: {
          product: { id: product.id, name: product.name, platform: product.platform },
          releases
        }
      };
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/public/products/:productId/telemetry",
    async (request, reply) => {
      const parsed = telemetrySchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid telemetry payload" } });
      }
      const limit = telemetryRateLimiter.consume([request.params.productId, request.ip]);
      if (!limit.allowed) {
        reply.header("retry-after", String(limit.retryAfterSeconds));
        return reply.code(429).send({ ok: false, error: { code: "RATE_LIMITED", message: "Too many telemetry events" } });
      }
      const recorded = await store.recordWebsiteEvent(
        request.params.productId,
        websiteEventFromTelemetry(parsed.data, {
          ipAddress: request.ip,
          userAgent: request.headers["user-agent"]
        })
      );
      if (!recorded) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Product not found" } });
      }
      return reply.code(202).send({
        ok: true,
        data: { accepted: true, duplicate: !recorded.created, eventId: recorded.event.eventId }
      });
    }
  );

  server.get<{ Params: { productId: string; releaseId: string }; Querystring: unknown }>(
    "/api/v1/public/products/:productId/downloads/:releaseId",
    async (request, reply) => {
      const query = downloadQuerySchema.safeParse(request.query);
      if (!query.success) {
        return reply.code(422).send({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid download request" } });
      }
      const release = (await store.listReleases(request.params.productId)).find(
        (item) => item.id === request.params.releaseId && item.status === "published"
      );
      if (!release) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Published release not found" } });
      }
      if (!release.artifactUrl?.startsWith("https://")) {
        return reply.code(409).send({ ok: false, error: { code: "ARTIFACT_UNAVAILABLE", message: "Published release artifact is unavailable" } });
      }
      await store.recordWebsiteEvent(
        request.params.productId,
        websiteEventFromTelemetry(
          {
            eventId: `download_${randomUUID().replaceAll("-", "")}`,
            type: "download_redirected",
            path: `/downloads/${release.id}`,
            visitorId: query.data.visitorId,
            sessionId: query.data.sessionId,
            releaseId: release.id,
            platform: query.data.platform,
            architecture: query.data.architecture
          },
          { ipAddress: request.ip, userAgent: request.headers["user-agent"] }
        )
      );
      reply.header("cache-control", "no-store");
      return reply.code(302).header("location", release.artifactUrl).send();
    }
  );

  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/website-analytics",
    { preHandler: server.authorize("products:read") },
    async (request, reply) => {
      const query = analyticsQuerySchema.safeParse(request.query);
      if (!query.success) {
        return reply.code(422).send({ ok: false, error: { code: "VALIDATION_ERROR", message: "Invalid analytics range" } });
      }
      const summary = await store.websiteAnalytics(request.params.productId, rangeStart(query.data.range));
      if (!summary) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Product not found" } });
      }
      return { ok: true, data: summary };
    }
  );
}
