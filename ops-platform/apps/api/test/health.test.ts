import { describe, expect, it } from "vitest";
import { buildServer } from "../src/server";

describe("health route", () => {
  it("returns an operational health payload", async () => {
    const server = buildServer();

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/health",
      headers: {
        "x-request-id": "req_health_trace_001"
      }
    });

    expect(response.statusCode).toBe(200);
    expect(response.headers["x-request-id"]).toBe("req_health_trace_001");
    expect(response.json()).toEqual(
      expect.objectContaining({
        ok: true,
        data: {
          service: "stacio-ops-api",
          status: "ok"
        },
        meta: {
          request_id: "req_health_trace_001",
          timestamp: expect.any(String)
        }
      })
    );
  });

  it("returns request trace metadata on JSON errors", async () => {
    const server = buildServer();

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/dashboard",
      headers: {
        "x-request-id": "req_auth_error_trace_001"
      }
    });

    expect(response.statusCode).toBe(401);
    expect(response.headers["x-request-id"]).toBe("req_auth_error_trace_001");
    expect(response.json()).toEqual(
      expect.objectContaining({
        ok: false,
        error: expect.objectContaining({
          code: "UNAUTHORIZED"
        }),
        meta: {
          request_id: "req_auth_error_trace_001",
          timestamp: expect.any(String)
        }
      })
    );
  });
});
