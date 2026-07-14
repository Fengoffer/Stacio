import { describe, expect, it, vi } from "vitest";
import { createMemoryStore } from "../src/data/store.js";
import type { OpsJobQueue } from "../src/jobs/queue.js";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

describe("release publication orchestration", () => {
  it("creates auditable synchronization targets only after a manually publishable release is published", async () => {
    const store = createMemoryStore();
    const release = await store.createRelease("stacio", {
      channel: "stable",
      version: "0.14.0",
      buildNumber: "140",
      minimumSystemVersion: "14.0",
      artifactName: "Stacio-0.14.0.dmg",
      artifactUrl: "https://objects.example.com/releases/Stacio-0.14.0.dmg",
      artifactObjectKey: "products/stacio/release_artifact/rel_0140/Stacio-0.14.0.dmg",
      artifactType: "application/x-apple-diskimage",
      artifactSize: 4096,
      artifactSha256: "a".repeat(64),
      sparkleEdDsaSignature: "sparkle-signature",
      releaseNotes: "Stable release notes.",
      downloadReachabilityEvidence: {
        status: "reachable",
        statusCode: 200,
        contentLength: 4096,
        summary: "Object storage returned the expected artifact."
      }
    });
    expect(release).toBeDefined();
    const validation = await store.validateRelease("stacio", release!.id);
    expect(validation?.passed).toBe(true);
    expect(await store.publishRelease("stacio", release!.id, "usr_development_owner")).toEqual(
      expect.objectContaining({ status: "published" })
    );

    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);
    const response = await server.inject({
      method: "GET",
      url: `/api/v1/products/stacio/releases/${release!.id}/publications`,
      headers
    });

    expect(response.statusCode).toBe(200);
    expect(response.json().data).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ target: "object_storage", status: "queued" }),
        expect.objectContaining({ target: "appcast", status: "queued" }),
        expect.objectContaining({ target: "github", status: "queued" }),
        expect.objectContaining({ target: "website_catalog", status: "queued" })
      ])
    );
  });

  it("enqueues publication work only after the existing manual PUBLISH confirmation succeeds", async () => {
    const store = createMemoryStore();
    const release = await store.createRelease("stacio", {
      channel: "beta",
      version: "0.14.1-Beta",
      buildNumber: "141",
      minimumSystemVersion: "14.0",
      artifactName: "Stacio-0.14.1-Beta.dmg",
      artifactUrl: "https://objects.example.com/releases/Stacio-0.14.1-Beta.dmg",
      artifactObjectKey: "products/stacio/release_artifact/rel_0141/Stacio-0.14.1-Beta.dmg",
      artifactType: "application/x-apple-diskimage",
      artifactSize: 4096,
      artifactSha256: "b".repeat(64),
      sparkleEdDsaSignature: "sparkle-signature",
      releaseNotes: "Beta release notes.",
      downloadReachabilityEvidence: {
        status: "reachable",
        statusCode: 200,
        contentLength: 4096,
        summary: "Object storage returned the expected artifact."
      }
    });
    await store.validateRelease("stacio", release!.id);
    const enqueueReleasePublication = vi.fn(async (payload: unknown) => ({
      id: "job_release_0141",
      name: "release.publish" as const,
      payload
    }));
    const jobQueue: OpsJobQueue = {
      async enqueueNotificationSend(payload) {
        return { id: "job_notification", name: "notification.send", payload };
      },
      async enqueueGitHubPull(payload) {
        return { id: "job_github", name: "github.pull", payload };
      },
      enqueueReleasePublication
    };
    const server = buildServer({ store, jobQueue });
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${release!.id}/publish`,
      headers,
      payload: { confirmation: "PUBLISH" }
    });

    expect(response.statusCode).toBe(200);
    expect(enqueueReleasePublication).toHaveBeenCalledWith({
      productId: "stacio",
      releaseId: release!.id,
      requestedBy: "usr_development_owner"
    });
  });

  it("manually requeues a failed publication with RETRY_SYNC", async () => {
    const store = createMemoryStore();
    const release = await store.createRelease("stacio", {
      channel: "stable",
      version: "0.14.2",
      buildNumber: "142",
      minimumSystemVersion: "14.0",
      artifactName: "Stacio-0.14.2.dmg",
      artifactUrl: "https://objects.example.com/releases/Stacio-0.14.2.dmg",
      artifactObjectKey: "products/stacio/release_artifact/rel_0142/Stacio-0.14.2.dmg",
      artifactType: "application/x-apple-diskimage",
      artifactSize: 4096,
      artifactSha256: "c".repeat(64),
      sparkleEdDsaSignature: "sparkle-signature",
      releaseNotes: "Stable release notes.",
      downloadReachabilityEvidence: { status: "reachable", statusCode: 200, contentLength: 4096 }
    });
    await store.validateRelease("stacio", release!.id);
    await store.publishRelease("stacio", release!.id, "usr_development_owner");
    await store.updateReleasePublication("stacio", release!.id, "github", {
      status: "failed",
      lastError: "GitHub is temporarily unavailable"
    });

    const enqueueReleasePublication = vi.fn(async (payload: unknown) => ({
      id: "job_release_retry_0142",
      name: "release.publish" as const,
      payload
    }));
    const server = buildServer({
      store,
      jobQueue: {
        async enqueueNotificationSend(payload) {
          return { id: "job_notification", name: "notification.send", payload };
        },
        async enqueueGitHubPull(payload) {
          return { id: "job_github", name: "github.pull", payload };
        },
        enqueueReleasePublication
      }
    });
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "POST",
      url: `/api/v1/products/stacio/releases/${release!.id}/publications/retry`,
      headers,
      payload: { confirmation: "RETRY_SYNC" }
    });

    expect(response.statusCode).toBe(200);
    expect(enqueueReleasePublication).toHaveBeenCalledWith({
      productId: "stacio",
      releaseId: release!.id,
      requestedBy: "usr_development_owner"
    });
  });
});
