import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { OpsStore } from "../data/store.js";
import type { OpsJobQueue } from "../jobs/queue.js";
import {
  fetchGitHubIssues,
  GitHubConfigurationError,
  GitHubFetchError,
  postGitHubIssueComment,
  updateGitHubIssue as updateRemoteGitHubIssue
} from "../services/githubClient.js";
import { paginate, paginationQuerySchema } from "./pagination.js";

const githubIssueSchema = z.object({
  githubIssueId: z.string().min(1),
  number: z.number().int().positive(),
  title: z.string().min(1),
  body: z.string().optional(),
  labels: z.array(z.string()).optional(),
  author: z.string().optional(),
  state: z.enum(["open", "closed"]),
  commentsCount: z.number().int().nonnegative().optional(),
  url: z.string().url(),
  githubCreatedAt: z.string().datetime().optional(),
  githubUpdatedAt: z.string().datetime().optional(),
  githubClosedAt: z.string().datetime().optional()
});

const syncSchema = z.object({
  trigger: z.enum(["manual", "scheduled", "webhook"]).default("manual"),
  issues: z.array(githubIssueSchema).min(1).max(500)
});

const pullSchema = z.object({
  owner: z.string().min(1).max(160).optional(),
  repository: z.string().min(1).max(160).optional(),
  state: z.enum(["open", "closed", "all"]).optional(),
  labels: z.array(z.string().min(1).max(80)).max(20).optional(),
  perPage: z.number().int().positive().max(100).optional()
});
type GitHubPullOptions = z.infer<typeof pullSchema>;

const githubIssueListQuerySchema = paginationQuerySchema.extend({
  state: z.enum(["open", "closed"]).optional(),
  search: z.string().trim().optional()
});

const githubSyncRunListQuerySchema = paginationQuerySchema;

const commentSchema = z.object({
  body: z.string().min(1).max(65536),
  confirmation: z.string()
});

const updateIssueSchema = z
  .object({
    labels: z.array(z.string().trim().min(1).max(80)).max(40).optional(),
    state: z.enum(["open", "closed"]).optional(),
    confirmation: z.string()
  })
  .refine((value) => value.labels !== undefined || value.state !== undefined, {
    message: "At least one GitHub issue change is required"
  });

function requiredIssueUpdateConfirmation(input: z.infer<typeof updateIssueSchema>) {
  if (input.state === "closed") return "CLOSE";
  if (input.state === "open") return "REOPEN";
  if (input.labels !== undefined) return "APPLY_LABELS";
  return "CONFIRM";
}

async function recordFailedPull(
  store: OpsStore,
  jobQueue: OpsJobQueue | undefined,
  context: {
    productId: string;
    actorId?: string;
    ipAddress?: string;
    userAgent?: string | string[];
    options?: GitHubPullOptions;
  },
  error: string,
  statusCode?: number
) {
  const run = await store.recordGitHubSyncFailure(context.productId, {
    trigger: "manual",
    error
  });
  if (!run) {
    return undefined;
  }
  await store.createAuditLog({
    actorType: "user",
    actorId: context.actorId,
    action: "github.pull_sync_failed",
    targetType: "github_sync_run",
    targetId: run.id,
    productId: context.productId,
    ipAddress: context.ipAddress,
    userAgent: typeof context.userAgent === "string" ? context.userAgent : undefined,
    afterValue: {
      error,
      ...(statusCode ? { statusCode } : {})
    }
  });
  const product = await store.findProduct(context.productId);
  if (product) {
    const payload = {
      productId: context.productId,
      error,
      ...(statusCode !== undefined ? { statusCode } : {}),
      owner: context.options?.owner ?? product.githubOwner ?? process.env.GITHUB_OWNER,
      repository: context.options?.repository ?? product.githubRepository ?? process.env.GITHUB_REPOSITORY
    };
    const notification = await store.createNotification(context.productId, {
      type: "admin_github_sync_failure",
      recipient: product.supportEmail,
      priority: "high",
      status: "queued",
      payload
    });
    if (notification) {
      const job = await jobQueue?.enqueueNotificationSend({
        productId: context.productId,
        notificationId: notification.id,
        requestedBy: context.actorId,
        dryRun: false
      });
      await store.createAuditLog({
        actorType: "system",
        actorId: context.actorId,
        action: "notification.queued",
        targetType: "notification",
        targetId: notification.id,
        productId: context.productId,
        ipAddress: context.ipAddress,
        userAgent: typeof context.userAgent === "string" ? context.userAgent : undefined,
        afterValue: {
          type: notification.type,
          recipient: notification.recipient,
          syncRunId: run.id,
          ...(job?.id ? { jobId: job.id } : {}),
          ...payload
        }
      });
    }
  }
  return run;
}

