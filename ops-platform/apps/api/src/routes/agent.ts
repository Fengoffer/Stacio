import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import type { OpsStore, UpdateFeedbackInput } from "../data/store.js";
import type { AiProposedActionItem, FeedbackItem } from "../data/types.js";
import { paginate, paginationQuerySchema } from "./pagination.js";

const agentAnalysisSchema = z.object({
  agentIdentity: z.string().min(1).max(160).default("external-agent"),
  provider: z.string().max(80).optional(),
  model: z.string().max(160).optional(),
  analysisType: z.string().min(1).max(80),
  inputReferences: z.record(z.string(), z.unknown()).optional(),
  outputBody: z.record(z.string(), z.unknown()),
  confidence: z.string().max(32).optional()
});

const agentReplyDraftSchema = z.object({
  agentIdentity: z.string().min(1).max(160).default("external-agent"),
  provider: z.string().max(80).optional(),
  model: z.string().max(160).optional(),
  replyDraft: z.string().min(1).max(50_000),
  tone: z.string().max(80).optional(),
  inputReferences: z.record(z.string(), z.unknown()).optional(),
  confidence: z.string().max(32).optional()
});

const adminAgentRequestSchema = z.object({
  requestType: z.enum(["summary", "reply_draft"]),
  agentHint: z.string().trim().min(1).max(160).optional(),
  prompt: z.string().trim().min(1).max(10_000)
});

const adminReleaseAgentRequestSchema = z.object({
  requestType: z.enum(["release_notes", "release_risk"]),
  agentHint: z.string().trim().min(1).max(160).optional(),
  prompt: z.string().trim().min(1).max(10_000)
});

const agentNotificationDraftSchema = z.object({
  agentIdentity: z.string().min(1).max(160).default("external-agent"),
  type: z.string().min(1).max(80),
  recipient: z.string().email(),
  payload: z.record(z.string(), z.unknown()).default({}),
  priority: z.enum(["low", "normal", "high", "urgent"]).optional(),
  scheduledAt: z.string().datetime().optional()
});

const agentProposedActionSchema = z.object({
  agentIdentity: z.string().min(1).max(160).default("external-agent"),
  provider: z.string().max(80).optional(),
  model: z.string().max(160).optional(),
  targetType: z.enum(["feedback", "release", "github_issue"]),
  targetId: z.string().min(1).max(64),
  actionType: z.string().min(1).max(80),
  payload: z.record(z.string(), z.unknown()),
  rationale: z.string().max(10_000).optional(),
  inputReferences: z.record(z.string(), z.unknown()).optional(),
  confidence: z.string().max(32).optional()
});

const aiReviewSchema = z.object({
  adoptionState: z.enum(["accepted", "edited_accepted", "ignored"]),
  outputBody: z.record(z.string(), z.unknown()).optional()
});

const proposedActionReviewSchema = z.object({
  status: z.enum(["accepted", "rejected", "dismissed"])
});

const proposedActionExecutionSchema = z.object({
  confirmation: z.string().trim().optional()
});

const aiAnalysisListQuerySchema = paginationQuerySchema.extend({
  targetType: z.enum(["feedback", "release", "github_issue"]).optional(),
  targetId: z.string().trim().optional()
});

const proposedActionListQuerySchema = paginationQuerySchema.extend({
  status: z.string().trim().optional()
});

const agentRequestListQuerySchema = paginationQuerySchema.extend({
  status: z.string().trim().optional()
});

const agentFeedbackTriageQueueQuerySchema = paginationQuerySchema;

const agentGitHubIssueListQuerySchema = paginationQuerySchema.extend({
  state: z.enum(["open", "closed"]).optional(),
  search: z.string().trim().optional()
});

const agentCustomerListQuerySchema = paginationQuerySchema.extend({
  status: z.string().trim().optional(),
  search: z.string().trim().optional()
});

const agentLicenseListQuerySchema = paginationQuerySchema.extend({
  status: z.string().trim().optional(),
  plan: z.string().trim().optional(),
  search: z.string().trim().optional()
});

const agentReleaseDraftListQuerySchema = paginationQuerySchema.extend({
  channel: z.string().trim().optional()
});

const executableFeedbackStatuses = [
  "new",
  "triaged",
  "in_progress",
  "waiting_for_user",
  "resolved",
  "closed"
] as const;
const executableFeedbackPriorities = ["P0", "P1", "P2", "P3"] as const;

const feedbackStatusActionPayloadSchema = z.object({
  status: z.enum(executableFeedbackStatuses)
});

const feedbackPriorityActionPayloadSchema = z.object({
  priority: z.enum(executableFeedbackPriorities)
});

const agentKeySchema = z.object({
  id: z.string().min(1).max(160),
  key: z.string().min(8),
  name: z.string().max(160).optional(),
  productIds: z.array(z.string().min(1)).default([]),
  scopes: z.array(z.string().min(1)).default([]),
  expiresAt: z.string().datetime().optional()
});

type AgentKeyRecord = z.infer<typeof agentKeySchema>;
type AgentCredential = {
  id: string;
  name?: string;
  productIds: string[];
  scopes: string[];
  expiresAt?: string;
  status: string;
  source: "store" | "env";
};

