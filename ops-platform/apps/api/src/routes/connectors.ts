import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import type { OpsStore } from "../data/store.js";
import {
  ConnectorEncryptionConfigurationError,
  decryptConnectorSecrets,
  encryptConnectorSecrets
} from "../services/connectorSecrets.js";
import type {
  ConnectorTester,
  ConnectorType
} from "../services/connectorTester.js";

const connectorTypeSchema = z.enum([
  "github",
  "smtp",
  "object_storage",
  "agent_api",
  "webhook"
]);

const githubPayload = z.object({
  config: z.object({
    owner: z.string().trim().min(1).max(160),
    repository: z.string().trim().min(1).max(160),
    apiBaseUrl: z.string().url().optional(),
    state: z.enum(["open", "closed", "all"]).optional()
  }),
  secrets: z.object({
    token: z.string().min(1)
  }).optional()
});

const smtpPayload = z.object({
  config: z.object({
    host: z.string().trim().min(1).max(255),
    port: z.number().int().min(1).max(65_535),
    secure: z.boolean(),
    user: z.string().trim().max(320).optional(),
    from: z.string().trim().min(1).max(320),
    replyTo: z.string().trim().max(320).optional()
  }),
  secrets: z.object({
    password: z.string().min(1)
  }).optional()
});

const objectStoragePayload = z.object({
  config: z.object({
    endpoint: z.string().url().optional(),
    region: z.string().trim().min(1).max(120),
    bucket: z.string().trim().min(1).max(255),
    forcePathStyle: z.boolean().optional(),
    publicBaseUrl: z.string().url().optional(),
    objectPrefix: z.string().trim().max(500).optional()
  }),
  secrets: z.object({
    accessKeyId: z.string().min(1),
    secretAccessKey: z.string().min(1),
    sessionToken: z.string().min(1).optional()
  }).optional()
});

const agentApiPayload = z.object({
  config: z.object({
    baseUrl: z.string().url(),
    healthPath: z.string().trim().max(500).optional(),
    headerName: z.string().trim().min(1).max(120).optional()
  }),
  secrets: z.object({
    apiKey: z.string().min(1)
  }).optional()
});

const webhookPayload = z.object({
  config: z.object({
    url: z.string().url(),
    eventTypes: z.array(z.string().trim().min(1).max(120)).default([]),
    signingHeader: z.string().trim().min(1).max(120).optional()
  }),
  secrets: z.object({
    signingSecret: z.string().min(1)
  }).optional()
});

const payloadSchemas = {
  github: githubPayload,
  smtp: smtpPayload,
  object_storage: objectStoragePayload,
  agent_api: agentApiPayload,
  webhook: webhookPayload
} satisfies Record<ConnectorType, z.ZodTypeAny>;

const connectorNames: Record<ConnectorType, string> = {
  github: "GitHub Issues",
  smtp: "SMTP",
  object_storage: "Object Storage",
  agent_api: "Agent API",
  webhook: "Webhook"
};

const disconnectSchema = z.object({
  confirmation: z.literal("DISCONNECT")
});

async function auditConnector(
  store: OpsStore,
  request: FastifyRequest,
  action: string,
  productId: string,
  type: ConnectorType,
  metadata?: Record<string, unknown>
) {
  await store.createAuditLog({
    actorType: "user",
    actorId: request.authPrincipal?.id,
    action,
    targetType: "connector",
    targetId: type,
    productId,
    ipAddress: request.ip,
    userAgent: request.headers["user-agent"],
    metadata
  });
}

function parsedConnectorType(value: string) {
  return connectorTypeSchema.safeParse(value);
}

