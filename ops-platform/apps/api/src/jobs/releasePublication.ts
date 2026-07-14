import type { AppcastEntryItem, Product, ReleaseArtifactItem, ReleaseItem, ReleasePublicationTarget } from "../data/types.js";
import type { OpsStore } from "../data/store.js";

export interface ReleasePublicationJobPayload {
  productId: string;
  releaseId: string;
  requestedBy?: string;
}

export interface PublishReleaseArtifactInput {
  product: Product;
  release: ReleaseItem;
  artifact: ReleaseArtifactItem;
}

export interface PublishAppcastInput {
  product: Product;
  release: ReleaseItem;
  appcast: AppcastEntryItem;
}

export interface SyncGitHubReleaseInput {
  product: Product;
  release: ReleaseItem;
}

export interface ReleasePublicationDependencies {
  store: OpsStore;
  publishArtifact: (input: PublishReleaseArtifactInput) => Promise<{ objectKey: string; publicUrl: string }>;
  publishAppcast: (input: PublishAppcastInput) => Promise<{ objectKey: string; publicUrl?: string }>;
  syncGitHubRelease: (input: SyncGitHubReleaseInput) => Promise<{ externalUrl: string }>;
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : "Unknown release publication error";
}

async function updateTarget(
  store: OpsStore,
  payload: ReleasePublicationJobPayload,
  target: ReleasePublicationTarget,
  input: Parameters<OpsStore["updateReleasePublication"]>[3]
) {
  const publication = await store.updateReleasePublication(payload.productId, payload.releaseId, target, input);
  if (!publication) {
    throw new Error(`Release publication target is missing: ${target}`);
  }
  return publication;
}

async function runTarget<T>(
  store: OpsStore,
  payload: ReleasePublicationJobPayload,
  target: ReleasePublicationTarget,
  task: () => Promise<T>,
  result: (value: T) => { objectKey?: string; externalUrl?: string; metadata?: Record<string, unknown> } = () => ({})
) {
  await updateTarget(store, payload, target, {
    status: "running",
    lastError: null,
    startedAt: new Date().toISOString(),
    completedAt: null,
    incrementAttempts: true
  });
  try {
    const value = await task();
    const output = result(value);
    await updateTarget(store, payload, target, {
      status: "succeeded",
      ...output,
      lastError: null,
      completedAt: new Date().toISOString()
    });
    return value;
  } catch (error) {
    await updateTarget(store, payload, target, {
      status: "failed",
      lastError: errorMessage(error),
      completedAt: new Date().toISOString()
    });
    throw error;
  }
}

export async function processReleasePublicationJob(
  payload: ReleasePublicationJobPayload,
  dependencies: ReleasePublicationDependencies
) {
  const product = await dependencies.store.findProduct(payload.productId);
  const initialRelease = (await dependencies.store.listReleases(payload.productId)).find(
    (release) => release.id === payload.releaseId && release.status === "published"
  );
  if (!product || !initialRelease) {
    throw new Error("Published release not found");
  }
  const artifacts = await dependencies.store.listReleaseArtifacts(payload.productId, payload.releaseId);
  const artifact = artifacts.find((item) => item.objectKey) ?? artifacts[0];
  if (!artifact?.objectKey) {
    throw new Error("Published release is missing its staged object-storage key");
  }

  const existingPublications = await dependencies.store.listReleasePublications(payload.productId, payload.releaseId);
  const publicationFor = (target: ReleasePublicationTarget) =>
    existingPublications.find((publication) => publication.target === target);
  const existingArtifactPublication = publicationFor("object_storage");
  const publishedArtifact =
    existingArtifactPublication?.status === "succeeded" &&
    existingArtifactPublication.objectKey &&
    existingArtifactPublication.externalUrl
      ? {
          objectKey: existingArtifactPublication.objectKey,
          publicUrl: existingArtifactPublication.externalUrl
        }
      : await runTarget(
          dependencies.store,
          payload,
          "object_storage",
          () => dependencies.publishArtifact({ product, release: initialRelease, artifact }),
          (value) => ({ objectKey: value.objectKey, externalUrl: value.publicUrl })
        );
  const release = await dependencies.store.finalizePublishedReleaseArtifact(payload.productId, payload.releaseId, {
    objectKey: publishedArtifact.objectKey,
    artifactUrl: publishedArtifact.publicUrl
  });
  if (!release) {
    throw new Error("Published release could not be updated with its object-storage artifact");
  }
  const appcast = (await dependencies.store.listAppcastEntries(payload.productId, release.channel)).find(
    (entry) => entry.releaseId === release.id
  );
  if (!appcast) {
    throw new Error("Published release appcast entry is missing");
  }

  if (publicationFor("appcast")?.status !== "succeeded") {
    await runTarget(
      dependencies.store,
      payload,
      "appcast",
      () => dependencies.publishAppcast({ product, release, appcast }),
      (value) => ({ objectKey: value.objectKey, externalUrl: value.publicUrl })
    );
  }
  if (publicationFor("website_catalog")?.status !== "succeeded") {
    await runTarget(
      dependencies.store,
      payload,
      "website_catalog",
      async () => undefined,
      () => ({
        externalUrl: `/api/v1/public/products/${encodeURIComponent(product.id)}/releases`
      })
    );
  }
  if (publicationFor("github")?.status !== "succeeded") {
    await runTarget(
      dependencies.store,
      payload,
      "github",
      () => dependencies.syncGitHubRelease({ product, release }),
      (value) => ({ externalUrl: value.externalUrl })
    );
  }
}