function legacyAgentKey(): AgentKeyRecord | undefined {
  if (process.env.AGENT_API_KEY) {
    return {
      id: "agent_legacy",
      key: process.env.AGENT_API_KEY,
      name: "Legacy Agent API key",
      productIds: [],
      scopes: ["*"]
    };
  }
  if (process.env.NODE_ENV === "production") {
    return undefined;
  }
  return {
    id: "agent_development",
    key: "development-agent-key",
    name: "Development Agent API key",
    productIds: [],
    scopes: ["*"]
  };
}

function suggestedPriority(outputBody: Record<string, unknown>) {
  const priority = outputBody.prioritySuggestion;
  return ["P0", "P1", "P2", "P3"].includes(String(priority)) ? (priority as "P0" | "P1" | "P2" | "P3") : undefined;
}

function configuredAgentKeys() {
  if (process.env.AGENT_API_KEYS_JSON) {
    const parsed = z.array(agentKeySchema).safeParse(JSON.parse(process.env.AGENT_API_KEYS_JSON));
    return parsed.success ? parsed.data : [];
  }
  const legacy = legacyAgentKey();
  return legacy ? [legacy] : [];
}

function extractAgentToken(request: FastifyRequest) {
  const header = request.headers.authorization;
  const token = header?.startsWith("Bearer ") ? header.slice("Bearer ".length) : request.headers["x-agent-api-key"];
  return Array.isArray(token) ? token[0] : token;
}

function agentCanAccessProduct(agent: AgentCredential, productId: string) {
  return agent.productIds.length === 0 || agent.productIds.includes(productId);
}

function agentHasScope(agent: AgentCredential, requiredScope: string) {
  return agent.scopes.includes("*") || agent.scopes.includes(requiredScope);
}

async function resolveAgentCredential(
  store: OpsStore,
  token: string | undefined
): Promise<{ agent?: AgentCredential; configInvalid?: boolean }> {
  if (!token) {
    return {};
  }
  const stored = await store.findAgentApiKeyByToken(token);
  if (stored) {
    return {
      agent: {
        id: stored.id,
        name: stored.name,
        productIds: stored.productIds,
        scopes: stored.scopes,
        expiresAt: stored.expiresAt,
        status: stored.status,
        source: "store"
      }
    };
  }
  try {
    const agent = configuredAgentKeys().find((item) => item.key === token);
    return agent
      ? {
          agent: {
            id: agent.id,
            name: agent.name,
            productIds: agent.productIds,
            scopes: agent.scopes,
            expiresAt: agent.expiresAt,
            status: "active",
            source: "env"
          }
        }
      : {};
  } catch {
    return { configInvalid: true };
  }
}

async function auditAgentDenial(
  store: OpsStore,
  request: FastifyRequest,
  agent: AgentCredential | undefined,
  productId: string | undefined,
  reason: string,
  requiredScope?: string
) {
  await store.createAuditLog({
    actorType: agent ? "agent" : "public",
    actorId: agent?.id,
    action: "agent.authorization_denied",
    targetType: "agent_api",
    targetId: requiredScope,
    productId,
    ipAddress: request.ip,
    userAgent: request.headers["user-agent"],
    metadata: {
      method: request.method,
      url: request.url,
      reason,
      requiredScope
    }
  });
}

function authenticateAgent(store: OpsStore, requiredScope: string) {
  return async function agentPreHandler(request: FastifyRequest, reply: FastifyReply) {
    const token = extractAgentToken(request);
    const resolved = await resolveAgentCredential(store, token);
    if (resolved.configInvalid) {
      return reply.code(503).send({
        ok: false,
        error: {
          code: "AGENT_API_KEY_CONFIG_INVALID",
          message: "Agent API key configuration is invalid"
        }
      });
    }
    const agent = resolved.agent;
    if (!agent) {
      await auditAgentDenial(store, request, undefined, undefined, "UNAUTHORIZED_AGENT", requiredScope);
      return reply.code(401).send({
        ok: false,
        error: {
          code: "UNAUTHORIZED_AGENT",
          message: "Agent authentication required"
        }
      });
    }
    const params = request.params as Record<string, unknown> | undefined;
    const productId = typeof params?.productId === "string" ? params.productId : undefined;
    if (agent.status === "disabled") {
      await auditAgentDenial(store, request, agent, productId, "AGENT_KEY_DISABLED", requiredScope);
      return reply.code(401).send({
        ok: false,
        error: {
          code: "AGENT_KEY_DISABLED",
          message: "Agent API key is disabled"
        }
      });
    }
    if (agent.expiresAt && new Date(agent.expiresAt).getTime() <= Date.now()) {
      await auditAgentDenial(store, request, agent, productId, "AGENT_KEY_EXPIRED", requiredScope);
      return reply.code(401).send({
        ok: false,
        error: {
          code: "AGENT_KEY_EXPIRED",
          message: "Agent API key has expired"
        }
      });
    }
    if (productId && !agentCanAccessProduct(agent, productId)) {
      await auditAgentDenial(store, request, agent, productId, "AGENT_PRODUCT_ACCESS_DENIED", requiredScope);
      return reply.code(403).send({
        ok: false,
        error: {
          code: "AGENT_PRODUCT_ACCESS_DENIED",
          message: "Agent is not allowed to access this product"
        }
      });
    }
    if (!agentHasScope(agent, requiredScope)) {
      await auditAgentDenial(store, request, agent, productId, "AGENT_SCOPE_DENIED", requiredScope);
      return reply.code(403).send({
        ok: false,
        error: {
          code: "AGENT_SCOPE_DENIED",
          message: "Agent scope is not allowed for this action"
        }
      });
    }
    if (agent.source === "store") {
      await store.touchAgentApiKeyLastUsed(agent.id);
    }
  };
}

