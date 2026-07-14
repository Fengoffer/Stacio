import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import type { OpsDatabase } from "../db/database.js";
import { refreshTokens, roles, userRoles, users } from "../db/schema.js";
import { hashPassword, hashPasswordSync } from "./password.js";

export interface AuthUser {
  id: string;
  email: string;
  name: string;
  passwordHash: string;
  status: "active" | "disabled";
  roles: string[];
  permissions: string[];
  productIds: string[];
}

export interface AuthRole {
  id: string;
  name: string;
  description?: string;
  permissions: string[];
}

export interface RefreshTokenRecord {
  id: string;
  userId: string;
  tokenHash: string;
  expiresAt: string;
  revokedAt?: string;
  replacedByTokenHash?: string;
  ipAddress?: string;
  userAgent?: string;
  createdAt: string;
}

export interface CreateRefreshTokenInput {
  userId: string;
  tokenHash: string;
  expiresAt: string;
  ipAddress?: string;
  userAgent?: string;
}

export interface AdminUserRecord {
  id: string;
  email: string;
  name: string;
  status: "active" | "disabled";
  roles: string[];
  permissions: string[];
  productIds: string[];
  lastLoginAt?: string;
  createdAt?: string;
  updatedAt?: string;
}

export interface CreateAdminUserInput {
  email: string;
  name: string;
  password: string;
  role: string;
  productIds: string[];
}

export interface UpdateAdminUserInput {
  name?: string;
  password?: string;
  status?: "active" | "disabled";
  role?: string;
  productIds?: string[];
}

export interface UpdateOwnProfileInput {
  name: string;
  email: string;
  password?: string;
}

export interface AuthStore {
  findByEmail(email: string): Promise<AuthUser | undefined>;
  findById(id: string): Promise<AuthUser | undefined>;
  touchLastLogin(id: string): Promise<void>;
  createRefreshToken(input: CreateRefreshTokenInput): Promise<RefreshTokenRecord>;
  findRefreshToken(tokenHash: string): Promise<RefreshTokenRecord | undefined>;
  revokeRefreshToken(tokenHash: string, replacedByTokenHash?: string): Promise<void>;
  revokeRefreshTokensForUser(userId: string): Promise<void>;
  updateOwnProfile(id: string, input: UpdateOwnProfileInput): Promise<AuthUser | "duplicate" | undefined>;
  listRoles(): Promise<AuthRole[]>;
  listUsers(): Promise<AdminUserRecord[]>;
  createUser(input: CreateAdminUserInput): Promise<AdminUserRecord | "duplicate" | "unknown_role">;
  updateUser(id: string, input: UpdateAdminUserInput): Promise<AdminUserRecord | "unknown_role" | undefined>;
}

export const developmentOwnerCredentials = {
  email: "owner@stacio.local",
  password: "change-me-now"
};

const defaultRoles: AuthRole[] = [
  {
    id: "role_owner",
    name: "owner",
    description: "Full system control",
    permissions: ["*"]
  },
  {
    id: "role_admin",
    name: "admin",
    description: "Manage products, feedback, releases, customers, licenses and settings",
    permissions: [
      "products:read",
      "products:write",
      "feedback:read",
      "feedback:write",
      "releases:read",
      "releases:write",
      "licenses:read",
      "licenses:write",
      "customers:read",
      "customers:write",
      "connectors:read",
      "connectors:write",
      "audit:read"
    ]
  },
  {
    id: "role_operator",
    name: "operator",
    description: "Triage feedback and operate non-destructive workflows",
    permissions: [
      "feedback:read",
      "feedback:write",
      "releases:read",
      "licenses:read",
      "customers:read",
      "notifications:write_draft"
    ]
  },
  {
    id: "role_readonly",
    name: "readonly",
    description: "Read-only access",
    permissions: ["products:read", "feedback:read", "releases:read", "licenses:read", "customers:read", "audit:read"]
  },
  {
    id: "role_agent",
    name: "agent",
    description: "Scoped external agent access",
    permissions: [
      "feedback:read",
      "feedback:write_analysis",
      "feedback:write_draft",
      "issues:read",
      "customers:read",
      "licenses:read",
      "notifications:write_draft",
      "actions:propose",
      "releases:read",
      "releases:write_draft"
    ]
  }
];

