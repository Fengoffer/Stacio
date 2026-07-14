import { describe, expect, it, vi } from "vitest";
import { createMemoryStore } from "../src/data/store.js";
import { processReleasePublicationJob } from "../src/jobs/releasePublication.js";
import { processOpsQueueJob } from "../src/jobs/worker.js";

async function publishedRelease() {
  const store = createMemoryStore();
  const release = await store.createRelease("stacio", {
    channel: "stable",
    version: "0.14.0",
    buildNumber: "140",
    minimumSystemVersion: "14.0",
    artifactName: "Stacio-0.14.0.dmg",
    artifactUrl: "https://staging.objects.example.com/uploads/Stacio-0.14.0.dmg",
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
  await store.validateRelease("stacio", release!.id);
  await store.publishRelease("stacio", release!.id, "usr_development_owner");
  return { store, release: release! };
}

describe("release publication worker", () => {
  it("publishes an immutable artifact before synchronizing appcast, GitHub, and the website catalog", async () => {
    const { store, release } = await publishedRelease();
    const publishArtifact = vi.fn(async () => ({
      objectKey: "products/stacio/releases/stable/0.14.0/Stacio-0.14.0.dmg",
      publicUrl: "https://downloads.example.com/products/stacio/releases/stable/0.14.0/Stacio-0.14.0.dmg"
    }));
    const publishAppcast = vi.fn(async () => ({
      objectKey: "products/stacio/releases/stable/appcast.xml",
      publicUrl: "https://downloads.example.com/products/stacio/releases/stable/appcast.xml"
    }));
    const syncGitHubRelease = vi.fn(async () => ({
      externalUrl: "https://github.com/Fengoffer/Stacio/releases/tag/v0.14.0"
    }));

    await processReleasePublicationJob(
      { productId: "stacio", releaseId: release.id },
      { store, publishArtifact, publishAppcast, syncGitHubRelease }
    );

    expect(publishArtifact).toHaveBeenCalledWith(
      expect.objectContaining({
        release: expect.objectContaining({ id: release.id }),
        artifact: expect.objectContaining({ objectKey: "products/stacio/release_artifact/rel_0140/Stacio-0.14.0.dmg" })
      })
    );
    expect(publishAppcast).toHaveBeenCalledWith(
      expect.objectContaining({
        release: expect.objectContaining({
          artifactUrl: "https://downloads.example.com/products/stacio/releases/stable/0.14.0/Stacio-0.14.0.dmg"
        })
      })
    );
    expect(syncGitHubRelease).toHaveBeenCalledWith(
      expect.objectContaining({
        release: expect.objectContaining({
          artifactUrl: "https://downloads.example.com/products/stacio/releases/stable/0.14.0/Stacio-0.14.0.dmg"
        })
      })
    );
    expect(await store.listReleasePublications("stacio", release.id)).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ target: "object_storage", status: "succeeded", attempts: 1 }),
        expect.objectContaining({ target: "appcast", status: "succeeded", attempts: 1 }),
        expect.objectContaining({ target: "github", status: "succeeded", attempts: 1 }),
        expect.objectContaining({ target: "website_catalog", status: "succeeded", attempts: 1 })
      ])
    );
  });

  it("updates the website catalog before GitHub and only retries the failed target", async () => {
    const { store, release } = await publishedRelease();
    const publishArtifact = vi.fn(async () => ({
      objectKey: "products/stacio/releases/stable/0.14.0/Stacio-0.14.0.dmg",
      publicUrl: "https://downloads.example.com/products/stacio/releases/stable/0.14.0/Stacio-0.14.0.dmg"
    }));
    const publishAppcast = vi.fn(async () => ({
      objectKey: "products/stacio/releases/stable/appcast.xml",
      publicUrl: "https://downloads.example.com/products/stacio/releases/stable/appcast.xml"
    }));
    const syncGitHubRelease = vi
      .fn()
      .mockImplementationOnce(async () => {
        const publications = await store.listReleasePublications("stacio", release.id);
        expect(publications.find((item) => item.target === "website_catalog")).toEqual(
          expect.objectContaining({ status: "succeeded" })
        );
        throw new Error("GitHub is temporarily unavailable");
      })
      .mockResolvedValueOnce({ externalUrl: "https://github.com/Fengoffer/Stacio/releases/tag/v0.14.0" });

    await expect(
      processReleasePublicationJob(
        { productId: "stacio", releaseId: release.id },
        { store, publishArtifact, publishAppcast, syncGitHubRelease }
      )
    ).rejects.toThrow("GitHub is temporarily unavailable");

    await processReleasePublicationJob(
      { productId: "stacio", releaseId: release.id },
      { store, publishArtifact, publishAppcast, syncGitHubRelease }
    );

    expect(publishArtifact).toHaveBeenCalledTimes(1);
    expect(publishAppcast).toHaveBeenCalledTimes(1);
    expect(syncGitHubRelease).toHaveBeenCalledTimes(2);
    expect(await store.listReleasePublications("stacio", release.id)).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ target: "object_storage", status: "succeeded", attempts: 1 }),
        expect.objectContaining({ target: "appcast", status: "succeeded", attempts: 1 }),
        expect.objectContaining({ target: "website_catalog", status: "succeeded", attempts: 1 }),
        expect.objectContaining({ target: "github", status: "succeeded", attempts: 2 })
      ])
    );
  });

  it("dispatches release.publish jobs to the publication processor", async () => {
    const processReleasePublication = vi.fn(async () => ({ status: "ok" }));

    await processOpsQueueJob(
      {
        name: "release.publish",
        data: { productId: "stacio", releaseId: "rel_001" }
      },
      {
        processNotification: async () => undefined,
        processGitHubPull: async () => undefined,
        processWebhookDispatch: async () => undefined,
        processReleasePublication
      }
    );

    expect(processReleasePublication).toHaveBeenCalledWith({ productId: "stacio", releaseId: "rel_001" });
  });
});