function safeConfiguredAgentKeys() {
  try {
    return configuredAgentKeys();
  } catch {
    return [];
  }
}

function agentReadOnlyPolicy() {
  return {
    customerVisibleEmailSent: false,
    publicGitHubReplySent: false,
    otaPublished: false,
    licenseChanged: false,
    licenseKeyRevealed: false
  };
}

function agentNotificationDraftPolicy() {
  return {
    customerVisibleEmailSent: false,
    notificationSent: false,
    publicGitHubReplySent: false,
    otaPublished: false,
    licenseChanged: false
  };
}

function proposedActionReviewOnlyPolicy() {
  return {
    actionExecuted: false,
    customerVisibleEmailSent: false,
    publicGitHubReplySent: false,
    otaPublished: false,
    licenseChanged: false,
    feedbackDeleted: false
  };
}

function proposedActionExecutionPolicy(actionExecuted: boolean) {
  return {
    actionExecuted,
    customerVisibleEmailSent: false,
    publicGitHubReplySent: false,
    otaPublished: false,
    licenseChanged: false,
    feedbackDeleted: false
  };
}

function agentRequestPolicy() {
  return {
    customerVisibleEmailSent: false,
    publicGitHubReplySent: false,
    otaPublished: false,
    licenseChanged: false,
    feedbackDeleted: false,
    actionExecuted: false
  };
}

function agentRequestReadPolicy() {
  return {
    customerVisibleEmailSent: false,
    publicGitHubReplySent: false,
    otaPublished: false,
    licenseChanged: false,
    feedbackDeleted: false
  };
}

function releaseDraftUpdateFromOutput(outputBody: Record<string, unknown>) {
  return {
    releaseNotes:
      typeof outputBody.releaseNotesDraft === "string"
        ? outputBody.releaseNotesDraft
        : typeof outputBody.releaseNotes === "string"
          ? outputBody.releaseNotes
          : undefined,
    aiReleaseSummary:
      typeof outputBody.summary === "string"
        ? outputBody.summary
        : typeof outputBody.releaseSummary === "string"
          ? outputBody.releaseSummary
          : undefined,
    aiRiskSummary:
      typeof outputBody.riskSummary === "string"
        ? outputBody.riskSummary
        : typeof outputBody.aiRiskSummary === "string"
          ? outputBody.aiRiskSummary
          : undefined
  };
}

async function ensureAgentConfigurationIsParseable(request: FastifyRequest, reply: FastifyReply) {
  if (process.env.AGENT_API_KEYS_JSON && safeConfiguredAgentKeys().length === 0 && !extractAgentToken(request)) {
    return reply.code(503).send({
      ok: false,
      error: {
        code: "AGENT_API_KEY_CONFIG_INVALID",
        message: "Agent API key configuration is invalid"
      }
    });
  }
}

type ProposedActionExecutionResult = {
  targetType: "feedback";
  targetId: string;
  changes: UpdateFeedbackInput;
  feedback: FeedbackItem;
};

type ProposedActionExecutionOutcome =
  | {
      ok: true;
      result: ProposedActionExecutionResult;
    }
  | {
      ok: false;
      statusCode: 404 | 409 | 422;
      code: string;
      message: string;
      details?: Record<string, unknown>;
    };

async function executeAcceptedProposedAction(
  store: OpsStore,
  productId: string,
  action: AiProposedActionItem
): Promise<ProposedActionExecutionOutcome> {
  if (action.targetType !== "feedback") {
    return {
      ok: false,
      statusCode: 409,
      code: "ACTION_TYPE_NOT_EXECUTABLE",
      message: "This proposed action type is not executable from the Agent review queue"
    };
  }

  let changes: UpdateFeedbackInput | undefined;
  if (action.actionType === "feedback.update_status") {
    const parsed = feedbackStatusActionPayloadSchema.safeParse(action.payload);
    if (!parsed.success) {
      return {
        ok: false,
        statusCode: 422,
        code: "ACTION_PAYLOAD_INVALID",
        message: "Invalid feedback status action payload",
        details: parsed.error.flatten()
      };
    }
    changes = { status: parsed.data.status };
  } else if (action.actionType === "feedback.update_priority") {
    const parsed = feedbackPriorityActionPayloadSchema.safeParse(action.payload);
    if (!parsed.success) {
      return {
        ok: false,
        statusCode: 422,
        code: "ACTION_PAYLOAD_INVALID",
        message: "Invalid feedback priority action payload",
        details: parsed.error.flatten()
      };
    }
    changes = { priority: parsed.data.priority };
  } else {
    return {
      ok: false,
      statusCode: 409,
      code: "ACTION_TYPE_NOT_EXECUTABLE",
      message: "This proposed action type is not executable from the Agent review queue"
    };
  }

  const feedback = await store.updateFeedback(productId, action.targetId, changes);
  if (!feedback) {
    return {
      ok: false,
      statusCode: 404,
      code: "FEEDBACK_NOT_FOUND",
      message: "Feedback not found"
    };
  }

  return {
    ok: true,
    result: {
      targetType: "feedback",
      targetId: action.targetId,
      changes,
      feedback
    }
  };
}