function adminUserFromAuthUser(user: AuthUser, timestamps: Partial<AdminUserRecord> = {}): AdminUserRecord {
  return {
    id: user.id,
    email: user.email,
    name: user.name,
    status: user.status,
    roles: user.roles,
    permissions: user.permissions,
    productIds: user.productIds,
    ...timestamps
  };
}

export function createMemoryAuthStore(): AuthStore {
  const usersById = new Map<string, AuthUser>();
  const refreshTokensByHash = new Map<string, RefreshTokenRecord>();
  const owner: AuthUser = {
    id: "usr_development_owner",
    email: process.env.DEVELOPMENT_OWNER_EMAIL ?? developmentOwnerCredentials.email,
    name: "Development Owner",
    passwordHash: hashPasswordSync(
      process.env.DEVELOPMENT_OWNER_PASSWORD ?? developmentOwnerCredentials.password,
      Buffer.from("stacio-dev-owner")
    ),
    status: "active",
    roles: ["owner"],
    permissions: ["*"],
    productIds: []
  };
  usersById.set(owner.id, owner);

  function roleByName(name: string) {
    return defaultRoles.find((role) => role.name === name);
  }

  function userFromEmail(email: string) {
    return [...usersById.values()].find((user) => user.email.toLowerCase() === email.toLowerCase());
  }

  function permissionsFor(roleNames: string[]) {
    return [...new Set(roleNames.flatMap((roleName) => roleByName(roleName)?.permissions ?? []))];
  }

  return {
    async findByEmail(email) {
      return userFromEmail(email);
    },
    async findById(id) {
      return usersById.get(id);
    },
    async touchLastLogin() {},
    async createRefreshToken(input) {
      const timestamp = new Date().toISOString();
      const record: RefreshTokenRecord = {
        id: `rt_${randomUUID()}`,
        ...input,
        createdAt: timestamp
      };
      refreshTokensByHash.set(record.tokenHash, record);
      return record;
    },
    async findRefreshToken(tokenHash) {
      return refreshTokensByHash.get(tokenHash);
    },
    async revokeRefreshToken(tokenHash, replacedByTokenHash) {
      const record = refreshTokensByHash.get(tokenHash);
      if (!record || record.revokedAt) {
        return;
      }
      record.revokedAt = new Date().toISOString();
      record.replacedByTokenHash = replacedByTokenHash;
    },
    async revokeRefreshTokensForUser(userId) {
      const revokedAt = new Date().toISOString();
      for (const record of refreshTokensByHash.values()) {
        if (record.userId === userId && !record.revokedAt) {
          record.revokedAt = revokedAt;
        }
      }
    },
    async updateOwnProfile(id, input) {
      const user = usersById.get(id);
      if (!user) {
        return undefined;
      }
      const email = input.email.toLowerCase();
      const existing = userFromEmail(email);
      if (existing && existing.id !== id) {
        return "duplicate";
      }
      user.name = input.name;
      user.email = email;
      if (input.password !== undefined) {
        user.passwordHash = hashPasswordSync(input.password);
      }
      return user;
    },
    async listRoles() {
      return defaultRoles;
    },
    async listUsers() {
      return [...usersById.values()].map((user) => adminUserFromAuthUser(user));
    },
    async createUser(input) {
      if (userFromEmail(input.email)) {
        return "duplicate";
      }
      const role = roleByName(input.role);
      if (!role) {
        return "unknown_role";
      }
      const user: AuthUser = {
        id: `usr_${randomUUID()}`,
        email: input.email.toLowerCase(),
        name: input.name,
        passwordHash: hashPasswordSync(input.password),
        status: "active",
        roles: [role.name],
        permissions: permissionsFor([role.name]),
        productIds: input.productIds
      };
      usersById.set(user.id, user);
      return adminUserFromAuthUser(user);
    },
    async updateUser(id, input) {
      const user = usersById.get(id);
      if (!user) {
        return undefined;
      }
      if (input.role && !roleByName(input.role)) {
        return "unknown_role";
      }
      if (input.name !== undefined) {
        user.name = input.name;
      }
      if (input.password !== undefined) {
        user.passwordHash = hashPasswordSync(input.password);
      }
      if (input.status !== undefined) {
        user.status = input.status;
      }
      if (input.role !== undefined) {
        user.roles = [input.role];
        user.permissions = permissionsFor(user.roles);
      }
      if (input.productIds !== undefined) {
        user.productIds = input.productIds;
      }
      return adminUserFromAuthUser(user);
    }
  };
}

