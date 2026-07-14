import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { PlanItem, ReleaseChannelItem } from "../data/types.js";
import type { OpsStore } from "../data/store.js";
import { paginate, paginationQuerySchema } from "./pagination.js";

const planFields = {
  name: z.string().trim().min(1).max(120),
  description: z.string().trim().max(20_000).optional(),
  maxDevices: z.number().int().positive().max(100_000),
  maxSeats: z.number().int().positive().max(100_000),
  trialDays: z.number().int().min(0).max(3650),
  offlineGraceDays: z.number().int().min(1).max(3650),
  allowedChannels: z.array(z.string().trim().min(1).max(64)).max(32),
  supportedVersionRange: z.string().trim().max(160).optional(),
  paymentProvider: z.string().trim().max(64).optional(),
  providerPlanId: z.string().trim().max(160).optional(),
  priceMinor: z.number().int().min(0).optional(),
  currency: z.string().trim().min(3).max(8).optional(),
  billingInterval: z.enum(["month", "year", "one_time"]).optional(),
  couponSupport: z.boolean().optional(),
  subscriptionSupport: z.boolean().optional(),
  entitlements: z.array(z.string().trim().min(1).max(120)).max(200).optional(),
  status: z.enum(["active", "disabled"]).optional()
};

const createPlanSchema = z.object({
  id: z.string().trim().regex(/^[a-z0-9][a-z0-9_-]{2,63}$/),
  ...planFields
});

const updatePlanSchema = z
  .object(planFields)
  .partial()
  .refine((value) => Object.keys(value).length > 0, "At least one field is required");

const createChannelSchema = z.object({
  name: z.string().trim().regex(/^[a-z0-9][a-z0-9_-]{1,63}$/),
  appcastUrl: z.string().url().optional(),
  currentReleaseId: z.string().trim().min(1).max(64).optional(),
  allowedPlanIds: z.array(z.string().trim().min(1).max(64)).max(200).default([]),
  minimumUpgradableVersion: z.string().trim().max(80).optional(),
  rolloutPercentage: z.number().int().min(0).max(100).default(100),
  autoDownloadAllowed: z.boolean().default(false),
  forceUpdatePrompt: z.boolean().default(false),
  status: z.enum(["active", "paused"]).default("active")
});

const updateChannelSchema = z
  .object({
    name: z.string().trim().regex(/^[a-z0-9][a-z0-9_-]{1,63}$/).optional(),
    appcastUrl: z.string().url().nullable().optional(),
    currentReleaseId: z.string().trim().min(1).max(64).nullable().optional(),
    allowedPlanIds: z.array(z.string().trim().min(1).max(64)).max(200).optional(),
    minimumUpgradableVersion: z.string().trim().max(80).nullable().optional(),
    rolloutPercentage: z.number().int().min(0).max(100).optional(),
    autoDownloadAllowed: z.boolean().optional(),
    forceUpdatePrompt: z.boolean().optional(),
    status: z.enum(["active", "paused", "archived"]).optional(),
    confirmation: z.string().optional()
  })
  .refine(
    (value) => Object.keys(value).some((key) => key !== "confirmation"),
    "At least one field is required"
  );

const archiveSchema = z.object({
  confirmation: z.literal("ARCHIVE")
});

const rollbackSchema = z.object({
  historyId: z.string().trim().min(1).max(64),
  confirmation: z.literal("ROLLBACK")
});

function planSnapshot(plan: PlanItem) {
  return {
    id: plan.id,
    name: plan.name,
    description: plan.description,
    maxDevices: plan.maxDevices,
    maxSeats: plan.maxSeats,
    trialDays: plan.trialDays,
    offlineGraceDays: plan.offlineGraceDays,
    allowedChannels: plan.allowedChannels,
    supportedVersionRange: plan.supportedVersionRange,
    paymentProvider: plan.paymentProvider,
    providerPlanId: plan.providerPlanId,
    priceMinor: plan.priceMinor,
    currency: plan.currency,
    billingInterval: plan.billingInterval,
    couponSupport: plan.couponSupport,
    subscriptionSupport: plan.subscriptionSupport,
    entitlements: plan.entitlements,
    status: plan.status
  };
}

