import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { OpsStore } from "../data/store.js";
import {
  createPresignedUpload,
  ObjectStorageConfigurationError,
  objectStorageUploadCategories
} from "../services/objectStorage.js";
import { resolveObjectStorageSettings } from "../services/releasePublishers.js";

const presignUploadSchema = z.object({
  category: z.enum(objectStorageUploadCategories).default("generic"),
  refId: z.string().min(1).max(120).optional(),
  fileName: z.string().min(1).max(240),
  contentType: z.string().min(1).max(160),
  sizeBytes: z.number().int().positive().max(2_000_000_000),
  dryRun: z.boolean().optional()
});

export async function registerStorageRoutes(server: FastifyInstance, store: OpsStore) {
  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId/storage/presign-upload",
    {
      preHandler: server.authorize("products:write")
    },
    async (request, reply) => {
      const parsed = presignUploadSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid upload presign payload",
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

      try {
        let settings;
        try {
          settings = await resolveObjectStorageSettings(store, request.params.productId);
        } catch (error) {
          if (!parsed.data.dryRun || !(error instanceof ObjectStorageConfigurationError)) {
            throw error;
          }
        }
        const upload = await createPresignedUpload({
          productId: request.params.productId,
          ...parsed.data
        }, settings);
        await store.createAuditLog({
          actorType: "user",
          actorId: request.authPrincipal?.id,
          action: upload.dryRun ? "storage.presign_upload_dry_run" : "storage.presign_upload",
          targetType: parsed.data.category,
          targetId: parsed.data.refId,
          productId: request.params.productId,
          afterValue: {
            objectKey: upload.objectKey,
            bucket: upload.bucket,
            contentType: parsed.data.contentType,
            sizeBytes: parsed.data.sizeBytes
          }
        });
        return {
          ok: true,
          data: upload
        };
      } catch (error) {
        if (error instanceof ObjectStorageConfigurationError) {
          return reply.code(503).send({
            ok: false,
            error: {
              code: "OBJECT_STORAGE_NOT_CONFIGURED",
              message: error.message
            }
          });
        }
        const message = error instanceof Error ? error.message : "Unknown object storage error";
        return reply.code(502).send({
          ok: false,
          error: {
            code: "OBJECT_STORAGE_PRESIGN_FAILED",
            message
          }
        });
      }
    }
  );
}
