import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { AuthStore } from "../auth/store.js";
import type { OpsStore } from "../data/store.js";
import { paginate, paginationQuerySchema } from "./pagination.js";

const createUserSchema = z.object({
  email: z.string().email().max(320),
  name: z.string().trim().min(1).max(160),
  password: z.string().min(8).max(256),
  role: z.string().trim().min(1).max(64),
  productIds: z.array(z.string().trim().min(1).max(64)).max(100).default([])
});

const updateUserSchema = z
  .object({
    name: z.string().trim().min(1).max(160).optional(),
    password: z.string().min(8).max(256).optional(),
    status: z.enum(["active", "disabled"]).optional(),
    role: z.string().trim().min(1).max(64).optional(),
    productIds: z.array(z.string().trim().min(1).max(64)).max(100).optional(),
    confirmation: z.string().optional()
  })
  .refine(
    (value) => Object.keys(value).some((key) => key !== "confirmation"),
    "At least one field is required"
  );

export async function registerAdminUserRoutes(
  server: FastifyInstance,
  authStore: AuthStore,
  opsStore: OpsStore
) {
  server.get<{ Querystring: unknown }>(
    "/api/v1/admin/roles",
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
            message: "Invalid role query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const page = paginate(await authStore.listRoles(), parsedQuery.data);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.get<{ Querystring: unknown }>(
    "/api/v1/admin/users",
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
            message: "Invalid admin user query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const page = paginate(await authStore.listUsers(), parsedQuery.data);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.post<{ Body: unknown }>(
    "/api/v1/admin/users",
    {
      preHandler: server.authorize("users:write", { global: true })
    },
    async (request, reply) => {
      const parsed = createUserSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid admin user payload",
            details: parsed.error.flatten()
          }
        });
      }

      const user = await authStore.createUser(parsed.data);
      if (user === "duplicate") {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "USER_EXISTS",
            message: "Admin user email already exists"
          }
        });
      }
      if (user === "unknown_role") {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "UNKNOWN_ROLE",
            message: "Admin role does not exist"
          }
        });
      }

      await opsStore.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "admin_user.created",
        targetType: "user",
        targetId: user.id,
        afterValue: {
          email: user.email,
          roles: user.roles,
          productIds: user.productIds
        }
      });

      return reply.code(201).send({
        ok: true,
        data: user
      });
    }
  );

  server.patch<{ Params: { userId: string }; Body: unknown }>(
    "/api/v1/admin/users/:userId",
    {
      preHandler: server.authorize("users:write", { global: true })
    },
    async (request, reply) => {
      const parsed = updateUserSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid admin user update",
            details: parsed.error.flatten()
          }
        });
      }

      const requiredConfirmation =
        parsed.data.status === "disabled"
          ? "DISABLE"
          : parsed.data.status === "active"
            ? "ENABLE"
            : undefined;
      if (requiredConfirmation && parsed.data.confirmation !== requiredConfirmation) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "USER_CONFIRMATION_REQUIRED",
            message: `Admin user status change requires confirmation: ${requiredConfirmation}`
          }
        });
      }

      const { confirmation: _confirmation, ...update } = parsed.data;
      const user = await authStore.updateUser(request.params.userId, update);
      if (!user) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Admin user not found"
          }
        });
      }
      if (user === "unknown_role") {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "UNKNOWN_ROLE",
            message: "Admin role does not exist"
          }
        });
      }

      await opsStore.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action:
          parsed.data.status === "disabled"
            ? "admin_user.disabled"
            : parsed.data.status === "active"
              ? "admin_user.enabled"
              : "admin_user.updated",
        targetType: "user",
        targetId: user.id,
        afterValue: {
          email: user.email,
          status: user.status,
          roles: user.roles,
          productIds: user.productIds
        }
      });

      return {
        ok: true,
        data: user
      };
    }
  );
}
