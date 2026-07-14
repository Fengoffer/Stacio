import { CopyObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import type { ConnectorItem, Product, ReleaseArtifactItem, ReleaseItem } from "../data/types.js";
import type { OpsStore } from "../data/store.js";
import { decryptConnectorSecrets } from "./connectorSecrets.js";
import {
  ObjectStorageConfigurationError,
  objectStorageSettingsFromEnvironment,
  type ObjectStorageSettings
} from "./objectStorage.js";

export interface GitHubReleaseSettings {
  owner: string;
  repository: string;
  token: string;
  apiBaseUrl?: string;
}

function stringValue(value: unknown) {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

function boolValue(value: unknown, fallback = false) {
  return typeof value === "boolean" ? value : fallback;
}

function safePathPart(value: string) {
  return value.replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "") || "release";
}

function publicUrlFor(settings: ObjectStorageSettings, objectKey: string) {
  const base = settings.publicBaseUrl?.replace(/\/+$/, "");
  if (!base) {
    throw new Error("Object storage public base URL is required for release publication");
  }
  return `${base}/${objectKey}`;
}

function s3Client(settings: ObjectStorageSettings) {
  return new S3Client({
    region: settings.region,
    endpoint: settings.endpoint,
    forcePathStyle: settings.forcePathStyle,
    credentials: {
      accessKeyId: settings.accessKeyId,
      secretAccessKey: settings.secretAccessKey,
      ...(settings.sessionToken ? { sessionToken: settings.sessionToken } : {})
    }
  });
}

function connectorSettings(connector: ConnectorItem | undefined, envelope: string | undefined) {
  if (!connector) return undefined;
  const secrets = envelope ? decryptConnectorSecrets(envelope) : {};
  return { config: connector.config, secrets };
}

export async function resolveObjectStorageSettings(
  store: OpsStore,
  productId: string,
  options: { requirePublicBaseUrl?: boolean } = {}
): Promise<ObjectStorageSettings> {
  const connector = await store.findConnector(productId, "object_storage");
  const envelope = connector ? await store.getConnectorSecretEnvelope(productId, "object_storage") : undefined;
  const configured = connectorSettings(connector, envelope);
  const environment = objectStorageSettingsFromEnvironment();
  const accessKeyId = stringValue(configured?.secrets.accessKeyId) ?? environment?.accessKeyId;
  const secretAccessKey = stringValue(configured?.secrets.secretAccessKey) ?? environment?.secretAccessKey;
  const bucket = stringValue(configured?.config.bucket) ?? environment?.bucket;
  const publicBaseUrl = stringValue(configured?.config.publicBaseUrl) ?? environment?.publicBaseUrl;
  if (!accessKeyId || !secretAccessKey || !bucket || (options.requirePublicBaseUrl && !publicBaseUrl)) {
    throw new ObjectStorageConfigurationError(
      options.requirePublicBaseUrl
        ? "Object Storage connector requires bucket, public URL, and access credentials"
        : "Object Storage connector requires bucket and access credentials"
    );
  }
  return {
    endpoint: stringValue(configured?.config.endpoint) ?? environment?.endpoint,
    region: stringValue(configured?.config.region) ?? environment?.region ?? "auto",
    bucket,
    forcePathStyle: boolValue(configured?.config.forcePathStyle, environment?.forcePathStyle ?? true),
    publicBaseUrl,
    objectPrefix: stringValue(configured?.config.objectPrefix) ?? environment?.objectPrefix,
    accessKeyId,
    secretAccessKey,
    sessionToken: stringValue(configured?.secrets.sessionToken)
  };
}

export async function resolveGitHubReleaseSettings(store: OpsStore, product: Product): Promise<GitHubReleaseSettings> {
  const connector = await store.findConnector(product.id, "github");
  const envelope = connector ? await store.getConnectorSecretEnvelope(product.id, "github") : undefined;
  const configured = connectorSettings(connector, envelope);
  const token = stringValue(configured?.secrets.token) ?? process.env.GITHUB_TOKEN;
  const owner = stringValue(configured?.config.owner) ?? product.githubOwner ?? process.env.GITHUB_OWNER;
  const repository = stringValue(configured?.config.repository) ?? product.githubRepository ?? process.env.GITHUB_REPOSITORY;
  if (!token || !owner || !repository) {
    throw new Error("GitHub connector requires owner, repository, and token");
  }
  return {
    owner,
    repository,
    token,
    apiBaseUrl: stringValue(configured?.config.apiBaseUrl) ?? process.env.GITHUB_API_BASE_URL
  };
}

function releaseBody(release: ReleaseItem) {
  const sections = [release.releaseNotes?.trim() ?? "", "", `Official download: ${release.artifactUrl ?? ""}`]
    .filter((value, index) => value || index === 1);
  return sections.join("\n").trim();
}

function requestHeaders(token: string) {
  return {
    Accept: "application/vnd.github+json",
    Authorization: `Bearer ${token}`,
    "Content-Type": "application/json",
    "User-Agent": "stacio-ops-platform",
    "X-GitHub-Api-Version": "2022-11-28"
  };
}

export async function upsertGitHubRelease(settings: GitHubReleaseSettings, release: ReleaseItem) {
  const apiBaseUrl = (settings.apiBaseUrl ?? "https://api.github.com").replace(/\/+$/, "");
  const tagName = `v${release.version}`;
  const headers = requestHeaders(settings.token);
  const existingResponse = await fetch(
    `${apiBaseUrl}/repos/${encodeURIComponent(settings.owner)}/${encodeURIComponent(settings.repository)}/releases/tags/${encodeURIComponent(tagName)}`,
    { headers }
  );
  const body = {
    tag_name: tagName,
    name: `${release.version} (${release.channel})`,
    body: releaseBody(release),
    draft: false,
    prerelease: release.channel !== "stable"
  };
  let response: Response;
  if (existingResponse.status === 404) {
    response = await fetch(
      `${apiBaseUrl}/repos/${encodeURIComponent(settings.owner)}/${encodeURIComponent(settings.repository)}/releases`,
      { method: "POST", headers, body: JSON.stringify(body) }
    );
  } else if (existingResponse.ok) {
    const existing = await existingResponse.json() as { id?: number };
    if (!existing.id) {
      throw new Error("GitHub Release response is missing its ID");
    }
    response = await fetch(
      `${apiBaseUrl}/repos/${encodeURIComponent(settings.owner)}/${encodeURIComponent(settings.repository)}/releases/${existing.id}`,
      { method: "PATCH", headers, body: JSON.stringify(body) }
    );
  } else {
    throw new Error(`GitHub Release lookup failed with ${existingResponse.status}`);
  }
  if (!response.ok) {
    throw new Error(`GitHub Release upsert failed with ${response.status}`);
  }
  const published = await response.json() as { html_url?: string };
  if (!published.html_url) {
    throw new Error("GitHub Release response is missing its public URL");
  }
  return { externalUrl: published.html_url };
}

export interface GitHubReleaseDownloadMetric {
  tagName: string;
  name?: string;
  releaseUrl: string;
  publishedAt?: string;
  sourceZipUrl?: string;
  sourceTarUrl?: string;
  assets: Array<{
    id: number;
    name: string;
    sizeBytes: number;
    downloadCount: number;
    downloadUrl: string;
  }>;
}

export async function fetchGitHubReleaseDownloadMetrics(settings: GitHubReleaseSettings) {
  const apiBaseUrl = (settings.apiBaseUrl ?? "https://api.github.com").replace(/\/+$/, "");
  const response = await fetch(
    `${apiBaseUrl}/repos/${encodeURIComponent(settings.owner)}/${encodeURIComponent(settings.repository)}/releases?per_page=100`,
    { headers: requestHeaders(settings.token) }
  );
  if (!response.ok) {
    throw new Error(`GitHub Release metrics request failed with ${response.status}`);
  }
  const releases = await response.json() as Array<{
    tag_name?: string;
    name?: string;
    html_url?: string;
    published_at?: string;
    zipball_url?: string;
    tarball_url?: string;
    assets?: Array<{
      id?: number;
      name?: string;
      size?: number;
      download_count?: number;
      browser_download_url?: string;
    }>;
  }>;
  return {
    fetchedAt: new Date().toISOString(),
    sourceArchiveDetailAvailable: false,
    releases: releases.map((release) => ({
      tagName: release.tag_name ?? "unknown",
      name: release.name ?? undefined,
      releaseUrl: release.html_url ?? "",
      publishedAt: release.published_at ?? undefined,
      sourceZipUrl: release.zipball_url ?? undefined,
      sourceTarUrl: release.tarball_url ?? undefined,
      assets: (release.assets ?? []).map((asset) => ({
        id: asset.id ?? 0,
        name: asset.name ?? "unknown",
        sizeBytes: asset.size ?? 0,
        downloadCount: asset.download_count ?? 0,
        downloadUrl: asset.browser_download_url ?? ""
      }))
    })) satisfies GitHubReleaseDownloadMetric[]
  };
}

export function createReleasePublisher(store: OpsStore) {
  return {
    store,
    async publishArtifact({ product, release, artifact }: { product: Product; release: ReleaseItem; artifact: ReleaseArtifactItem }) {
      const settings = await resolveObjectStorageSettings(store, product.id, { requirePublicBaseUrl: true });
      const prefix = (product.objectStoragePrefix ?? `products/${product.id}`).replace(/\/+$/, "");
      const objectKey = `${prefix}/releases/${safePathPart(release.channel)}/${safePathPart(release.version)}/${safePathPart(release.artifactName)}`;
      await s3Client(settings).send(new CopyObjectCommand({
        Bucket: settings.bucket,
        Key: objectKey,
        CopySource: `${settings.bucket}/${artifact.objectKey!.split("/").map(encodeURIComponent).join("/")}`,
        MetadataDirective: "COPY"
      }));
      return { objectKey, publicUrl: publicUrlFor(settings, objectKey) };
    },
    async publishAppcast({ product, release, appcast }: { product: Product; release: ReleaseItem; appcast: { xml: string } }) {
      const settings = await resolveObjectStorageSettings(store, product.id, { requirePublicBaseUrl: true });
      const prefix = (product.objectStoragePrefix ?? `products/${product.id}`).replace(/\/+$/, "");
      const objectKey = `${prefix}/releases/${safePathPart(release.channel)}/appcast.xml`;
      await s3Client(settings).send(new PutObjectCommand({
        Bucket: settings.bucket,
        Key: objectKey,
        Body: appcast.xml,
        ContentType: "application/xml; charset=utf-8",
        CacheControl: "public, max-age=60"
      }));
      return { objectKey, publicUrl: publicUrlFor(settings, objectKey) };
    },
    async syncGitHubRelease({ product, release }: { product: Product; release: ReleaseItem }) {
      return upsertGitHubRelease(await resolveGitHubReleaseSettings(store, product), release);
    }
  };
}
