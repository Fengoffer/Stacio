import { randomUUID } from "node:crypto";
import { PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

export const objectStorageUploadCategories = [
  "feedback_attachment",
  "release_artifact",
  "release_notes",
  "appcast_file",
  "diagnostics_summary",
  "offline_license",
  "email_asset",
  "generic"
] as const;

export type ObjectStorageUploadCategory = (typeof objectStorageUploadCategories)[number];

export interface PresignUploadInput {
  productId: string;
  category: ObjectStorageUploadCategory;
  fileName: string;
  contentType: string;
  sizeBytes: number;
  refId?: string;
  dryRun?: boolean;
}

export interface ObjectStorageSettings {
  endpoint?: string;
  region: string;
  bucket: string;
  forcePathStyle: boolean;
  publicBaseUrl?: string;
  objectPrefix?: string;
  accessKeyId: string;
  secretAccessKey: string;
  sessionToken?: string;
}

export interface PresignedUpload {
  objectKey: string;
  bucket: string;
  uploadUrl: string;
  method: "PUT";
  headers: Record<string, string>;
  expiresInSeconds: number;
  publicUrl?: string;
  dryRun: boolean;
}

export class ObjectStorageConfigurationError extends Error {
  constructor(message = "Object storage is not configured") {
    super(message);
    this.name = "ObjectStorageConfigurationError";
  }
}

function boolFromEnv(value: string | undefined, fallback = false) {
  if (value === undefined) return fallback;
  return ["1", "true", "yes", "on"].includes(value.toLowerCase());
}

export function objectStorageSettingsFromEnvironment(): ObjectStorageSettings | undefined {
  const bucket = process.env.S3_BUCKET;
  const accessKeyId = process.env.S3_ACCESS_KEY_ID;
  const secretAccessKey = process.env.S3_SECRET_ACCESS_KEY;
  if (!bucket || !accessKeyId || !secretAccessKey) {
    return undefined;
  }
  return {
    endpoint: process.env.S3_ENDPOINT,
    region: process.env.S3_REGION ?? "auto",
    bucket,
    forcePathStyle: boolFromEnv(process.env.S3_FORCE_PATH_STYLE, true),
    publicBaseUrl: process.env.S3_PUBLIC_BASE_URL,
    objectPrefix: process.env.S3_OBJECT_PREFIX,
    accessKeyId,
    secretAccessKey
  };
}

export function isObjectStorageConfigured() {
  return objectStorageSettingsFromEnvironment() !== undefined;
}

function safeFileName(fileName: string) {
  return fileName.replace(/[^a-zA-Z0-9._-]+/g, "-").replace(/^-+|-+$/g, "") || "upload.bin";
}

function publicUrlFor(objectKey: string, settings?: ObjectStorageSettings) {
  const publicBaseUrl = settings?.publicBaseUrl?.replace(/\/+$/, "");
  return publicBaseUrl ? `${publicBaseUrl}/${objectKey}` : undefined;
}

function objectKeyFor(input: PresignUploadInput, settings?: ObjectStorageSettings) {
  const prefix = settings?.objectPrefix ?? `products/${input.productId}`;
  const ref = input.refId ? `${input.refId}/` : "";
  return `${prefix}/${input.category}/${ref}${randomUUID()}-${safeFileName(input.fileName)}`;
}

export async function createPresignedUpload(
  input: PresignUploadInput,
  settings = objectStorageSettingsFromEnvironment()
): Promise<PresignedUpload> {
  const expiresInSeconds = Number(process.env.S3_PRESIGN_EXPIRES_SECONDS ?? 900);
  const bucket = settings?.bucket ?? "stacio-ops";
  const objectKey = objectKeyFor(input, settings);
  const headers = {
    "Content-Type": input.contentType
  };

  if (input.dryRun) {
    return {
      objectKey,
      bucket,
      uploadUrl: `mock://object-storage/${bucket}/${objectKey}`,
      method: "PUT",
      headers,
      expiresInSeconds,
      publicUrl: publicUrlFor(objectKey, settings),
      dryRun: true
    };
  }

  if (!settings) {
    throw new ObjectStorageConfigurationError();
  }

  const client = new S3Client({
    region: settings.region,
    endpoint: settings.endpoint,
    forcePathStyle: settings.forcePathStyle,
    credentials: {
      accessKeyId: settings.accessKeyId,
      secretAccessKey: settings.secretAccessKey,
      ...(settings.sessionToken ? { sessionToken: settings.sessionToken } : {})
    }
  });
  const command = new PutObjectCommand({
    Bucket: bucket,
    Key: objectKey,
    ContentType: input.contentType,
    ContentLength: input.sizeBytes
  });
  const uploadUrl = await getSignedUrl(client, command, {
    expiresIn: expiresInSeconds
  });

  return {
    objectKey,
    bucket,
    uploadUrl,
    method: "PUT",
    headers,
    expiresInSeconds,
    publicUrl: publicUrlFor(objectKey, settings),
    dryRun: false
  };
}