export async function registerGitHubIssueRoutes(server: FastifyInstance, store: OpsStore, jobQueue?: OpsJobQueue) {
  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/github/issues",
    {
      preHandler: server.authorize("feedback:read")
    },
    async (request, reply) => {
      const parsedQuery = githubIssueListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid GitHub issue query",
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
        pagination: page.pagination
      };
    }
  );

  server.get<{ Params: { productId: string }; Querystring: unknown }>(
    "/api/v1/products/:productId/github/sync-runs",
    {
      preHandler: server.authorize("feedback:read")
    },
    async (request, reply) => {
      const parsedQuery = githubSyncRunListQuerySchema.safeParse(request.query);
      if (!parsedQuery.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid GitHub sync run query",
            details: parsedQuery.error.flatten()
          }
        });
      }
      const page = paginate(await store.listGitHubSyncRuns(request.params.productId), parsedQuery.data);
      return {
        ok: true,
        data: page.data,
        pagination: page.pagination
      };
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId/github/sync",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = syncSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid GitHub sync payload",
            details: parsed.error.flatten()
          }
        });
      }

      const result = await store.syncGitHubIssues(request.params.productId, parsed.data);
      if (!result) {
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
        action: "github.sync",
        targetType: "github_sync_run",
        targetId: result.run.id,
        productId: request.params.productId,
        ipAddress: request.ip,
        userAgent: request.headers["user-agent"],
        afterValue: {
          fetchedCount: result.run.fetchedCount,
          changedCount: result.run.changedCount,
          feedbackCreatedCount: result.feedbackCreated.length
        }
      });

      return {
        ok: true,
        data: result
      };
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId/github/pull",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = pullSchema.safeParse(request.body ?? {});
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid GitHub pull payload",
            details: parsed.error.flatten()
          }
        });
      }

      try {
        const issues = await fetchGitHubIssues(parsed.data);
        const result = await store.syncGitHubIssues(request.params.productId, {
          trigger: "manual",
          issues
        });
        if (!result) {
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
          action: "github.pull_sync",
          targetType: "github_sync_run",
          targetId: result.run.id,
          productId: request.params.productId,
          ipAddress: request.ip,
          userAgent: request.headers["user-agent"],
          afterValue: {
            fetchedCount: result.run.fetchedCount,
            changedCount: result.run.changedCount,
            feedbackCreatedCount: result.feedbackCreated.length,
            owner: parsed.data.owner ?? process.env.GITHUB_OWNER,
            repository: parsed.data.repository ?? process.env.GITHUB_REPOSITORY
          }
        });
        return {
          ok: true,
          data: result
        };
      } catch (error) {
        if (error instanceof GitHubConfigurationError) {
          await recordFailedPull(
            store,
            jobQueue,
            {
              productId: request.params.productId,
              actorId: request.authPrincipal?.id,
              ipAddress: request.ip,
              userAgent: request.headers["user-agent"],
              options: parsed.data
            },
            error.message
          );
          return reply.code(503).send({
            ok: false,
            error: {
              code: "GITHUB_NOT_CONFIGURED",
              message: error.message
            }
          });
        }
        if (error instanceof GitHubFetchError) {
          await recordFailedPull(
            store,
            jobQueue,
            {
              productId: request.params.productId,
              actorId: request.authPrincipal?.id,
              ipAddress: request.ip,
              userAgent: request.headers["user-agent"],
              options: parsed.data
            },
            error.message,
            error.statusCode
          );
          return reply.code(502).send({
            ok: false,
            error: {
              code: "GITHUB_FETCH_FAILED",
              message: error.message,
              statusCode: error.statusCode
            }
          });
        }
        const message = error instanceof Error ? error.message : "Unknown GitHub sync error";
        await recordFailedPull(
          store,
          jobQueue,
          {
            productId: request.params.productId,
            actorId: request.authPrincipal?.id,
            ipAddress: request.ip,
            userAgent: request.headers["user-agent"],
            options: parsed.data
          },
          message
        );
        return reply.code(502).send({
          ok: false,
          error: {
            code: "GITHUB_FETCH_FAILED",
            message
          }
        });
      }
    }
  );

  server.post<{ Params: { productId: string }; Body: unknown }>(
    "/api/v1/products/:productId/github/pull/enqueue",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = pullSchema.safeParse(request.body ?? {});
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid GitHub pull payload",
            details: parsed.error.flatten()
          }
        });
      }
      if (!jobQueue) {
        return reply.code(503).send({
          ok: false,
          error: {
            code: "JOB_QUEUE_NOT_CONFIGURED",
            message: "Job queue is not configured"
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
      const job = await jobQueue.enqueueGitHubPull({
        productId: request.params.productId,
        requestedBy: request.authPrincipal?.id,
        options: parsed.data
      });
      await store.createAuditLog({
        actorType: "user",
        actorId: request.authPrincipal?.id,
        action: "github.pull_enqueued",
        targetType: "github_pull_job",
        targetId: job.id,
        productId: request.params.productId,
        afterValue: {
          owner: parsed.data.owner ?? process.env.GITHUB_OWNER,
          repository: parsed.data.repository ?? process.env.GITHUB_REPOSITORY
        }
      });
      return reply.code(202).send({
        ok: true,
        data: job
      });
    }
  );

  server.post<{ Params: { productId: string; issueId: string }; Body: unknown }>(
    "/api/v1/products/:productId/github/issues/:issueId/comments",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = commentSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid GitHub comment payload",
            details: parsed.error.flatten()
          }
        });
      }
      if (parsed.data.confirmation !== "POST") {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CONFIRMATION_REQUIRED",
            message: "Type POST to confirm a public GitHub reply"
          },
          policy: {
            publicGitHubReplySent: false,
            requiredConfirmation: "POST"
          }
        });
      }

      const product = await store.findProduct(request.params.productId);
      const issue = (await store.listGitHubIssues(request.params.productId)).find(
        (item) => item.id === request.params.issueId
      );
      if (!product || !issue) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "GitHub issue not found"
          }
        });
      }

      try {
        const comment = await postGitHubIssueComment({
          owner: product.githubOwner,
          repository: product.githubRepository,
          issueNumber: issue.number,
          body: parsed.data.body
        });
        await store.createAuditLog({
          actorType: "user",
          actorId: request.authPrincipal?.id,
          action: "github.issue_comment.created",
          targetType: "github_issue",
          targetId: issue.id,
          productId: request.params.productId,
          ipAddress: request.ip,
          userAgent: request.headers["user-agent"],
          afterValue: {
            issueNumber: issue.number,
            commentId: comment.commentId,
            url: comment.url
          }
        });
        return reply.code(201).send({
          ok: true,
          data: comment,
          policy: {
            publicGitHubReplySent: true,
            requiredConfirmation: "POST"
          }
        });
      } catch (error) {
        if (error instanceof GitHubConfigurationError) {
          return reply.code(503).send({
            ok: false,
            error: {
              code: "GITHUB_NOT_CONFIGURED",
              message: error.message
            },
            policy: {
              publicGitHubReplySent: false,
              requiredConfirmation: "POST"
            }
          });
        }
        if (error instanceof GitHubFetchError) {
          return reply.code(502).send({
            ok: false,
            error: {
              code: "GITHUB_COMMENT_FAILED",
              message: error.message,
              statusCode: error.statusCode
            },
            policy: {
              publicGitHubReplySent: false,
              requiredConfirmation: "POST"
            }
          });
        }
        const message = error instanceof Error ? error.message : "Unknown GitHub comment error";
        return reply.code(502).send({
          ok: false,
          error: {
            code: "GITHUB_COMMENT_FAILED",
            message
          },
          policy: {
            publicGitHubReplySent: false,
            requiredConfirmation: "POST"
          }
        });
      }
    }
  );

  server.patch<{ Params: { productId: string; issueId: string }; Body: unknown }>(
    "/api/v1/products/:productId/github/issues/:issueId",
    {
      preHandler: server.authorize("feedback:write")
    },
    async (request, reply) => {
      const parsed = updateIssueSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid GitHub issue update payload",
            details: parsed.error.flatten()
          }
        });
      }

      const requiredConfirmation = requiredIssueUpdateConfirmation(parsed.data);
      if (parsed.data.confirmation !== requiredConfirmation) {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "CONFIRMATION_REQUIRED",
            message: `Type ${requiredConfirmation} to confirm this public GitHub change`
          },
          policy: {
            publicGitHubIssueChanged: false,
            requiredConfirmation
          }
        });
      }

      const product = await store.findProduct(request.params.productId);
      const issue = (await store.listGitHubIssues(request.params.productId)).find(
        (item) => item.id === request.params.issueId
      );
      if (!product || !issue) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "GitHub issue not found"
          }
        });
      }

      try {
        const remoteIssue = await updateRemoteGitHubIssue({
          owner: product.githubOwner,
          repository: product.githubRepository,
          issueNumber: issue.number,
          labels: parsed.data.labels,
          state: parsed.data.state
        });
        const updated = await store.updateGitHubIssue(request.params.productId, issue.id, {
          title: remoteIssue.title,
          body: remoteIssue.body,
          labels: remoteIssue.labels,
          author: remoteIssue.author,
          state: remoteIssue.state,
          commentsCount: remoteIssue.commentsCount,
          url: remoteIssue.url,
          githubUpdatedAt: remoteIssue.githubUpdatedAt,
          githubClosedAt: remoteIssue.githubClosedAt
        });
        await store.createAuditLog({
          actorType: "user",
          actorId: request.authPrincipal?.id,
          action: parsed.data.state === "closed" ? "github.issue.closed" : "github.issue_labels.updated",
          targetType: "github_issue",
          targetId: issue.id,
          productId: request.params.productId,
          ipAddress: request.ip,
          userAgent: request.headers["user-agent"],
          beforeValue: {
            labels: issue.labels,
            state: issue.state
          },
          afterValue: {
            labels: updated?.labels,
            state: updated?.state,
            issueNumber: issue.number
          }
        });
        return {
          ok: true,
          data: updated,
          policy: {
            publicGitHubIssueChanged: true,
            requiredConfirmation
          }
        };
      } catch (error) {
        if (error instanceof GitHubConfigurationError) {
          return reply.code(503).send({
            ok: false,
            error: {
              code: "GITHUB_NOT_CONFIGURED",
              message: error.message
            },
            policy: {
              publicGitHubIssueChanged: false,
              requiredConfirmation
            }
          });
        }
        if (error instanceof GitHubFetchError) {
          return reply.code(502).send({
            ok: false,
            error: {
              code: "GITHUB_ISSUE_UPDATE_FAILED",
              message: error.message,
              statusCode: error.statusCode
            },
            policy: {
              publicGitHubIssueChanged: false,
              requiredConfirmation
            }
          });
        }
        const message = error instanceof Error ? error.message : "Unknown GitHub issue update error";
        return reply.code(502).send({
          ok: false,
          error: {
            code: "GITHUB_ISSUE_UPDATE_FAILED",
            message
          },
          policy: {
            publicGitHubIssueChanged: false,
            requiredConfirmation
          }
        });
      }
    }
  );
}
