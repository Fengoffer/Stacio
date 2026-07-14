import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import type { Product } from "../data/types.js";
import type { OpsStore } from "../data/store.js";
import { paginate, paginationQuerySchema } from "./pagination.js";

const productIdSchema = z
  .string()
  .min(2)
  .max(64)
  .regex(/^[a-z0-9][a-z0-9_-]*$/);

const optionalUrl = z.string().url().optional();

const createProductSchema = z.object({
  id: productIdSchema,
  name: z.string().trim().min(1).max(160),
  platform: z.string().trim().min(1).max(80),
  bundleId: z.string().trim().min(1).max(255),
  iconUrl: optionalUrl,
  description: z.string().trim().max(4_000).optional(),
  supportEmail: z.string().email().max(320),
  currentStableVersion: z.string().trim().max(80).optional(),
  currentBetaVersion: z.string().trim().max(80).optional(),
  githubOwner: z.string().trim().max(160).optional(),
  githubRepository: z.string().trim().max(160).optional(),
  updateBaseUrl: optionalUrl,
  appcastBaseUrl: optionalUrl,
  licensePolicy: z.record(z.string(), z.unknown()).optional(),
  dataRetentionPolicy: z.record(z.string(), z.unknown()).optional(),
  emailBrand: z.record(z.string(), z.unknown()).optional(),
  objectStoragePrefix: z.string().trim().max(500).optional()
});

const updateProductSchema = createProductSchema.omit({ id: true }).partial().extend({
  status: z.enum(["active", "archived"]).optional()
});

const archiveSchema = z.object({
  confirmation: z.literal("ARCHIVE")
});

const rotateKeySchema = z.object({
  confirmation: z.literal("ROTATE")
});

const productListQuerySchema = paginationQuerySchema.extend({
  search: z.string().trim().optional(),
  status: z.enum(["active", "archived"]).optional(),
  sort_by: z.enum(["id", "name", "platform", "createdAt", "updatedAt"]).default("createdAt"),
  sort_order: z.enum(["asc", "desc"]).default("desc")
});

type ProductListQuery = z.infer<typeof productListQuerySchema>;

function filterProducts(products: Product[], query: ProductListQuery) {
  const search = query.search?.toLowerCase();
  const filtered = products.filter((product) => {
    if (query.status && product.status !== query.status) return false;
    if (
      search &&
      ![product.id, product.name, product.platform, product.bundleId, product.description, product.supportEmail]
        .filter(Boolean)
        .some((value) => value?.toLowerCase().includes(search))
    ) {
      return false;
    }
    return true;
  });

  return filtered.sort((left, right) => {
    const leftValue = String(left[query.sort_by] ?? "");
    const rightValue = String(right[query.sort_by] ?? "");
    const direction = query.sort_order === "asc" ? 1 : -1;
    return leftValue.localeCompare(rightValue) * direction;
  });
}

async function auditProductChange(
  store: OpsStore,
  request: FastifyRequest,
  action: string,
  productId: string,
  beforeValue?: Record<string, unknown>,
  afterValue?: Record<string, unknown>
) {
  await store.createAuditLog({
    actorType: "user",
    actorId: request.authPrincipal?.id,
    action,
    targetType: "product",
    targetId: productId,
    productId,
    beforeValue,
    afterValue,
    ipAddress: request.ip,
    userAgent: request.headers["user-agent"]
  });
}

export async function registerProductRoutes(server: FastifyInstance, store: OpsStore) {
  server.get(
    "/api/v1/products",
    {
      preHandler: server.authorize("products:read")
    },
    async (request, reply) => {
      const parsedQuery = productListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid product query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const products = await store.listProducts();
      const productIds = request.authPrincipal?.productIds ?? [];
      const scopedProducts =
        productIds.length === 0 ? products : products.filter((product) => productIds.includes(product.id));
      const page = paginate(filterProducts(scopedProducts, parsedQuery.data), parsedQuery.data);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.post<{ Body: unknown }>(
    "/api/v1/products",
    {
      preHandler: server.authorize("products:write", { global: true })
    },
    async (request, reply) => {
      const parsed = createProductSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid product payload",
            details: parsed.error.flatten()
          }
        });
      }
      const result = await store.createProduct(parsed.data);
      if (!result) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CONFLICT",
            message: "Product ID already exists"
          }
        });
      }
      await auditProductChange(store, request, "product.created", result.product.id, undefined, {
        name: result.product.name,
        platform: result.product.platform,
        bundleId: result.product.bundleId,
        status: result.product.status
      });
      return reply.code(201).send({
        ok: true,
        data: result
      });
    }
  );

  server.get<{ Params: { productId: string } }>(
    "/api/v1/products/:productId",
    {
      preHandler: server.authorize("products:read")
    },
    async (request, reply) => {
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
      return {
        ok: true,
        data: product
      };
    }
  );

  server.patch<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId",
    {
      preHandler: server.authorize("products:write")
    },
    async (request, reply) => {
      const parsed = updateProductSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid product update",
            details: parsed.error.flatten()
          }
        });
      }
      const before = await store.findProduct(request.params.productId);
      if (!before) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Product not found"
          }
        });
      }
      const product = await store.updateProduct(request.params.productId, parsed.data);
      if (!product) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Product not found"
          }
        });
      }
      await auditProductChange(
        store,
        request,
        "product.updated",
        product.id,
        before as unknown as Record<string, unknown>,
        product as unknown as Record<string, unknown>
      );
      return {
        ok: true,
        data: product
      };
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId/archive",
    {
      preHandler: server.authorize("products:write")
    },
    async (request, reply) => {
      const parsed = archiveSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CONFIRMATION_REQUIRED",
            message: "Type ARCHIVE to confirm product archival"
          }
        });
      }
      const before = await store.findProduct(request.params.productId);
      const product = await store.archiveProduct(request.params.productId);
      if (!before || !product) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Product not found"
          }
        });
      }
      await auditProductChange(
        store,
        request,
        "product.archived",
        product.id,
        before as unknown as Record<string, unknown>,
        product as unknown as Record<string, unknown>
      );
      return {
        ok: true,
        data: product
      };
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId/feedback-api-key/rotate",
    {
      preHandler: server.authorize("products:write")
    },
    async (request, reply) => {
      const parsed = rotateKeySchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CONFIRMATION_REQUIRED",
            message: "Type ROTATE to confirm feedback API key rotation"
          }
        });
      }
      const feedbackApiKey = await store.rotateProductFeedbackApiKey(request.params.productId);
      if (!feedbackApiKey) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Product not found"
          }
        });
      }
      await auditProductChange(store, request, "product.feedback_api_key_rotated", request.params.productId, undefined, {
        rotated: true
      });
      return {
        ok: true,
        data: {
          feedbackApiKey
        }
      };
    }
  );
}
