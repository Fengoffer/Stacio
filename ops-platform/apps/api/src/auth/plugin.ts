import { createHash, randomBytes } from "node:crypto";
import fastifyJwt from "@fastify/jwt";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import type { OpsStore } from "../data/store.js";
import type { AuthStore, AuthUser } from "./store.js";
import { verifyPassword } from "./password.js";

export interface AuthPrincipal {
  id: string;
  email: string;
  name: string;
  roles: string[];
  permissions: string[];
  productIds: string[];
}

type AsyncPreHandler = (request: FastifyRequest, reply: FastifyReply) => Promise<void>;

interface AuthorizationOptions {
  global?: boolean;
}

declare module "fastify" {
  interface FastifyRequest {
    authPrincipal: AuthPrincipal | null;
  }

  interface FastifyInstance {
    authenticate: AsyncPreHandler;
    authorize(permission: string, options?: AuthorizationOptions): AsyncPreHandler;
  }
}

const loginSchema = z.object({
  email: z.string().email(),
  password: z.string().min(8)
});

const updateOwnProfileSchema = z.object({
  name: z.string().trim().min(1).max(160),
  email: z.string().trim().email().max(320),
  currentPassword: z.string().min(8).max(256),
  newPassword: z.string().min(8).max(256).optional()
});

const refreshTokenBodySchema = z
  .object({
    refreshToken: z.string().optional(),
    refresh_token: z.string().optional()
  })
  .transform((body) => ({
    refreshToken: body.refreshToken ?? body.refresh_token
  }))
  .pipe(
    z.object({
      refreshToken: z.string().min(16)
    })
  );

function toPrincipal(user: AuthUser): AuthPrincipal {
  return {
    id: user.id,
    email: user.email,
    name: user.name,
    roles: user.roles,
    permissions: user.permissions,
    productIds: user.productIds
  };
}

function can(principal: AuthPrincipal, permission: string) {
  return principal.permissions.includes("*") || principal.permissions.includes(permission);
}

function requestedProductId(request: FastifyRequest) {
  const params = request.params as Record<string, unknown> | undefined;
  if (typeof params?.productId === "string" && params.productId.length > 0) {
    return params.productId;
  }
  const query = request.query as Record<string, unknown> | undefined;
  if (typeof query?.productId === "string" && query.productId.length > 0) {
    return query.productId;
  }
  return undefined;
}

function hasGlobalProductAccess(principal: AuthPrincipal) {
  return principal.productIds.length === 0;
}

function canAccessProduct(principal: AuthPrincipal, productId: string) {
  return hasGlobalProductAccess(principal) || principal.productIds.includes(productId);
}

function jwtSecret() {
  const configured = process.env.JWT_SECRET;
  if (configured) {
    return configured;
  }
  if (process.env.NODE_ENV === "production") {
    throw new Error("JWT_SECRET is required in production");
  }
  return "development-only-jwt-secret-change-before-production";
}

function requestAddress(request: FastifyRequest) {
  return request.ip || request.socket.remoteAddress;
}

function refreshTokenExpiresAt() {
  const days = Number(process.env.REFRESH_TOKEN_EXPIRES_DAYS ?? 30);
  const safeDays = Number.isFinite(days) && days > 0 ? days : 30;
  return new Date(Date.now() + safeDays * 24 * 60 * 60 * 1000);
}

function createRefreshTokenValue() {
  return `rt_${randomBytes(32).toString("base64url")}`;
}

function hashRefreshToken(token: string) {
  return createHash("sha256").update(token).digest("hex");
}

function invalidRefreshToken(reply: FastifyReply) {
  return reply.code(401).send({
    ok: false,
    error: {
      code: "INVALID_REFRESH_TOKEN",
      message: "Refresh token is invalid or expired"
    }
  });
}