function channelSnapshot(channel: ReleaseChannelItem) {
  return {
    name: channel.name,
    appcastUrl: channel.appcastUrl,
    currentReleaseId: channel.currentReleaseId,
    allowedPlanIds: channel.allowedPlanIds,
    minimumUpgradableVersion: channel.minimumUpgradableVersion,
    rolloutPercentage: channel.rolloutPercentage,
    autoDownloadAllowed: channel.autoDownloadAllowed,
    forceUpdatePrompt: channel.forceUpdatePrompt,
    status: channel.status
  };
}

async function validatePlanIds(store: OpsStore, productId: string, planIds: string[]) {
  const knownIds = new Set((await store.listPlans(productId)).map((plan) => plan.id));
  return planIds.every((planId) => knownIds.has(planId));
}

export async function registerAdminConfigRoutes(server: FastifyInstance, store: OpsStore) {
  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/channels",
    {
      preHandler: server.authorize("releases:read")
    },
    async (request, reply) => {
      const parsedQuery = paginationQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid channel query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const page = paginate(await store.listReleaseChannels(request.params.productId), parsedQuery.data);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId/channels",
    {
      preHandler: server.authorize("releases:write")
    },
    async (request, reply) => {
      const parsed = createChannelSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid channel payload",
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
      if (!(await validatePlanIds(store, request.params.productId, parsed.data.allowedPlanIds))) {
        return reply.code(422).send({
          ok: false,
          error: { code: "UNKNOWN_PLAN", message: "One or more allowed plans do not exist" }
        });
      }
      const existing = (await store.listReleaseChannels(request.params.productId)).find(
        (channel) => channel.name === parsed.data.name
      );
      if (existing) {
        return reply.code(409).send({
          ok: false,
          error: { code: "CHANNEL_EXISTS", message: "Channel name already exists" }
        });
      }
      const channel = await store.createReleaseChannel(request.params.productId, parsed.data);
      if (!channel) {
        return reply.code(409).send({
          ok: false,
          error: { code: "CHANNEL_CREATE_FAILED", message: "Channel could not be created" }
        });
      }
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "channel.created",
        targetType: "channel",
        targetId: channel.id,
        productId: request.params.productId,
        afterValue: channelSnapshot(channel)
      });
      return reply.code(201).send({ ok: true, data: channel });
    }
  );

  server.patch<{ Params: { productId: string; channelId: string }; Body: unknown }>(
    "/api/v1/products/:productId/channels/:channelId",
    {
      preHandler: server.authorize("releases:write")
    },
    async (request, reply) => {
      const parsed = updateChannelSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid channel update",
            details: parsed.error.flatten()
          }
        });
      }
      const before = (await store.listReleaseChannels(request.params.productId)).find(
        (channel) => channel.id === request.params.channelId
      );
      if (!before) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Channel not found" }
        });
      }
      const beforeSnapshotValue = channelSnapshot(before);
      const beforeStatus = before.status;
      if (
        parsed.data.allowedPlanIds &&
        !(await validatePlanIds(store, request.params.productId, parsed.data.allowedPlanIds))
      ) {
        return reply.code(422).send({
          ok: false,
          error: { code: "UNKNOWN_PLAN", message: "One or more allowed plans do not exist" }
        });
      }
      if (parsed.data.currentReleaseId) {
        const release = (await store.listReleases(request.params.productId)).find(
          (item) => item.id === parsed.data.currentReleaseId
        );
        if (!release) {
          return reply.code(422).send({
            ok: false,
            error: { code: "UNKNOWN_RELEASE", message: "Current release does not exist" }
          });
        }
      }
      const requiredConfirmation =
        parsed.data.status === "paused"
          ? "PAUSE"
          : parsed.data.status === "archived"
            ? "ARCHIVE"
            : parsed.data.status === "active" && beforeStatus === "paused"
              ? "RESUME"
              : undefined;
      if (requiredConfirmation && parsed.data.confirmation !== requiredConfirmation) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CHANNEL_CONFIRMATION_REQUIRED",
            message: `Channel action requires confirmation: ${requiredConfirmation}`
          }
        });
      }
      const { confirmation: _confirmation, ...update } = parsed.data;
      const channel = await store.updateReleaseChannel(
        request.params.productId,
        request.params.channelId,
        update
      );
      if (!channel) {
        return reply.code(409).send({
          ok: false,
          error: { code: "CHANNEL_UPDATE_FAILED", message: "Channel could not be updated" }
        });
      }
      const action =
        channel.status !== beforeStatus
          ? channel.status === "paused"
            ? "channel.paused"
            : channel.status === "archived"
              ? "channel.archived"
              : "channel.resumed"
          : "channel.updated";
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action,
        targetType: "channel",
        targetId: channel.id,
        productId: request.params.productId,
        beforeValue: beforeSnapshotValue,
        afterValue: channelSnapshot(channel)
      });
      return { ok: true, data: channel };
    }
  );

  server.get<{ Params: { productId: string; channelId: string } }>(
    "/api/v1/products/:productId/channels/:channelId/history",
    {
      preHandler: server.authorize("releases:read")
    },
    async (request, reply) => {
      const channel = (await store.listReleaseChannels(request.params.productId)).find(
        (item) => item.id === request.params.channelId
      );
      if (!channel) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Channel not found" }
        });
      }
      const history = (await store.listAuditLogs(request.params.productId)).filter(
        (item) => item.targetType === "channel" && item.targetId === request.params.channelId
      );
      return { ok: true, data: history };
    }
  );

  server.post<{
    Params: { productId: string; channelId: string };
    Body: unknown;
  }>(
    "/api/v1/products/:productId/channels/:channelId/rollback",
    {
      preHandler: server.authorize("releases:write")
    },
    async (request, reply) => {
      const parsed = rollbackSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CHANNEL_ROLLBACK_CONFIRMATION_REQUIRED",
            message: "Channel rollback requires confirmation: ROLLBACK"
          }
        });
      }
      const before = (await store.listReleaseChannels(request.params.productId)).find(
        (item) => item.id === request.params.channelId
      );
      if (!before) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Channel not found" }
        });
      }
      const beforeSnapshotValue = channelSnapshot(before);
      const history = (await store.listAuditLogs(request.params.productId)).find(
        (item) =>
          item.id === parsed.data.historyId &&
          item.targetType === "channel" &&
          item.targetId === request.params.channelId
      );
      const rollback = updateChannelSchema.safeParse(history?.beforeValue);
      if (!history || !rollback.success) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CHANNEL_HISTORY_NOT_REVERSIBLE",
            message: "Selected channel history entry cannot be rolled back"
          }
        });
      }
      const { confirmation: _confirmation, ...update } = rollback.data;
      const channel = await store.updateReleaseChannel(
        request.params.productId,
        request.params.channelId,
        update
      );
      if (!channel) {
        return reply.code(409).send({
          ok: false,
          error: { code: "CHANNEL_ROLLBACK_FAILED", message: "Channel rollback failed" }
        });
      }
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "channel.rolled_back",
        targetType: "channel",
        targetId: channel.id,
        productId: request.params.productId,
        beforeValue: beforeSnapshotValue,
        afterValue: channelSnapshot(channel),
        metadata: {
          historyId: history.id
        }
      });
      return { ok: true, data: channel };
    }
  );

  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/plans",
    {
      preHandler: server.authorize("licenses:read")
    },
    async (request, reply) => {
      const parsedQuery = paginationQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid plan query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const page = paginate(await store.listPlans(request.params.productId), parsedQuery.data);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId/plans",
    {
      preHandler: server.authorize("licenses:write")
    },
    async (request, reply) => {
      const parsed = createPlanSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid plan payload",
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
      const duplicate = (await store.listPlans(request.params.productId)).find(
        (plan) =>
          plan.id === parsed.data.id ||
          plan.name.toLowerCase() === parsed.data.name.toLowerCase()
      );
      if (duplicate) {
        return reply.code(409).send({
          ok: false,
          error: { code: "PLAN_EXISTS", message: "Plan ID or name already exists" }
        });
      }
      const plan = await store.createPlan(request.params.productId, parsed.data);
      if (!plan) {
        return reply.code(409).send({
          ok: false,
          error: { code: "PLAN_CREATE_FAILED", message: "Plan could not be created" }
        });
      }
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "plan.created",
        targetType: "plan",
        targetId: plan.id,
        productId: request.params.productId,
        afterValue: planSnapshot(plan)
      });
      return reply.code(201).send({ ok: true, data: plan });
    }
  );

  server.patch<{ Params: { productId: string; planId: string }; Body: unknown }>(
    "/api/v1/products/:productId/plans/:planId",
    {
      preHandler: server.authorize("licenses:write")
    },
    async (request, reply) => {
      const parsed = updatePlanSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid plan update",
            details: parsed.error.flatten()
          }
        });
      }
      const before = (await store.listPlans(request.params.productId)).find(
        (plan) => plan.id === request.params.planId
      );
      if (!before) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Plan not found" }
        });
      }
      const beforeSnapshotValue = planSnapshot(before);
      const plan = await store.updatePlan(
        request.params.productId,
        request.params.planId,
        parsed.data
      );
      if (!plan) {
        return reply.code(409).send({
          ok: false,
          error: { code: "PLAN_UPDATE_FAILED", message: "Plan could not be updated" }
        });
      }
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "plan.updated",
        targetType: "plan",
        targetId: plan.id,
        productId: request.params.productId,
        beforeValue: beforeSnapshotValue,
        afterValue: planSnapshot(plan)
      });
      return { ok: true, data: plan };
    }
  );

  server.post<{ Params: { productId: string; planId: string }; Body: unknown }>(
    "/api/v1/products/:productId/plans/:planId/archive",
    {
      preHandler: server.authorize("licenses:write")
    },
    async (request, reply) => {
      const parsed = archiveSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "PLAN_ARCHIVE_CONFIRMATION_REQUIRED",
            message: "Plan archive requires confirmation: ARCHIVE"
          }
        });
      }
      const before = (await store.listPlans(request.params.productId)).find(
        (plan) => plan.id === request.params.planId
      );
      if (!before) {
        return reply.code(404).send({
          ok: false,
          error: { code: "NOT_FOUND", message: "Plan not found" }
        });
      }
      const beforeSnapshotValue = planSnapshot(before);
      const plan = await store.updatePlan(
        request.params.productId,
        request.params.planId,
        { status: "archived" }
      );
      if (!plan) {
        return reply.code(409).send({
          ok: false,
          error: { code: "PLAN_ARCHIVE_FAILED", message: "Plan could not be archived" }
        });
      }
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "plan.archived",
        targetType: "plan",
        targetId: plan.id,
        productId: request.params.productId,
        beforeValue: beforeSnapshotValue,
        afterValue: planSnapshot(plan)
      });
      return { ok: true, data: plan };
    }
  );

  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/connectors",
    {
      preHandler: server.authorize("connectors:read")
    },
    async (request, reply) => {
      const parsedQuery = paginationQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid connector query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const page = paginate(await store.listConnectors(request.params.productId), parsedQuery.data);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.get<{ Querystring: { productId?: string } }>(
    "/api/v1/settings/summary",
    {
      preHandler: server.authorize("products:read")
    },
    async (request, reply) => {
      const assignedProductIds = request.authPrincipal?.productIds ?? [];
      if (!request.query.productId && assignedProductIds.length > 1) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "PRODUCT_ID_REQUIRED",
            message: "Select a product before loading settings"
          }
        });
      }
      const productId =
        request.query.productId ?? (assignedProductIds.length === 1 ? assignedProductIds[0] : "stacio");
      const summary = await store.settingsSummary(productId);
      if (!summary) {
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
        data: summary
      };
    }
  );
}
