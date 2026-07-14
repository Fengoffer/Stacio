import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import type { OpsStore } from "../data/store.js";
import { paginate, paginationQuerySchema } from "./pagination.js";

const customerStatusSchema = z.enum([
  "active",
  "trial",
  "blocked",
  "archived",
  "merged"
]);

const createCustomerSchema = z.object({
  email: z.string().trim().email().max(320),
  name: z.string().trim().min(1).max(160),
  company: z.string().trim().max(200).optional(),
  status: customerStatusSchema.exclude(["merged"]).optional(),
  riskFlag: z.boolean().optional()
});

const updateCustomerSchema = z.object({
  email: z.string().trim().email().max(320).optional(),
  name: z.string().trim().min(1).max(160).optional(),
  company: z.string().trim().max(200).nullable().optional(),
  status: customerStatusSchema.exclude(["merged"]).optional(),
  riskFlag: z.boolean().optional()
});

const noteSchema = z.object({
  body: z.string().trim().min(1).max(10_000)
});

const mergeSchema = z.object({
  targetCustomerId: z.string().trim().min(1).max(64),
  confirmation: z.literal("MERGE")
});

async function auditCustomer(
  store: OpsStore,
  request: FastifyRequest,
  action: string,
  productId: string,
  customerId: string,
  beforeValue?: Record<string, unknown>,
  afterValue?: Record<string, unknown>,
  metadata?: Record<string, unknown>
) {
  await store.createAuditLog({
    actorType: "user",
    actorId: request.authPrincipal?.id,
    action,
    targetType: "customer",
    targetId: customerId,
    productId,
    beforeValue,
    afterValue,
    ipAddress: request.ip,
    userAgent: request.headers["user-agent"],
    metadata
  });
}

export async function registerCustomerRoutes(server: FastifyInstance, store: OpsStore) {
  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/customers",
    {
      preHandler: server.authorize("customers:read")
    },
    async (request, reply) => {
      const parsedQuery = paginationQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid customer query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const page = paginate(await store.listCustomers(request.params.productId), parsedQuery.data);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId/customers",
    {
      preHandler: server.authorize("customers:write")
    },
    async (request, reply) => {
      const parsed = createCustomerSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid customer payload",
            details: parsed.error.flatten()
          }
        });
      }
      if (!(await store.findProduct(request.params.productId))) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Product not found" }
        });
      }
      const customer = await store.createCustomer(request.params.productId, parsed.data);
      if (!customer) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CUSTOMER_EMAIL_EXISTS",
            message: "A customer with this email already exists for the product"
          }
        });
      }
      await auditCustomer(
        store,
        request,
        "customer.created",
        request.params.productId,
        customer.id,
        undefined,
        customer as unknown as Record<string, unknown>
      );
      return reply.code(201).send({
        ok: true,
        data: customer
      });
    }
  );

  server.get<{ Params: { productId: string; customerId: string } }>(
    "/api/v1/products/:productId/customers/:customerId",
    {
      preHandler: server.authorize("customers:read")
    },
    async (request, reply) => {
      const detail = await store.customerDetail(
        request.params.productId,
        request.params.customerId
      );
      if (!detail) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Customer not found" }
        });
      }
      return {
        ok: true,
        data: detail
      };
    }
  );

  server.patch<{
    Params: { productId: string; customerId: string };
    Body: unknown;
  }>(
    "/api/v1/products/:productId/customers/:customerId",
    {
      preHandler: server.authorize("customers:write")
    },
    async (request, reply) => {
      const parsed = updateCustomerSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid customer update",
            details: parsed.error.flatten()
          }
        });
      }
      const before = await store.findCustomer(
        request.params.productId,
        request.params.customerId
      );
      if (!before) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Customer not found" }
        });
      }
      const customer = await store.updateCustomer(
        request.params.productId,
        request.params.customerId,
        parsed.data
      );
      if (!customer) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CUSTOMER_EMAIL_EXISTS",
            message: "A customer with this email already exists for the product"
          }
        });
      }
      await auditCustomer(
        store,
        request,
        "customer.updated",
        request.params.productId,
        customer.id,
        before as unknown as Record<string, unknown>,
        customer as unknown as Record<string, unknown>
      );
      return {
        ok: true,
        data: customer
      };
    }
  );

  server.post<{
    Params: { productId: string; customerId: string };
    Body: unknown;
  }>(
    "/api/v1/products/:productId/customers/:customerId/notes",
    {
      preHandler: server.authorize("customers:write")
    },
    async (request, reply) => {
      const parsed = noteSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid customer note",
            details: parsed.error.flatten()
          }
        });
      }
      const note = await store.addCustomerNote(
        request.params.productId,
        request.params.customerId,
        {
          body: parsed.data.body,
          authorId: request.authPrincipal?.id
        }
      );
      if (!note) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Customer not found" }
        });
      }
      await auditCustomer(
        store,
        request,
        "customer.note_added",
        request.params.productId,
        request.params.customerId,
        undefined,
        undefined,
        { noteId: note.id }
      );
      return reply.code(201).send({
        ok: true,
        data: note
      });
    }
  );

  server.post<{
    Params: { productId: string; customerId: string };
    Body: unknown;
  }>(
    "/api/v1/products/:productId/customers/:customerId/merge",
    {
      preHandler: server.authorize("customers:write")
    },
    async (request, reply) => {
      const parsed = mergeSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CONFIRMATION_REQUIRED",
            message: "Type MERGE to confirm customer merge"
          }
        });
      }
      const result = await store.mergeCustomers(
        request.params.productId,
        request.params.customerId,
        parsed.data.targetCustomerId
      );
      if (!result) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "CUSTOMER_MERGE_INVALID",
            message: "Source or target customer is not available for merge"
          }
        });
      }
      await auditCustomer(
        store,
        request,
        "customer.merged",
        request.params.productId,
        request.params.customerId,
        undefined,
        undefined,
        {
          sourceCustomerId: request.params.customerId,
          targetCustomerId: parsed.data.targetCustomerId
        }
      );
      return {
        ok: true,
        data: result
      };
    }
  );
}
