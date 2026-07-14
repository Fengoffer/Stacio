import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { AuditLogItem } from "../data/types.js";
import type { OpsStore } from "../data/store.js";
import { paginate, paginationQuerySchema } from "./pagination.js";

const auditLogQuerySchema = paginationQuerySchema.extend({
  productId: z.string().trim().optional(),
  search: z.string().trim().optional(),
  actorType: z.enum(["user", "agent", "system", "public"]).optional(),
  actorId: z.string().trim().optional(),
  action: z.string().trim().optional(),
  targetType: z.string().trim().optional(),
  targetId: z.string().trim().optional(),
  ipAddress: z.string().trim().optional(),
  createdFrom: z.string().trim().optional(),
  createdTo: z.string().trim().optional()
});

type AuditLogQuery = z.infer<typeof auditLogQuerySchema>;

function parseTimestamp(value: string | undefined) {
  if (!value) return undefined;
  const timestamp = Date.parse(value);
  return Number.isNaN(timestamp) ? undefined : timestamp;
}

function searchHaystack(item: AuditLogItem) {
  return [
    item.id,
    item.actorType,
    item.actorId,
    item.action,
    item.targetType,
    item.targetId,
    item.productId,
    item.ipAddress,
    item.userAgent,
    JSON.stringify(item.beforeValue ?? {}),
    JSON.stringify(item.afterValue ?? {}),
    JSON.stringify(item.metadata ?? {})
  ]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();
}

function matchesAuditQuery(item: AuditLogItem, query: AuditLogQuery) {
  if (query.actorType && item.actorType !== query.actorType) return false;
  if (query.actorId && item.actorId !== query.actorId) return false;
  if (query.action && item.action !== query.action) return false;
  if (query.targetType && item.targetType !== query.targetType) return false;
  if (query.targetId && item.targetId !== query.targetId) return false;
  if (query.ipAddress && item.ipAddress !== query.ipAddress) return false;

  const createdAt = Date.parse(item.createdAt);
  const createdFrom = parseTimestamp(query.createdFrom);
  if (createdFrom !== undefined && createdAt < createdFrom) return false;
  const createdTo = parseTimestamp(query.createdTo);
  if (createdTo !== undefined && createdAt > createdTo) return false;

  if (query.search && !searchHaystack(item).includes(query.search.toLowerCase())) {
    return false;
  }
  return true;
}

export async function registerAuditLogRoutes(server: FastifyInstance, store: OpsStore) {
  server.get<{ Querystring: AuditLogQuery }>(
    "/api/v1/audit-logs",
    {
      preHandler: server.authorize("audit:read")
    },
    async (request, reply) => {
      const parsedQuery = auditLogQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid audit log query",
            details: parsedQuery.error.flatten()
          }
        });
      }

      const query = parsedQuery.data;
      const logs = await store.listAuditLogs(query.productId);
      const productIds = request.authPrincipal?.productIds ?? [];
      const scopedLogs =
        productIds.length === 0
          ? logs
          : logs.filter((item) => item.productId !== undefined && productIds.includes(item.productId));
      const page = paginate(
        scopedLogs.filter((item) => matchesAuditQuery(item, query)),
        query
      );
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );
}
