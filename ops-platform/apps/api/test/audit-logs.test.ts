import { afterEach, describe, expect, it, vi } from "vitest";
import { createMemoryStore } from "../src/data/store.js";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

describe("audit log filtering", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("filters audit logs by actor, action, target, IP, date range, and search text", async () => {
    const store = createMemoryStore();

    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-10T02:00:00.000Z"));
    await store.createAuditLog({
      actorType: "user",
      actorId: "usr_release_admin",
      action: "release.publish",
      targetType: "release",
      targetId: "rel_0140",
      productId: "stacio",
      afterValue: {
        version: "0.14.0",
        channel: "beta"
      },
      ipAddress: "203.0.113.10",
      userAgent: "Safari"
    });

    vi.setSystemTime(new Date("2026-07-10T04:00:00.000Z"));
    await store.createAuditLog({
      actorType: "user",
      actorId: "usr_license_admin",
      action: "license.revoke",
      targetType: "license",
      targetId: "lic_pro",
      productId: "stacio",
      ipAddress: "203.0.113.11"
    });

    vi.setSystemTime(new Date("2026-07-11T02:00:00.000Z"));
    await store.createAuditLog({
      actorType: "agent",
      actorId: "codex",
      action: "agent.analysis_written",
      targetType: "feedback",
      targetId: "fb_other",
      productId: "other-product",
      ipAddress: "203.0.113.12"
    });
    vi.useRealTimers();

    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);
    const response = await server.inject({
      method: "GET",
      url:
        "/api/v1/audit-logs?productId=stacio" +
        "&action=release.publish" +
        "&actorType=user" +
        "&actorId=usr_release_admin" +
        "&targetType=release" +
        "&targetId=rel_0140" +
        "&ipAddress=203.0.113.10" +
        "&createdFrom=2026-07-10T00%3A00%3A00.000Z" +
        "&createdTo=2026-07-10T23%3A59%3A59.999Z" +
        "&search=0.14.0",
      headers
    });

    expect(response.statusCode).toBe(200);
    expect(response.json().data).toEqual([
      expect.objectContaining({
        action: "release.publish",
        actorId: "usr_release_admin",
        targetId: "rel_0140",
        ipAddress: "203.0.113.10"
      })
    ]);
  });
});
