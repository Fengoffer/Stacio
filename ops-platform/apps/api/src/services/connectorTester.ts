import { HeadBucketCommand, S3Client } from "@aws-sdk/client-s3";
import nodemailer from "nodemailer";
import type { ConnectorSecrets } from "./connectorSecrets.js";

export type ConnectorType = "github" | "smtp" | "object_storage" | "agent_api" | "webhook";

export interface ConnectorTestInput {
  productId: string;
  type: ConnectorType;
  config: Record<string, unknown>;
  secrets: ConnectorSecrets;
}

export interface ConnectorTestResult {
  message: string;
  metadata?: Record<string, unknown>;
}

export interface ConnectorTester {
  test(input: ConnectorTestInput): Promise<ConnectorTestResult>;
}

function requiredString(
  values: Record<string, unknown> | ConnectorSecrets,
  key: string
) {
  const value = values[key];
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`Missing connector field: ${key}`);
  }
  return value.trim();
}

function optionalString(values: Record<string, unknown>, key: string) {
  const value = values[key];
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function trimBaseUrl(value: string) {
  return value.replace(/\/+$/, "");
}

async function testGitHub(input: ConnectorTestInput): Promise<ConnectorTestResult> {
  const owner = requiredString(input.config, "owner");
  const repository = requiredString(input.config, "repository");
  const apiBaseUrl = trimBaseUrl(
    optionalString(input.config, "apiBaseUrl") ?? "https://api.github.com"
  );
  const token = input.secrets.token;
  const response = await fetch(
    `${apiBaseUrl}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repository)}`,
    {
      headers: {
        Accept: "application/vnd.github+json",
        "User-Agent": "stacio-ops-platform",
        ...(token ? { Authorization: `Bearer ${token}` } : {})
      }
    }
  );
  if (!response.ok) {
    throw new Error(`GitHub repository check returned ${response.status}`);
  }
  return {
    message: "GitHub repository is accessible",
    metadata: { owner, repository }
  };
}

async function testSmtp(input: ConnectorTestInput): Promise<ConnectorTestResult> {
  const host = requiredString(input.config, "host");
  const port = Number(input.config.port ?? 587);
  const user = optionalString(input.config, "user");
  const password = input.secrets.password;
  const transporter = nodemailer.createTransport({
    host,
    port,
    secure: input.config.secure === true,
    auth: user && password ? { user, pass: password } : undefined
  });
  await transporter.verify();
  return {
    message: "SMTP connection verified",
    metadata: { host, port }
  };
}

async function testObjectStorage(
  input: ConnectorTestInput
): Promise<ConnectorTestResult> {
  const bucket = requiredString(input.config, "bucket");
  const client = new S3Client({
    region: optionalString(input.config, "region") ?? "auto",
    endpoint: optionalString(input.config, "endpoint"),
    forcePathStyle: input.config.forcePathStyle !== false,
    credentials: {
      accessKeyId: requiredString(input.secrets, "accessKeyId"),
      secretAccessKey: requiredString(input.secrets, "secretAccessKey"),
      ...(input.secrets.sessionToken
        ? { sessionToken: input.secrets.sessionToken }
        : {})
    }
  });
  await client.send(new HeadBucketCommand({ Bucket: bucket }));
  return {
    message: "Object storage bucket is accessible",
    metadata: { bucket }
  };
}

async function testAgentApi(input: ConnectorTestInput): Promise<ConnectorTestResult> {
  const baseUrl = trimBaseUrl(requiredString(input.config, "baseUrl"));
  const healthPath = optionalString(input.config, "healthPath") ?? "/health";
  const headerName = optionalString(input.config, "headerName") ?? "Authorization";
  const apiKey = requiredString(input.secrets, "apiKey");
  const response = await fetch(`${baseUrl}${healthPath.startsWith("/") ? "" : "/"}${healthPath}`, {
    headers: {
      [headerName]: headerName.toLowerCase() === "authorization" ? `Bearer ${apiKey}` : apiKey
    }
  });
  if (!response.ok) {
    throw new Error(`Agent API health check returned ${response.status}`);
  }
  return {
    message: "Agent API is reachable",
    metadata: { baseUrl, healthPath }
  };
}

async function testWebhook(input: ConnectorTestInput): Promise<ConnectorTestResult> {
  const url = requiredString(input.config, "url");
  const response = await fetch(url, { method: "HEAD" });
  if (response.status >= 500) {
    throw new Error(`Webhook endpoint returned ${response.status}`);
  }
  return {
    message: "Webhook endpoint is reachable",
    metadata: { url }
  };
}

export function createConnectorTester(): ConnectorTester {
  return {
    async test(input) {
      switch (input.type) {
        case "github":
          return testGitHub(input);
        case "smtp":
          return testSmtp(input);
        case "object_storage":
          return testObjectStorage(input);
        case "agent_api":
          return testAgentApi(input);
        case "webhook":
          return testWebhook(input);
      }
    }
  };
}