export function createPostgresAuthStore(db: OpsDatabase): AuthStore {
  async function mapUser(row: typeof users.$inferSelect): Promise<AuthUser> {
    const assignments = await db
      .select({
        roleName: roles.name,
        permissions: roles.permissions,
        productId: userRoles.productId
      })
      .from(userRoles)
      .innerJoin(roles, eq(userRoles.roleId, roles.id))
      .where(eq(userRoles.userId, row.id));

    return {
      id: row.id,
      email: row.email,
      name: row.name,
      passwordHash: row.passwordHash,
      status: row.status as AuthUser["status"],
      roles: [...new Set(assignments.map((assignment) => assignment.roleName))],
      permissions: [...new Set(assignments.flatMap((assignment) => assignment.permissions))],
      productIds: [
        ...new Set(
          assignments
            .map((assignment) => assignment.productId)
            .filter((productId): productId is string => productId !== null)
        )
      ]
    };
  }

  async function mapAdminUser(row: typeof users.$inferSelect): Promise<AdminUserRecord> {
    const user = await mapUser(row);
    return adminUserFromAuthUser(user, {
      lastLoginAt: row.lastLoginAt?.toISOString(),
      createdAt: row.createdAt.toISOString(),
      updatedAt: row.updatedAt.toISOString()
    });
  }

  async function roleByName(name: string) {
    const [role] = await db.select().from(roles).where(eq(roles.name, name)).limit(1);
    return role;
  }

  async function assignRole(userId: string, roleName: string, productIds: string[]) {
    const role = await roleByName(roleName);
    if (!role) {
      return false;
    }
    await db.delete(userRoles).where(eq(userRoles.userId, userId));
    const assignments = productIds.length > 0 ? productIds : [null];
    await db.insert(userRoles).values(
      assignments.map((productId) => ({
        id: `user_role_${randomUUID()}`,
        userId,
        roleId: role.id,
        productId
      }))
    );
    return true;
  }

  return {
    async findByEmail(email) {
      const [row] = await db.select().from(users).where(eq(users.email, email.toLowerCase())).limit(1);
      return row ? mapUser(row) : undefined;
    },
    async findById(id) {
      const [row] = await db.select().from(users).where(eq(users.id, id)).limit(1);
      return row ? mapUser(row) : undefined;
    },
    async touchLastLogin(id) {
      await db.update(users).set({ lastLoginAt: new Date(), updatedAt: new Date() }).where(eq(users.id, id));
    },
    async createRefreshToken(input) {
      const [row] = await db
        .insert(refreshTokens)
        .values({
          id: `rt_${randomUUID()}`,
          userId: input.userId,
          tokenHash: input.tokenHash,
          expiresAt: new Date(input.expiresAt),
          ipAddress: input.ipAddress,
          userAgent: input.userAgent
        })
        .returning();
      return {
        id: row.id,
        userId: row.userId,
        tokenHash: row.tokenHash,
        expiresAt: row.expiresAt.toISOString(),
        revokedAt: row.revokedAt?.toISOString(),
        replacedByTokenHash: row.replacedByTokenHash ?? undefined,
        ipAddress: row.ipAddress ?? undefined,
        userAgent: row.userAgent ?? undefined,
        createdAt: row.createdAt.toISOString()
      };
    },
    async findRefreshToken(tokenHash) {
      const [row] = await db
        .select()
        .from(refreshTokens)
        .where(eq(refreshTokens.tokenHash, tokenHash))
        .limit(1);
      return row
        ? {
            id: row.id,
            userId: row.userId,
            tokenHash: row.tokenHash,
            expiresAt: row.expiresAt.toISOString(),
            revokedAt: row.revokedAt?.toISOString(),
            replacedByTokenHash: row.replacedByTokenHash ?? undefined,
            ipAddress: row.ipAddress ?? undefined,
            userAgent: row.userAgent ?? undefined,
            createdAt: row.createdAt.toISOString()
          }
        : undefined;
    },
    async revokeRefreshToken(tokenHash, replacedByTokenHash) {
      await db
        .update(refreshTokens)
        .set({
          revokedAt: new Date(),
          replacedByTokenHash
        })
        .where(eq(refreshTokens.tokenHash, tokenHash));
    },
    async revokeRefreshTokensForUser(userId) {
      await db
        .update(refreshTokens)
        .set({
          revokedAt: new Date()
        })
        .where(eq(refreshTokens.userId, userId));
    },
    async updateOwnProfile(id, input) {
      const [existing] = await db.select().from(users).where(eq(users.id, id)).limit(1);
      if (!existing) {
        return undefined;
      }
      const email = input.email.toLowerCase();
      if (email !== existing.email) {
        const [duplicate] = await db.select().from(users).where(eq(users.email, email)).limit(1);
        if (duplicate) {
          return "duplicate";
        }
      }
      const update: Partial<typeof users.$inferInsert> = {
        name: input.name,
        email,
        updatedAt: new Date()
      };
      if (input.password !== undefined) {
        update.passwordHash = await hashPassword(input.password);
      }
      await db.update(users).set(update).where(eq(users.id, id));
      const [row] = await db.select().from(users).where(eq(users.id, id)).limit(1);
      return mapUser(row);
    },
    async listRoles() {
      const rows = await db.select().from(roles);
      return rows.map((role) => ({
        id: role.id,
        name: role.name,
        description: role.description ?? undefined,
        permissions: role.permissions
      }));
    },
    async listUsers() {
      const rows = await db.select().from(users);
      return Promise.all(rows.map(mapAdminUser));
    },
    async createUser(input) {
      const [existing] = await db.select().from(users).where(eq(users.email, input.email.toLowerCase())).limit(1);
      if (existing) {
        return "duplicate";
      }
      if (!(await roleByName(input.role))) {
        return "unknown_role";
      }
      const id = `usr_${randomUUID()}`;
      await db.insert(users).values({
        id,
        email: input.email.toLowerCase(),
        name: input.name,
        passwordHash: await hashPassword(input.password),
        status: "active"
      });
      await assignRole(id, input.role, input.productIds);
      const [row] = await db.select().from(users).where(eq(users.id, id)).limit(1);
      return mapAdminUser(row);
    },
    async updateUser(id, input) {
      const [existing] = await db.select().from(users).where(eq(users.id, id)).limit(1);
      if (!existing) {
        return undefined;
      }
      if (input.role && !(await roleByName(input.role))) {
        return "unknown_role";
      }
      const update: Partial<typeof users.$inferInsert> = {
        updatedAt: new Date()
      };
      if (input.name !== undefined) {
        update.name = input.name;
      }
      if (input.password !== undefined) {
        update.passwordHash = await hashPassword(input.password);
      }
      if (input.status !== undefined) {
        update.status = input.status;
      }
      await db.update(users).set(update).where(eq(users.id, id));
      if (input.role !== undefined || input.productIds !== undefined) {
        const current = await mapUser(existing);
        await assignRole(
          id,
          input.role ?? current.roles[0] ?? "readonly",
          input.productIds ?? current.productIds
        );
      }
      const [row] = await db.select().from(users).where(eq(users.id, id)).limit(1);
      return mapAdminUser(row);
    }
  };
}
