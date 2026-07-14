import { describe, expect, it } from "vitest";
import { buildServer } from "../src/server.js";
import { developmentOwnerCredentials } from "../src/auth/store.js";
import { ownerAuthorization } from "./helpers.js";

describe("admin authentication and audit", () => {
  it("rejects unauthenticated admin API access", async () => {
    const server = buildServer();
    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/dashboard"
    });

    expect(response.statusCode).toBe(401);
    expect(response.json()).toEqual(
      expect.objectContaining({
        ok: false,
        error: expect.objectContaining({
          code: "UNAUTHORIZED"
        })
      })
    );
  });

  it("issues an owner token and records login audit events", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const meResponse = await server.inject({
      method: "GET",
      url: "/api/v1/auth/me",
      headers
    });
    expect(meResponse.statusCode).toBe(200);
    expect(meResponse.json().data).toEqual(
      expect.objectContaining({
        email: developmentOwnerCredentials.email,
        roles: ["owner"],
        permissions: ["*"]
      })
    );

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs",
      headers
    });
    expect(auditResponse.statusCode).toBe(200);
    expect(auditResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          actorType: "user",
          action: "user.login"
        })
      ])
    );
  });

  it("rotates refresh tokens and revokes them on logout", async () => {
    const server = buildServer();

    const loginResponse = await server.inject({
      method: "POST",
      url: "/api/v1/auth/login",
      payload: developmentOwnerCredentials
    });
    expect(loginResponse.statusCode).toBe(200);
    expect(loginResponse.json().data).toEqual(
      expect.objectContaining({
        token: expect.any(String),
        refreshToken: expect.stringMatching(/^rt_/),
        tokenType: "Bearer"
      })
    );
    const firstRefreshToken = loginResponse.json().data.refreshToken as string;

    const refreshResponse = await server.inject({
      method: "POST",
      url: "/api/v1/auth/refresh",
      payload: {
        refreshToken: firstRefreshToken
      }
    });
    expect(refreshResponse.statusCode).toBe(200);
    expect(refreshResponse.json().data).toEqual(
      expect.objectContaining({
        token: expect.any(String),
        refreshToken: expect.stringMatching(/^rt_/),
        tokenType: "Bearer"
      })
    );
    const secondRefreshToken = refreshResponse.json().data.refreshToken as string;
    expect(secondRefreshToken).not.toBe(firstRefreshToken);

    const staleRefreshResponse = await server.inject({
      method: "POST",
      url: "/api/v1/auth/refresh",
      payload: {
        refreshToken: firstRefreshToken
      }
    });
    expect(staleRefreshResponse.statusCode).toBe(401);
    expect(staleRefreshResponse.json().error.code).toBe("INVALID_REFRESH_TOKEN");

    const meResponse = await server.inject({
      method: "GET",
      url: "/api/v1/auth/me",
      headers: {
        authorization: `Bearer ${refreshResponse.json().data.token}`
      }
    });
    expect(meResponse.statusCode).toBe(200);

    const logoutResponse = await server.inject({
      method: "POST",
      url: "/api/v1/auth/logout",
      payload: {
        refreshToken: secondRefreshToken
      }
    });
    expect(logoutResponse.statusCode).toBe(200);
    expect(logoutResponse.json()).toEqual(
      expect.objectContaining({
        ok: true
      })
    );

    const revokedRefreshResponse = await server.inject({
      method: "POST",
      url: "/api/v1/auth/refresh",
      payload: {
        refreshToken: secondRefreshToken
      }
    });
    expect(revokedRefreshResponse.statusCode).toBe(401);
    expect(revokedRefreshResponse.json().error.code).toBe("INVALID_REFRESH_TOKEN");
  });

  it("rejects invalid credentials and audits the failure", async () => {
    const server = buildServer();
    const response = await server.inject({
      method: "POST",
      url: "/api/v1/auth/login",
      payload: {
        email: developmentOwnerCredentials.email,
        password: "wrong-password"
      }
    });
    expect(response.statusCode).toBe(401);

    const headers = await ownerAuthorization(server);
    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs",
      headers
    });
    expect(auditResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          actorType: "public",
          action: "user.login_failed"
        })
      ])
    );
  });

  it("lets an owner update their account and revokes old refresh sessions", async () => {
    const server = buildServer();
    const loginResponse = await server.inject({
      method: "POST",
      url: "/api/v1/auth/login",
      payload: developmentOwnerCredentials
    });
    const session = loginResponse.json().data as { token: string; refreshToken: string };

    const updateResponse = await server.inject({
      method: "PATCH",
      url: "/api/v1/auth/me",
      headers: {
        authorization: `Bearer ${session.token}`
      },
      payload: {
        name: "Stacio Administrator",
        email: "admin@stacio.example",
        currentPassword: developmentOwnerCredentials.password,
        newPassword: "updated-owner-password"
      }
    });

    expect(updateResponse.statusCode).toBe(200);
    expect(updateResponse.json().data).toEqual(
      expect.objectContaining({
        reauthenticationRequired: true,
        user: expect.objectContaining({
          name: "Stacio Administrator",
          email: "admin@stacio.example"
        })
      })
    );

    const staleRefresh = await server.inject({
      method: "POST",
      url: "/api/v1/auth/refresh",
      payload: { refreshToken: session.refreshToken }
    });
    expect(staleRefresh.statusCode).toBe(401);

    const oldLogin = await server.inject({
      method: "POST",
      url: "/api/v1/auth/login",
      payload: developmentOwnerCredentials
    });
    expect(oldLogin.statusCode).toBe(401);

    const newLogin = await server.inject({
      method: "POST",
      url: "/api/v1/auth/login",
      payload: {
        email: "admin@stacio.example",
        password: "updated-owner-password"
      }
    });
    expect(newLogin.statusCode).toBe(200);
  });

  it("requires the current password before changing an account", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "PATCH",
      url: "/api/v1/auth/me",
      headers,
      payload: {
        name: "Stacio Administrator",
        email: developmentOwnerCredentials.email,
        currentPassword: "incorrect-current-password"
      }
    });

    expect(response.statusCode).toBe(403);
    expect(response.json().error.code).toBe("INVALID_CURRENT_PASSWORD");
  });

  it("lets the owner create, disable, and enable scoped admin users", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const rolesResponse = await server.inject({
      method: "GET",
      url: "/api/v1/admin/roles",
      headers
    });
    expect(rolesResponse.statusCode).toBe(200);
    expect(rolesResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          name: "operator"
        })
      ])
    );

    const createResponse = await server.inject({
      method: "POST",
      url: "/api/v1/admin/users",
      headers,
      payload: {
        email: "operator@example.com",
        name: "Support Operator",
        password: "operator-password",
        role: "operator",
        productIds: ["stacio"]
      }
    });
    expect(createResponse.statusCode).toBe(201);
    expect(createResponse.json().data).toEqual(
      expect.objectContaining({
        email: "operator@example.com",
        roles: ["operator"],
        productIds: ["stacio"],
        status: "active"
      })
    );
    const userId = createResponse.json().data.id;

    const loginResponse = await server.inject({
      method: "POST",
      url: "/api/v1/auth/login",
      payload: {
        email: "operator@example.com",
        password: "operator-password"
      }
    });
    expect(loginResponse.statusCode).toBe(200);
    expect(loginResponse.json().data.user).toEqual(
      expect.objectContaining({
        roles: ["operator"],
        productIds: ["stacio"]
      })
    );

    const disableResponse = await server.inject({
      method: "PATCH",
      url: `/api/v1/admin/users/${userId}`,
      headers,
      payload: {
        status: "disabled",
        confirmation: "DISABLE"
      }
    });
    expect(disableResponse.statusCode).toBe(200);
    expect(disableResponse.json().data).toEqual(
      expect.objectContaining({
        id: userId,
        status: "disabled"
      })
    );

    const disabledLoginResponse = await server.inject({
      method: "POST",
      url: "/api/v1/auth/login",
      payload: {
        email: "operator@example.com",
        password: "operator-password"
      }
    });
    expect(disabledLoginResponse.statusCode).toBe(401);

    const enableResponse = await server.inject({
      method: "PATCH",
      url: `/api/v1/admin/users/${userId}`,
      headers,
      payload: {
        status: "active",
        confirmation: "ENABLE"
      }
    });
    expect(enableResponse.statusCode).toBe(200);
    expect(enableResponse.json().data).toEqual(
      expect.objectContaining({
        id: userId,
        status: "active"
      })
    );

    const enabledLoginResponse = await server.inject({
      method: "POST",
      url: "/api/v1/auth/login",
      payload: {
        email: "operator@example.com",
        password: "operator-password"
      }
    });
    expect(enabledLoginResponse.statusCode).toBe(200);

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs",
      headers
    });
    expect(auditResponse.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          action: "admin_user.created",
          targetId: userId
        }),
        expect.objectContaining({
          action: "admin_user.disabled",
          targetId: userId
        }),
        expect.objectContaining({
          action: "admin_user.enabled",
          targetId: userId
        })
      ])
    );
  });
});