async function auditProposedActionExecutionBlocked(
  store: OpsStore,
  request: FastifyRequest,
  action: AiProposedActionItem,
  reason: string
) {
  await store.createAuditLog({
    actorType: "user",
    actorId: request.authPrincipal?.id,
    action: "ai_proposed_action.execution_blocked",
    targetType: "ai_proposed_action",
    targetId: action.id,
    productId: action.productId,
    ipAddress: request.ip,
    userAgent: request.headers["user-agent"],
    afterValue: {
      reason,
      status: action.status,
      actionType: action.actionType,
      targetType: action.targetType,
      targetId: action.targetId
    }
  });
}

export async function registerAgentRoutes(server: FastifyInstance, store: OpsStore) {
  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/ai-analysis",
    {
      preHandler: server.authorize("feedback:read")
    },
    async (request, reply) => {
      const parsedQuery = aiAnalysisListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid AI analysis query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const query = parsedQuery.data;
      const page = paginate(
        await store.listAiAnalysis(request.params.productId, query.targetType, query.targetId),
        query
      );
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.patch<{ Params: { productId: string; analysisId: string }; Body: unknown }>(
    "/api/v1/products/:productId/ai-analysis/:analysisId",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = aiReviewSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid AI analysis review payload",
            details: parsed.error.flatten()
          }
        });
      }

      const existing = (await store.listAiAnalysis(request.params.productId)).find(
        (item) => item.id === request.params.analysisId
      );
      if (!existing) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "AI analysis not found"
          }
        });
      }

      const outputBody = parsed.data.outputBody ?? existing.outputBody;
      const reviewed = await store.reviewAiAnalysis(request.params.productId, request.params.analysisId, {
        adoptionState: parsed.data.adoptionState,
        outputBody,
        reviewedBy: request.authPrincipal?.id
      });
      if (!reviewed) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "AI analysis not found"
          }
        });
      }

      if (["accepted", "edited_accepted"].includes(parsed.data.adoptionState) && reviewed.targetType === "feedback") {
        await store.updateFeedback(request.params.productId, reviewed.targetId, {
          aiSummary: typeof outputBody.summary === "string" ? outputBody.summary : undefined,
          aiClassification: typeof outputBody.classification === "string" ? outputBody.classification : undefined,
          aiSuggestedPriority: suggestedPriority(outputBody)
        });
      }

      if (["accepted", "edited_accepted"].includes(parsed.data.adoptionState) && reviewed.targetType === "release") {
        const releaseDraft = releaseDraftUpdateFromOutput(outputBody);
        const hasReleaseDraftUpdate = Object.values(releaseDraft).some((value) => value !== undefined);
        if (hasReleaseDraftUpdate) {
          const updatedRelease = await store.updateReleaseDraft(
            request.params.productId,
            reviewed.targetId,
            releaseDraft
          );
          if (updatedRelease) {
            await store.createAuditLog({
              actorType: "user",
              actorId: request.authPrincipal?.id,
              action: "release.ai_analysis_applied",
              targetType: "release",
              targetId: updatedRelease.id,
              productId: request.params.productId,
              ipAddress: request.ip,
              userAgent: request.headers["user-agent"],
              afterValue: {
                analysisId: reviewed.id,
                releaseNotesUpdated: releaseDraft.releaseNotes !== undefined,
                aiReleaseSummaryUpdated: releaseDraft.aiReleaseSummary !== undefined,
                aiRiskSummaryUpdated: releaseDraft.aiRiskSummary !== undefined
              }
            });
          }
        }
      }

      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "ai_analysis.reviewed",
        targetType: "ai_analysis",
        targetId: reviewed.id,
        productId: request.params.productId,
        ipAddress: request.ip,
        userAgent: request.headers["user-agent"],
        afterValue: {
          adoptionState: reviewed.adoptionState,
          targetType: reviewed.targetType,
          targetId: reviewed.targetId
        }
      });

      return {
        ok: true,
        data: reviewed,
        policy: {
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false
        }
      };
    }
  );

  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/proposed-actions",
    {
      preHandler: server.authorize("feedback:read")
    },
    async (request, reply) => {
      const parsedQuery = proposedActionListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid proposed action query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const query = parsedQuery.data;
      const page = paginate(await store.listProposedActions(request.params.productId, query.status), query);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.patch<{ Params: { productId: string; actionId: string }; Body: unknown }>(
    "/api/v1/products/:productId/proposed-actions/:actionId",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = proposedActionReviewSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid proposed action review payload",
            details: parsed.error.flatten()
          }
        });
      }

      const reviewed = await store.reviewProposedAction(request.params.productId, request.params.actionId, {
        status: parsed.data.status,
        reviewedBy: request.authPrincipal?.id
      });
      if (!reviewed) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Proposed action not found"
          }
        });
      }

      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "ai_proposed_action.reviewed",
        targetType: "ai_proposed_action",
        targetId: reviewed.id,
        productId: request.params.productId,
        ipAddress: request.ip,
        userAgent: request.headers["user-agent"],
        afterValue: {
          status: reviewed.status,
          actionType: reviewed.actionType,
          targetType: reviewed.targetType,
          targetId: reviewed.targetId
        }
      });

      return {
        ok: true,
        data: reviewed,
        policy: proposedActionReviewOnlyPolicy()
      };
    }
  );

  server.post<{ Params: { productId: string; actionId: string }; Body: unknown }>(
    "/api/v1/products/:productId/proposed-actions/:actionId/execute",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = proposedActionExecutionSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid proposed action execution payload",
            details: parsed.error.flatten()
          },
          policy: proposedActionExecutionPolicy(false)
        });
      }

      const action = (await store.listProposedActions(request.params.productId)).find(
        (item) => item.id === request.params.actionId
      );
      if (!action) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Proposed action not found"
          },
          policy: proposedActionExecutionPolicy(false)
        });
      }

      if (parsed.data.confirmation !== "EXECUTE") {
        await auditProposedActionExecutionBlocked(store, request, action, "CONFIRMATION_REQUIRED");
        return reply.code(409).send({
          ok: false,
          error: {
            code: "ACTION_EXECUTION_CONFIRMATION_REQUIRED",
            message: "Type EXECUTE to run an accepted proposed action"
          },
          policy: proposedActionExecutionPolicy(false)
        });
      }

      if (action.status === "executed") {
        await auditProposedActionExecutionBlocked(store, request, action, "ACTION_ALREADY_EXECUTED");
        return reply.code(409).send({
          ok: false,
          error: {
            code: "ACTION_ALREADY_EXECUTED",
            message: "This proposed action has already been executed"
          },
          policy: proposedActionExecutionPolicy(false)
        });
      }

      if (action.status !== "accepted") {
        await auditProposedActionExecutionBlocked(store, request, action, "ACTION_REVIEW_REQUIRED");
        return reply.code(409).send({
          ok: false,
          error: {
            code: "ACTION_REVIEW_REQUIRED",
            message: "Only accepted proposed actions can be executed"
          },
          policy: proposedActionExecutionPolicy(false)
        });
      }

      const beforeFeedback =
        action.targetType === "feedback"
          ? await store.findFeedback(request.params.productId, action.targetId)
          : undefined;
      const outcome = await executeAcceptedProposedAction(store, request.params.productId, action);
      if (!outcome.ok) {
        await auditProposedActionExecutionBlocked(store, request, action, outcome.code);
        return reply.code(outcome.statusCode).send({
          ok: false,
          error: {
            code: outcome.code,
            message: outcome.message,
            details: outcome.details
          },
          policy: proposedActionExecutionPolicy(false)
        });
      }

      if (beforeFeedback) {
        await store.createAuditLog({
          actorType: "user",
          actorId: request.authPrincipal?.id,
          action: "feedback.updated",
          targetType: "feedback",
          targetId: outcome.result.targetId,
          productId: request.params.productId,
          beforeValue: structuredClone(beforeFeedback) as unknown as Record<string, unknown>,
          afterValue: outcome.result.feedback as unknown as Record<string, unknown>,
          ipAddress: request.ip,
          userAgent: request.headers["user-agent"],
          metadata: {
            proposedActionId: action.id,
            actionType: action.actionType
          }
        });
      }

      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "ai_proposed_action.executed",
        targetType: "ai_proposed_action",
        targetId: action.id,
        productId: request.params.productId,
        ipAddress: request.ip,
        userAgent: request.headers["user-agent"],
        afterValue: {
          actionType: action.actionType,
          targetType: outcome.result.targetType,
          targetId: outcome.result.targetId,
          changes: outcome.result.changes
        }
      });

      const executedAction = await store.reviewProposedAction(request.params.productId, action.id, {
        status: "executed",
        reviewedBy: request.authPrincipal?.id
      });

      return {
        ok: true,
        data: {
          action: executedAction ?? {
            ...action,
            status: "executed"
          },
          result: outcome.result
        },
        policy: proposedActionExecutionPolicy(true)
      };
    }
  );

  server.get<{ Params: { productId: string; feedbackId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/feedback/:feedbackId/agent-requests",
    {
      preHandler: server.authorize("feedback:read")
    },
    async (request, reply) => {
      const parsedQuery = agentRequestListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid Agent request query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const feedback = await store.findFeedback(request.params.productId, request.params.feedbackId);
      if (!feedback) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Feedback not found"
          }
        });
      }
      const query = parsedQuery.data;
      const page = paginate(
        await store.listAgentRequests(request.params.productId, {
          targetType: "feedback",
          targetId: request.params.feedbackId,
          status: query.status
        }),
        query
      );
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.post<{ Params: { productId: string; feedbackId: string }; Body: unknown }>(
    "/api/v1/products/:productId/feedback/:feedbackId/agent-requests",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = adminAgentRequestSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid Agent request payload",
            details: parsed.error.flatten()
          }
        });
      }

      const feedback = await store.findFeedback(request.params.productId, request.params.feedbackId);
      if (!feedback) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Feedback not found"
          }
        });
      }

      const agentRequest = await store.createAgentRequest({
        productId: request.params.productId,
        targetType: "feedback",
        targetId: request.params.feedbackId,
        requestType: parsed.data.requestType,
        agentHint: parsed.data.agentHint,
        prompt: parsed.data.prompt,
        requestedBy: request.authPrincipal?.id,
        metadata: {
          source: "admin_feedback_detail",
          feedbackTitle: feedback.title
        }
      });
      if (!agentRequest) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Product not found"
          }
        });
      }

      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "agent_request.created",
        targetType: "agent_request",
        targetId: agentRequest.id,
        productId: request.params.productId,
        ipAddress: request.ip,
        userAgent: request.headers["user-agent"],
        afterValue: {
          targetType: agentRequest.targetType,
          targetId: agentRequest.targetId,
          requestType: agentRequest.requestType,
          agentHint: agentRequest.agentHint
        }
      });

      return reply.code(201).send({
        ok: true,
        data: agentRequest,
        policy: agentRequestPolicy()
      });
    }
  );

  server.get<{ Params: { productId: string; releaseId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/releases/:releaseId/agent-requests",
    {
      preHandler: server.authorize("releases:read")
    },
    async (request, reply) => {
      const parsedQuery = agentRequestListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid release Agent request query",
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
      const query = parsedQuery.data;
      const page = paginate(
        await store.listAgentRequests(request.params.productId, {
          targetType: "release",
          targetId: request.params.releaseId,
          status: query.status
        }),
        query
      );
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.post<{ Params: { productId: string; releaseId: string }; Body: unknown }>(
    "/api/v1/products/:productId/releases/:releaseId/agent-requests",
    {
      preHandler: server.authorize("releases:write")
    },
    async (request, reply) => {
      const parsed = adminReleaseAgentRequestSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid release Agent request payload",
            details: parsed.error.flatten()
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

      const agentRequest = await store.createAgentRequest({
        productId: request.params.productId,
        targetType: "release",
        targetId: request.params.releaseId,
        requestType: parsed.data.requestType,
        agentHint: parsed.data.agentHint,
        prompt: parsed.data.prompt,
        requestedBy: request.authPrincipal?.id,
        metadata: {
          source: "admin_release_detail",
          releaseVersion: release.version,
          releaseChannel: release.channel
        }
      });
      if (!agentRequest) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Product not found"
          }
        });
      }

      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "agent_request.created",
        targetType: "agent_request",
        targetId: agentRequest.id,
        productId: request.params.productId,
        ipAddress: request.ip,
        userAgent: request.headers["user-agent"],
        afterValue: {
          targetType: agentRequest.targetType,
          targetId: agentRequest.targetId,
          requestType: agentRequest.requestType,
          agentHint: agentRequest.agentHint
        }
      });

      return reply.code(201).send({
        ok: true,
        data: agentRequest,
        policy: agentRequestPolicy()
      });
    }
  );

  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/agent/v1/products/:productId/feedback/triage-queue",
    {
      preHandler: [ensureAgentConfigurationIsParseable, authenticateAgent(store, "feedback:read")]
    },
    async (request, reply) => {
      const parsedQuery = agentFeedbackTriageQueueQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid Agent triage queue query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const feedback = await store.listFeedback(request.params.productId);
      const issues = await store.listGitHubIssues(request.params.productId);
      const items = feedback
        .filter((item) => ["new", "triaged"].includes(item.status))
        .map((item) => ({
          ...item,
          linkedGitHubIssues: issues.filter((issue) => issue.linkedFeedbackId === item.id)
        }));
      const page = paginate(items, parsedQuery.data);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/agent/v1/products/:productId/feedback/agent-requests",
    {
      preHandler: [ensureAgentConfigurationIsParseable, authenticateAgent(store, "feedback:read")]
    },
    async (request, reply) => {
      const parsedQuery = agentRequestListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid Agent request query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const query = parsedQuery.data;
      const page = paginate(
        await store.listAgentRequests(request.params.productId, {
          targetType: "feedback",
          status: query.status
        }),
        query
      );
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination,
        policy: agentRequestReadPolicy()
      };
    }
  );

  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/agent/v1/products/:productId/releases/agent-requests",
    {
      preHandler: [ensureAgentConfigurationIsParseable, authenticateAgent(store, "releases:read")]
    },
    async (request, reply) => {
      const parsedQuery = agentRequestListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid release Agent request query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const query = parsedQuery.data;
      const page = paginate(
        await store.listAgentRequests(request.params.productId, {
          targetType: "release",
          status: query.status
        }),
        query
      );
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination,
        policy: agentRequestReadPolicy()
      };
    }
  );

  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/agent/v1/products/:productId/github/issues",
    {
      preHandler: [ensureAgentConfigurationIsParseable, authenticateAgent(store, "issues:read")]
    },
    async (request, reply) => {
      const parsedQuery = agentGitHubIssueListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid Agent GitHub issue query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const query = parsedQuery.data;
      const search = query.search?.toLowerCase();
      const issues = (await store.listGitHubIssues(request.params.productId)).filter((issue) => {
        if (query.state && issue.state !== query.state) return false;
        if (
          search &&
          ![issue.githubIssueId, String(issue.number), issue.title, issue.body, issue.author, issue.url]
            .filter(Boolean)
            .some((value) => value?.toLowerCase().includes(search))
        ) {
          return false;
        }
        return true;
      });
      const page = paginate(issues, query);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination,
        policy: agentReadOnlyPolicy()
      };
    }
  );

  server.get<{ Params: { productId: string; feedbackId: string } }>(
    "/api/agent/v1/products/:productId/feedback/:feedbackId",
    {
      preHandler: [ensureAgentConfigurationIsParseable, authenticateAgent(store, "feedback:read")]
    },
    async (request, reply) => {
      const feedback = await store.findFeedback(request.params.productId, request.params.feedbackId);
      if (!feedback) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Feedback not found"
          }
        });
      }

      const [comments, attachments, linkedGitHubIssues, aiAnalysis] = await Promise.all([
        store.listFeedbackComments(feedback.id),
        store.listFeedbackAttachments(feedback.id),
        store.listLinkedGitHubIssues(request.params.productId, feedback.id),
        store.listAiAnalysis(request.params.productId, "feedback", feedback.id)
      ]);

      return {
        ok: true,
        data: {
          feedback,
          comments,
          attachments,
          linkedGitHubIssues,
          aiAnalysis
        },
        policy: {
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false,
          feedbackDeleted: false
        }
      };
    }
  );

  server.post<{ Params: { productId: string; feedbackId: string }; Body: unknown }>(
    "/api/agent/v1/products/:productId/feedback/:feedbackId/reply-drafts",
    {
      preHandler: [ensureAgentConfigurationIsParseable, authenticateAgent(store, "feedback:write_draft")]
    },
    async (request, reply) => {
      const parsed = agentReplyDraftSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid agent reply draft",
            details: parsed.error.flatten()
          }
        });
      }
      const feedback = await store.findFeedback(request.params.productId, request.params.feedbackId);
      if (!feedback) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Feedback not found"
          }
        });
      }
      const analysis = await store.createAiAnalysis({
        productId: request.params.productId,
        targetType: "feedback",
        targetId: request.params.feedbackId,
        agentIdentity: parsed.data.agentIdentity,
        provider: parsed.data.provider,
        model: parsed.data.model,
        analysisType: "feedback_reply_draft",
        inputReferences: parsed.data.inputReferences,
        outputBody: {
          replyDraft: parsed.data.replyDraft,
          ...(parsed.data.tone ? { tone: parsed.data.tone } : {})
        },
        confidence: parsed.data.confidence
      });
      if (!analysis) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Product not found" } });
      }

      await store.createAuditLog({
        actorType: "agent",
        actorId: parsed.data.agentIdentity,
        action: "agent.reply_draft_written",
        targetType: "feedback",
        targetId: request.params.feedbackId,
        productId: request.params.productId,
        metadata: {
          analysisId: analysis.id
        }
      });

      return reply.code(201).send({
        ok: true,
        data: analysis,
        policy: {
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false,
          feedbackDeleted: false
        }
      });
    }
  );

  server.post<{ Params: { productId: string; feedbackId: string }; Body: unknown }>(
    "/api/agent/v1/products/:productId/feedback/:feedbackId/analysis",
    {
      preHandler: [ensureAgentConfigurationIsParseable, authenticateAgent(store, "feedback:write_analysis")]
    },
    async (request, reply) => {
      const parsed = agentAnalysisSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid agent analysis",
            details: parsed.error.flatten()
          }
        });
      }
      const feedback = await store.findFeedback(request.params.productId, request.params.feedbackId);
      if (!feedback) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Feedback not found"
          }
        });
      }
      const analysis = await store.createAiAnalysis({
        productId: request.params.productId,
        targetType: "feedback",
        targetId: request.params.feedbackId,
        ...parsed.data
      });
      if (!analysis) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Product not found" } });
      }

      const summary = typeof parsed.data.outputBody.summary === "string" ? parsed.data.outputBody.summary : undefined;
      const classification =
        typeof parsed.data.outputBody.classification === "string" ? parsed.data.outputBody.classification : undefined;
      const priority = suggestedPriority(parsed.data.outputBody);
      if (summary || classification || priority) {
        await store.updateFeedback(request.params.productId, request.params.feedbackId, {
          aiSummary: summary,
          aiClassification: classification,
          aiSuggestedPriority: priority
        });
      }

      await store.createAuditLog({
        actorType: "agent",
        actorId: parsed.data.agentIdentity,
        action: "agent.analysis_written",
        targetType: "feedback",
        targetId: request.params.feedbackId,
        productId: request.params.productId,
        metadata: {
          analysisId: analysis.id,
          analysisType: analysis.analysisType
        }
      });

      return reply.code(201).send({
        ok: true,
        data: analysis,
        policy: {
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false
        }
      });
    }
  );

  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/agent/v1/products/:productId/customers",
    {
      preHandler: [ensureAgentConfigurationIsParseable, authenticateAgent(store, "customers:read")]
    },
    async (request, reply) => {
      const parsedQuery = agentCustomerListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid Agent customer query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const query = parsedQuery.data;
      const search = query.search?.toLowerCase();
      const customers = (await store.listCustomers(request.params.productId)).filter((customer) => {
        if (query.status && customer.status !== query.status) return false;
        if (
          search &&
          ![customer.id, customer.email, customer.name, customer.company]
            .filter(Boolean)
            .some((value) => value?.toLowerCase().includes(search))
        ) {
          return false;
        }
        return true;
      });
      const page = paginate(customers, query);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination,
        policy: agentReadOnlyPolicy()
      };
    }
  );

  server.get<{ Params: { productId: string; customerId: string } }>(
    "/api/agent/v1/products/:productId/customers/:customerId",
    {
      preHandler: [ensureAgentConfigurationIsParseable, authenticateAgent(store, "customers:read")]
    },
    async (request, reply) => {
      const detail = await store.customerDetail(request.params.productId, request.params.customerId);
      if (!detail) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Customer not found"
          }
        });
      }
      return {
        ok: true,
        data: detail,
        policy: agentReadOnlyPolicy()
      };
    }
  );

  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/agent/v1/products/:productId/licenses",
    {
      preHandler: [ensureAgentConfigurationIsParseable, authenticateAgent(store, "licenses:read")]
    },
    async (request, reply) => {
      const parsedQuery = agentLicenseListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid Agent license query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const query = parsedQuery.data;
      const search = query.search?.toLowerCase();
      const licenses = (await store.listLicenses(request.params.productId)).filter((license) => {
        if (query.status && license.status !== query.status) return false;
        if (query.plan && license.plan !== query.plan) return false;
        if (
          search &&
          ![license.id, license.customerName, license.customerEmail, license.username, license.plan]
            .filter(Boolean)
            .some((value) => value?.toLowerCase().includes(search))
        ) {
          return false;
        }
        return true;
      });
      const page = paginate(licenses, query);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination,
        policy: agentReadOnlyPolicy()
      };
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/agent/v1/products/:productId/notifications/drafts",
    {
      preHandler: [ensureAgentConfigurationIsParseable, authenticateAgent(store, "notifications:write_draft")]
    },
    async (request, reply) => {
      const parsed = agentNotificationDraftSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid agent notification draft",
            details: parsed.error.flatten()
          }
        });
      }
      const { agentIdentity, ...draftInput } = parsed.data;
      const notification = await store.createNotification(request.params.productId, {
        ...draftInput,
        status: "draft"
      });
      if (!notification) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Product not found"
          }
        });
      }

      await store.createAuditLog({
        actorType: "agent",
        actorId: agentIdentity,
        action: "agent.notification_draft_created",
        targetType: "notification",
        targetId: notification.id,
        productId: request.params.productId,
        afterValue: {
          type: notification.type,
          recipient: notification.recipient,
          priority: notification.priority,
          status: notification.status
        }
      });

      return reply.code(201).send({
        ok: true,
        data: notification,
        policy: agentNotificationDraftPolicy()
      });
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/agent/v1/products/:productId/proposed-actions",
    {
      preHandler: [ensureAgentConfigurationIsParseable, authenticateAgent(store, "actions:propose")]
    },
    async (request, reply) => {
      const parsed = agentProposedActionSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid agent proposed action",
            details: parsed.error.flatten()
          }
        });
      }

      const targetExists =
        parsed.data.targetType === "feedback"
          ? Boolean(await store.findFeedback(request.params.productId, parsed.data.targetId))
          : parsed.data.targetType === "release"
            ? (await store.listReleases(request.params.productId)).some((item) => item.id === parsed.data.targetId)
            : (await store.listGitHubIssues(request.params.productId)).some((item) => item.id === parsed.data.targetId);
      if (!targetExists) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Proposed action target not found"
          }
        });
      }

      const analysis = await store.createAiAnalysis({
        productId: request.params.productId,
        targetType: parsed.data.targetType,
        targetId: parsed.data.targetId,
        agentIdentity: parsed.data.agentIdentity,
        provider: parsed.data.provider,
        model: parsed.data.model,
        analysisType: "proposed_action",
        inputReferences: parsed.data.inputReferences,
        outputBody: {
          actionType: parsed.data.actionType,
          payload: parsed.data.payload,
          ...(parsed.data.rationale ? { rationale: parsed.data.rationale } : {})
        },
        confidence: parsed.data.confidence
      });
      if (!analysis) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Product not found" } });
      }

      const proposedAction = await store.createProposedAction({
        analysisId: analysis.id,
        actionType: parsed.data.actionType,
        payload: parsed.data.payload
      });
      if (!proposedAction) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "AI analysis not found"
          }
        });
      }

      await store.createAuditLog({
        actorType: "agent",
        actorId: parsed.data.agentIdentity,
        action: "agent.proposed_action_created",
        targetType: "ai_proposed_action",
        targetId: proposedAction.id,
        productId: request.params.productId,
        metadata: {
          analysisId: analysis.id,
          actionType: proposedAction.actionType,
          targetType: proposedAction.targetType,
          targetId: proposedAction.targetId
        }
      });

      return reply.code(201).send({
        ok: true,
        data: proposedAction,
        policy: proposedActionReviewOnlyPolicy()
      });
    }
  );

  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/agent/v1/products/:productId/releases/drafts",
    {
      preHandler: [ensureAgentConfigurationIsParseable, authenticateAgent(store, "releases:read")]
    },
    async (request, reply) => {
      const parsedQuery = agentReleaseDraftListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid Agent release draft query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const query = parsedQuery.data;
      const drafts = (await store.listReleases(request.params.productId)).filter((release) => {
        if (release.status !== "draft") return false;
        if (query.channel && release.channel !== query.channel) return false;
        return true;
      });
      const page = paginate(drafts, query);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.post<{ Params: { productId: string; releaseId: string }; Body: unknown }>(
    "/api/agent/v1/products/:productId/releases/:releaseId/analysis",
    {
      preHandler: [ensureAgentConfigurationIsParseable, authenticateAgent(store, "releases:write_draft")]
    },
    async (request, reply) => {
      const parsed = agentAnalysisSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid release analysis",
            details: parsed.error.flatten()
          }
        });
      }
      const release = (await store.listReleases(request.params.productId)).find((item) => item.id === request.params.releaseId);
      if (!release) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Release not found" } });
      }
      const analysis = await store.createAiAnalysis({
        productId: request.params.productId,
        targetType: "release",
        targetId: request.params.releaseId,
        ...parsed.data
      });
      if (!analysis) {
        return reply.code(404).send({ ok: false, error: { code: "NOT_FOUND", message: "Product not found" } });
      }
      await store.createAuditLog({
        actorType: "agent",
        actorId: parsed.data.agentIdentity,
        action: "agent.release_analysis_written",
        targetType: "release",
        targetId: request.params.releaseId,
        productId: request.params.productId,
        metadata: {
          analysisId: analysis.id,
          analysisType: analysis.analysisType
        }
      });
      return reply.code(201).send({
        ok: true,
        data: analysis,
        policy: {
          otaPublished: false,
          channelChanged: false,
          customerVisibleEmailSent: false
        }
      });
    }
  );
}
