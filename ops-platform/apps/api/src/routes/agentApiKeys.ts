import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { OpsStore } from "../data/store.js";
import { paginate, paginationQuerySchema } from "./pagination.js";

const createAgentApiKeySchema = z.object({
  name: z.string().trim().min(1).max(160),
  productIds: z.array(z.string().trim().min(1).max(64)).max(100).default([]),
  scopes: z.array(z.string().trim().min(1).max(120)).min(1).max(100),
  expiresAt: z.string().datetime().optional()
});

const updateAgentApiKeySchema = z.object({
  status: z.enum(["active", "disabled"]),
  confirmation: z.string().optional()
});

const rotateAgentApiKeySchema = z.object({
  confirmation: z.string()
});

export async function registerAgentApiKeyRoutes(server: FastifyInstance, store: OpsStore) {
  server.get<{ Querystring: unknown }>(
    "/api/v1/admin/agent-api-keys",
    {
      preHandler: server.authorize("users:read", { global: true })
    },
    async (request, reply) => {
      const parsedQuery = paginationQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid Agent API key query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const page = paginate(await store.listAgentApiKeys(), parsedQuery.data);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.post<{ Body: unknown }>(
    "/api/v1/admin/agent-api-keys",
    {
      preHandler: server.authorize("users:write", { global: true })
    },
    async (request, reply) => {
      const parsed = createAgentApiKeySchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid Agent API key payload",
            details: parsed.error.flatten()
          }
        });
      }

      const result = await store.createAgentApiKey({
        ...parsed.data,
        createdBy: request.authPrincipal?.id
      });
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "agent_api_key.created",
        targetType: "api_key",
        targetId: result.apiKey.id,
        afterValue: {
          name: result.apiKey.name,
          productIds: result.apiKey.productIds,
          scopes: result.apiKey.scopes,
          expiresAt: result.apiKey.expiresAt,
          status: result.apiKey.status
        }
      });

      return reply.code(201).send({
        ok: true,
        data: {
          ...result.apiKey,
          key: result.key
        }
      });
    }
  );

  server.patch<{ Params: { keyId: string }; Body: unknown }>(
    "/api/v1/admin/agent-api-keys/:keyId",
    {
      preHandler: server.authorize("users:write", { global: true })
    },
    async (request, reply) => {
      const parsed = updateAgentApiKeySchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid Agent API key update",
            details: parsed.error.flatten()
          }
        });
      }

      const requiredConfirmation = parsed.data.status === "disabled" ? "DISABLE" : "ENABLE";
      if (parsed.data.confirmation !== requiredConfirmation) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "AGENT_API_KEY_CONFIRMATION_REQUIRED",
            message: `Agent API key status change requires confirmation: ${requiredConfirmation}`
          }
        });
      }

      const updated = await store.updateAgentApiKey(request.params.keyId, {
        status: parsed.data.status
      });
      if (!updated) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Agent API key not found"
          }
        });
      }

      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: updated.status === "disabled" ? "agent_api_key.disabled" : "agent_api_key.enabled",
        targetType: "api_key",
        targetId: updated.id,
        afterValue: {
          status: updated.status
        }
      });

      return {
        ok: true,
        data: updated
      };
    }
  );

  server.post<{ Params: { keyId: string }; Body: unknown }>(
    "/api/v1/admin/agent-api-keys/:keyId/rotate",
    {
      preHandler: server.authorize("users:write", { global: true })
    },
    async (request, reply) => {
      const parsed = rotateAgentApiKeySchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid Agent API key rotation payload",
            details: parsed.error.flatten()
          }
        });
      }
      if (parsed.data.confirmation !== "ROTATE") {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "AGENT_API_KEY_ROTATE_CONFIRMATION_REQUIRED",
            message: "Agent API key rotation requires confirmation: ROTATE"
          }
        });
      }

      const result = await store.rotateAgentApiKey(request.params.keyId);
      if (!result) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Agent API key not found"
          }
        });
      }

      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "agent_api_key.rotated",
        targetType: "api_key",
        targetId: result.apiKey.id,
        afterValue: {
          keyPrefix: result.apiKey.keyPrefix,
          productIds: result.apiKey.productIds,
          scopes: result.apiKey.scopes,
          status: result.apiKey.status
        }
      });

      return {
        ok: true,
        data: {
          ...result.apiKey,
          key: result.key
        }
      };
    }
  );
}