export async function registerConnectorRoutes(
  server: FastifyInstance,
  store: OpsStore,
  connectorTester: ConnectorTester
) {
  server.put<{
    Params: { productId: string; type: string };
    Body: unknown;
  }>(
    "/api/v1/products/:productId/connectors/:type",
    {
      preHandler: server.authorize("connectors:write")
    },
    async (request, reply) => {
      const typeResult = parsedConnectorType(request.params.type);
      if (!typeResult.success) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Unsupported connector type" }
        });
      }
      const type = typeResult.data;
      const parsed = payloadSchemas[type].safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid connector configuration",
            details: parsed.error.flatten()
          }
        });
      }

      let encryptedSecrets: string | undefined;
      try {
        encryptedSecrets = parsed.data.secrets
          ? encryptConnectorSecrets(parsed.data.secrets)
          : undefined;
      } catch (error) {
        if (error instanceof ConnectorEncryptionConfigurationError) {
          return reply.code(503).send({
            ok: false,
            error: {
              code: "CONNECTOR_ENCRYPTION_NOT_CONFIGURED",
              message: error.message
            }
          });
        }
        throw error;
      }

      const connector = await store.upsertConnector(
        request.params.productId,
        type,
        {
          name: connectorNames[type],
          config: parsed.data.config,
          encryptedSecrets
        }
      );
      if (!connector) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Product not found" }
        });
      }
      await auditConnector(
        store,
        request,
        "connector.configured",
        request.params.productId,
        type,
        {
          hasSecrets: connector.hasSecrets,
          configKeys: Object.keys(connector.config)
        }
      );
      return {
        ok: true,
        data: connector
      };
    }
  );

  server.post<{ Params: { productId: string; type: string } }>(
    "/api/v1/products/:productId/connectors/:type/test",
    {
      preHandler: server.authorize("connectors:write")
    },
    async (request, reply) => {
      const typeResult = parsedConnectorType(request.params.type);
      if (!typeResult.success) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Unsupported connector type" }
        });
      }
      const type = typeResult.data;
      const connector = await store.findConnector(request.params.productId, type);
      if (!connector) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Connector not found" }
        });
      }

      const envelope = await store.getConnectorSecretEnvelope(
        request.params.productId,
        type
      );
      let secrets: Record<string, string> = {};
      try {
        secrets = envelope ? decryptConnectorSecrets(envelope) : {};
      } catch {
        const message = "Stored connector credentials cannot be decrypted";
        await store.recordConnectorTest(request.params.productId, type, {
          succeeded: false,
          error: message,
          testedAt: new Date().toISOString()
        });
        return reply.code(500).send({
          ok: false,
          error: { code: "CONNECTOR_SECRET_DECRYPTION_FAILED", message }
        });
      }

      try {
        const result = await connectorTester.test({
          productId: request.params.productId,
          type,
          config: connector.config,
          secrets
        });
        const testedAt = new Date().toISOString();
        const updated = await store.recordConnectorTest(
          request.params.productId,
          type,
          { succeeded: true, testedAt }
        );
        await auditConnector(
          store,
          request,
          "connector.test_succeeded",
          request.params.productId,
          type,
          result.metadata
        );
        return {
          ok: true,
          data: {
            connector: updated,
            result
          }
        };
      } catch (error) {
        const message = error instanceof Error ? error.message : "Connection test failed";
        await store.recordConnectorTest(request.params.productId, type, {
          succeeded: false,
          error: message,
          testedAt: new Date().toISOString()
        });
        await auditConnector(
          store,
          request,
          "connector.test_failed",
          request.params.productId,
          type,
          { error: message }
        );
        return reply.code(502).send({
          ok: false,
          error: {
            code: "CONNECTOR_TEST_FAILED",
            message
          }
        });
      }
    }
  );

  server.post<{
    Params: { productId: string; type: string };
    Body: unknown;
  }>(
    "/api/v1/products/:productId/connectors/:type/disconnect",
    {
      preHandler: server.authorize("connectors:write")
    },
    async (request, reply) => {
      const typeResult = parsedConnectorType(request.params.type);
      if (!typeResult.success) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Unsupported connector type" }
        });
      }
      const parsed = disconnectSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CONFIRMATION_REQUIRED",
            message: "Type DISCONNECT to confirm connector disconnection"
          }
        });
      }
      const type = typeResult.data;
      const connector = await store.disconnectConnector(
        request.params.productId,
        type
      );
      if (!connector) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Connector not found" }
        });
      }
      await auditConnector(
        store,
        request,
        "connector.disconnected",
        request.params.productId,
        type
      );
      return {
        ok: true,
        data: connector
      };
    }
  );
}
