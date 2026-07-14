import { randomUUID } from "node:crypto";
import cors from "@fastify/cors";
import Fastify, { type FastifyRequest } from "fastify";
import { registerAuth } from "./auth/plugin.js";
import { createMemoryAuthStore, type AuthStore } from "./auth/store.js";
import { createMemoryStore, type OpsStore } from "./data/store.js";
import { createRuntimeStore } from "./db/runtime.js";
import { createBullMqJobQueue, type OpsJobQueue } from "./jobs/queue.js";
import {
  createPublicFeedbackRateLimiter,
  createPublicTelemetryRateLimiter,
  type PublicRateLimiter
} from "./services/publicRateLimiter.js";
import {
  createConnectorTester,
  type ConnectorTester
} from "./services/connectorTester.js";
import { registerAgentRoutes } from "./routes/agent.js";
import { registerAgentApiKeyRoutes } from "./routes/agentApiKeys.js";
import { registerAdminConfigRoutes } from "./routes/adminConfig.js";
import { registerAdminUserRoutes } from "./routes/adminUsers.js";
import { registerAuditLogRoutes } from "./routes/auditLogs.js";
import { registerConnectorRoutes } from "./routes/connectors.js";
import { registerCustomerRoutes } from "./routes/customers.js";
import { registerDashboardRoutes } from "./routes/dashboard.js";
import { registerFeedbackRoutes } from "./routes/feedback.js";
import { registerGitHubIssueRoutes } from "./routes/githubIssues.js";
import { registerGitHubMetricsRoutes } from "./routes/githubMetrics.js";
import { registerHealthRoutes } from "./routes/health.js";
import { registerLicenseRoutes } from "./routes/licenses.js";
import { registerNotificationRoutes } from "./routes/notifications.js";
import { registerProductRoutes } from "./routes/products.js";
import { registerPublicSiteRoutes } from "./routes/publicSite.js";
import { registerReleaseRoutes } from "./routes/releases.js";
import { registerStorageRoutes } from "./routes/storage.js";

export interface BuildServerOptions {
  store?: OpsStore;
  authStore?: AuthStore;
  jobQueue?: OpsJobQueue;
  publicFeedbackRateLimiter?: PublicRateLimiter;
  publicTelemetryRateLimiter?: PublicRateLimiter;
  connectorTester?: ConnectorTester;
  onClose?: () => Promise<void>;
}

const requestTraceIds = new WeakMap<FastifyRequest, string>();

function firstHeaderValue(value: string | string[] | undefined) {
  return Array.isArray(value) ? value[0] : value;
}

function resolveRequestTraceId(request: FastifyRequest) {
  return firstHeaderValue(request.headers["x-request-id"]) || request.id || randomUUID();
}

function isPlainJsonObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value) && !Buffer.isBuffer(value);
}

function withResponseMeta(payload: unknown, requestId: string) {
  if (!isPlainJsonObject(payload) || isPlainJsonObject(payload.meta)) {
    return payload;
  }

  return {
    ...payload,
    meta: {
      request_id: requestId,
      timestamp: new Date().toISOString()
    }
  };
}

export function buildServer(options: BuildServerOptions = {}) {
  const server = Fastify({
    logger: process.env.NODE_ENV === "production",
    trustProxy: process.env.TRUST_PROXY === "true"
  });
  const store = options.store ?? createMemoryStore();
  const authStore = options.authStore ?? createMemoryAuthStore();
  const jobQueue = options.jobQueue;
  const publicFeedbackRateLimiter = options.publicFeedbackRateLimiter ?? createPublicFeedbackRateLimiter();
  const publicTelemetryRateLimiter = options.publicTelemetryRateLimiter ?? createPublicTelemetryRateLimiter();
  const connectorTester = options.connectorTester ?? createConnectorTester();

  if (options.onClose) {
    server.addHook("onClose", options.onClose);
  }

  void server.register(cors, {
    origin: true
  });
  server.addHook("onRequest", async (request, reply) => {
    const requestId = resolveRequestTraceId(request);
    requestTraceIds.set(request, requestId);
    reply.header("x-request-id", requestId);
  });
  server.addHook("preSerialization", async (request, _reply, payload) => {
    const requestId = requestTraceIds.get(request) ?? resolveRequestTraceId(request);
    return withResponseMeta(payload, requestId);
  });
  registerAuth(server, authStore, store);
  void server.register(registerHealthRoutes);
  void server.register(async (instance) => {
    await registerProductRoutes(instance, store);
    await registerAdminUserRoutes(instance, authStore, store);
    await registerAgentApiKeyRoutes(instance, store);
    await registerAdminConfigRoutes(instance, store);
    await registerConnectorRoutes(instance, store, connectorTester);
    await registerCustomerRoutes(instance, store);
    await registerDashboardRoutes(instance, store);
    await registerFeedbackRoutes(instance, store, publicFeedbackRateLimiter, jobQueue);
    await registerPublicSiteRoutes(instance, store, publicTelemetryRateLimiter);
    await registerGitHubIssueRoutes(instance, store, jobQueue);
    await registerGitHubMetricsRoutes(instance, store);
    await registerReleaseRoutes(instance, store, jobQueue);
    await registerLicenseRoutes(instance, store, jobQueue);
    await registerNotificationRoutes(instance, store, jobQueue);
    await registerStorageRoutes(instance, store);
    await registerAgentRoutes(instance, store);
    await registerAuditLogRoutes(instance, store);
  });

  return server;
}

async function start() {
  const runtime = await createRuntimeStore();
  const jobQueue = process.env.REDIS_URL ? createBullMqJobQueue(process.env.REDIS_URL) : undefined;
  const server = buildServer({
    store: runtime.store,
    authStore: runtime.authStore,
    jobQueue,
    onClose: async () => {
      await jobQueue?.close?.();
      await runtime.close();
    }
  });
  const port = Number(process.env.API_PORT ?? 8080);
  await server.listen({
    host: "0.0.0.0",
    port
  });
  server.log.info({ persistence: runtime.persistence }, "API persistence initialized");
}

if (import.meta.url === `file://${process.argv[1]}`) {
  start().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