export function registerAuth(server: FastifyInstance, authStore: AuthStore, opsStore: OpsStore) {
  void server.register(fastifyJwt, {
    secret: jwtSecret(),
    sign: {
      expiresIn: process.env.JWT_EXPIRES_IN ?? "8h"
    }
  });

  server.decorateRequest("authPrincipal", null);

  server.decorate("authenticate", async (request: FastifyRequest, reply: FastifyReply) => {
    try {
      const payload = await request.jwtVerify<{ sub: string }>();
      const user = await authStore.findById(payload.sub);
      if (!user || user.status !== "active") {
        return reply.code(401).send({
          ok: false,
          error: {
            code: "UNAUTHORIZED",
            message: "Authentication required"
          }
        });
      }
      request.authPrincipal = toPrincipal(user);
    } catch {
      return reply.code(401).send({
        ok: false,
        error: {
          code: "UNAUTHORIZED",
          message: "Authentication required"
        }
      });
    }
  });

  server.decorate("authorize", (permission: string, options: AuthorizationOptions = {}) => {
    return async (request: FastifyRequest, reply: FastifyReply) => {
      await server.authenticate(request, reply);
      if (reply.sent) {
        return;
      }

      const principal = request.authPrincipal;
      const productId = requestedProductId(request);
      let error:
        | {
            code: "FORBIDDEN" | "GLOBAL_ACCESS_REQUIRED" | "PRODUCT_ACCESS_DENIED";
            message: string;
            targetType: "permission" | "global_permission" | "product";
            targetId: string;
          }
        | undefined;

      if (!principal || !can(principal, permission)) {
        error = {
          code: "FORBIDDEN",
          message: "Insufficient permission",
          targetType: "permission",
          targetId: permission
        };
      } else if (options.global && !hasGlobalProductAccess(principal)) {
        error = {
          code: "GLOBAL_ACCESS_REQUIRED",
          message: "This operation requires access to all products",
          targetType: "global_permission",
          targetId: permission
        };
      } else if (productId && !canAccessProduct(principal, productId)) {
        error = {
          code: "PRODUCT_ACCESS_DENIED",
          message: "Product access denied",
          targetType: "product",
          targetId: productId
        };
      }

      if (error) {
        await opsStore.createAuditLog({
          actorType: principal ? "user" : "public",
          actorId: principal?.id,
          action: "authorization.denied",
          targetType: error.targetType,
          targetId: error.targetId,
          productId,
          ipAddress: requestAddress(request),
          userAgent: request.headers["user-agent"],
          metadata: {
            method: request.method,
            url: request.url,
            permission,
            reason: error.code
          }
        });
        return reply.code(403).send({
          ok: false,
          error: {
            code: error.code,
            message: error.message
          }
        });
      }
    };
  });

  async function issueSession(user: AuthUser, request: FastifyRequest, replacedTokenHash?: string) {
    const principal = toPrincipal(user);
    const token = server.jwt.sign(
      {
        email: principal.email,
        roles: principal.roles
      },
      {
        sub: principal.id
      }
    );
    const refreshToken = createRefreshTokenValue();
    const refreshTokenHash = hashRefreshToken(refreshToken);
    await authStore.createRefreshToken({
      userId: user.id,
      tokenHash: refreshTokenHash,
      expiresAt: refreshTokenExpiresAt().toISOString(),
      ipAddress: requestAddress(request),
      userAgent: request.headers["user-agent"]
    });
    if (replacedTokenHash) {
      await authStore.revokeRefreshToken(replacedTokenHash, refreshTokenHash);
    }
    return {
      token,
      accessToken: token,
      access_token: token,
      refreshToken,
      refresh_token: refreshToken,
      tokenType: "Bearer",
      token_type: "Bearer",
      expiresIn: process.env.JWT_EXPIRES_IN ?? "8h",
      expires_in: process.env.JWT_EXPIRES_IN ?? "8h",
      user: principal
    };
  }

  server.post<{ Body: unknown }>("/api/v1/auth/login", async (request, reply) => {
    const parsed = loginSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(422).send({
        ok: false,
        error: {
          code: "VALIDATION_ERROR",
          message: "Invalid login payload",
          details: parsed.error.flatten()
        }
      });
    }

    const user = await authStore.findByEmail(parsed.data.email);
    if (!user || user.status !== "active" || !(await verifyPassword(parsed.data.password, user.passwordHash))) {
      await opsStore.createAuditLog({
        actorType: "public",
        action: "user.login_failed",
        targetType: "user",
        ipAddress: requestAddress(request),
        userAgent: request.headers["user-agent"],
        metadata: {
          email: parsed.data.email
        }
      });
      return reply.code(401).send({
        ok: false,
        error: {
          code: "INVALID_CREDENTIALS",
          message: "Invalid email or password"
        }
      });
    }

    const session = await issueSession(user, request);

    await authStore.touchLastLogin(user.id);
    await opsStore.createAuditLog({
      actorType: "user",
      actorId: user.id,
      action: "user.login",
      targetType: "user",
      targetId: user.id,
      ipAddress: requestAddress(request),
      userAgent: request.headers["user-agent"]
    });

    return {
      ok: true,
      data: session
    };
  });

  server.post<{ Body: unknown }>("/api/v1/auth/refresh", async (request, reply) => {
    const parsed = refreshTokenBodySchema.safeParse(request.body);
    if (!parsed.success) {
      return invalidRefreshToken(reply);
    }

    const tokenHash = hashRefreshToken(parsed.data.refreshToken);
    const record = await authStore.findRefreshToken(tokenHash);
    if (!record || record.revokedAt || new Date(record.expiresAt).getTime() <= Date.now()) {
      return invalidRefreshToken(reply);
    }

    const user = await authStore.findById(record.userId);
    if (!user || user.status !== "active") {
      return invalidRefreshToken(reply);
    }

    const session = await issueSession(user, request, tokenHash);
    await opsStore.createAuditLog({
      actorType: "user",
      actorId: user.id,
      action: "user.token_refreshed",
      targetType: "user",
      targetId: user.id,
      ipAddress: requestAddress(request),
      userAgent: request.headers["user-agent"]
    });

    return {
      ok: true,
      data: session
    };
  });

  server.post<{ Body: unknown }>("/api/v1/auth/logout", async (request, reply) => {
    const parsed = refreshTokenBodySchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(200).send({ ok: true });
    }

    const tokenHash = hashRefreshToken(parsed.data.refreshToken);
    const record = await authStore.findRefreshToken(tokenHash);
    if (record) {
      await authStore.revokeRefreshToken(tokenHash);
      await opsStore.createAuditLog({
        actorType: "user",
        actorId: record.userId,
        action: "user.logout",
        targetType: "user",
        targetId: record.userId,
        ipAddress: requestAddress(request),
        userAgent: request.headers["user-agent"]
      });
    }

    return reply.code(200).send({ ok: true });
  });

  server.patch<{ Body: unknown }>(
    "/api/v1/auth/me",
    {
      preHandler: server.authenticate
    },
    async (request, reply) => {
      const parsed = updateOwnProfileSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(422).send({
          ok: false,
          error: {
            code: "VALIDATION_ERROR",
            message: "Invalid account update payload",
            details: parsed.error.flatten()
          }
        });
      }

      const principal = request.authPrincipal;
      if (!principal) {
        return reply.code(401).send({
          ok: false,
          error: {
            code: "UNAUTHORIZED",
            message: "Authentication required"
          }
        });
      }

      const currentUser = await authStore.findById(principal.id);
      if (!currentUser || !(await verifyPassword(parsed.data.currentPassword, currentUser.passwordHash))) {
        await opsStore.createAuditLog({
          actorType: "user",
          actorId: principal.id,
          action: "user.profile_update_denied",
          targetType: "user",
          targetId: principal.id,
          ipAddress: requestAddress(request),
          userAgent: request.headers["user-agent"],
          metadata: { reason: "invalid_current_password" }
        });
        return reply.code(403).send({
          ok: false,
          error: {
            code: "INVALID_CURRENT_PASSWORD",
            message: "Current password is incorrect"
          }
        });
      }

      const nextEmail = parsed.data.email.toLowerCase();
      const emailChanged = nextEmail !== currentUser.email;
      const passwordChanged = parsed.data.newPassword !== undefined;
      const updated = await authStore.updateOwnProfile(principal.id, {
        name: parsed.data.name,
        email: nextEmail,
        ...(passwordChanged ? { password: parsed.data.newPassword } : {})
      });
      if (updated === "duplicate") {
        return reply.code(409).send({
          ok: false,
          error: {
            code: "EMAIL_IN_USE",
            message: "This email is already used by another admin user"
          }
        });
      }
      if (!updated) {
        return reply.code(404).send({
          ok: false,
          error: {
            code: "NOT_FOUND",
            message: "Admin user not found"
          }
        });
      }

      const reauthenticationRequired = emailChanged || passwordChanged;
      if (reauthenticationRequired) {
        await authStore.revokeRefreshTokensForUser(updated.id);
      }
      await opsStore.createAuditLog({
        actorType: "user",
        actorId: updated.id,
        action: "user.profile_updated",
        targetType: "user",
        targetId: updated.id,
        ipAddress: requestAddress(request),
        userAgent: request.headers["user-agent"],
        afterValue: {
          name: updated.name,
          email: updated.email,
          emailChanged,
          passwordChanged
        }
      });

      return {
        ok: true,
        data: {
          user: toPrincipal(updated),
          reauthenticationRequired
        }
      };
    }
  );

  server.get(
    "/api/v1/auth/me",
    {
      preHandler: server.authenticate
    },
    async (request) => ({
      ok: true,
      data: request.authPrincipal
    })
  );
}
