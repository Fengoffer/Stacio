import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";

export type ConnectorSecrets = Record<string, string>;

export class ConnectorEncryptionConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConnectorEncryptionConfigurationError";
  }
}

const developmentKey = createHash("sha256")
  .update("stacio-ops-development-connector-key")
  .digest();

function encryptionKey() {
  const configured = process.env.CONNECTOR_ENCRYPTION_KEY_BASE64?.trim();
  if (!configured) {
    if (process.env.NODE_ENV === "production") {
      throw new ConnectorEncryptionConfigurationError(
        "CONNECTOR_ENCRYPTION_KEY_BASE64 is required in production"
      );
    }
    return developmentKey;
  }

  const key = Buffer.from(configured, "base64");
  if (key.length !== 32) {
    throw new ConnectorEncryptionConfigurationError(
      "CONNECTOR_ENCRYPTION_KEY_BASE64 must decode to exactly 32 bytes"
    );
  }
  return key;
}

export function encryptConnectorSecrets(secrets: ConnectorSecrets) {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", encryptionKey(), iv);
  const encrypted = Buffer.concat([
    cipher.update(JSON.stringify(secrets), "utf8"),
    cipher.final()
  ]);
  const authenticationTag = cipher.getAuthTag();
  return [
    "v1",
    iv.toString("base64url"),
    authenticationTag.toString("base64url"),
    encrypted.toString("base64url")
  ].join(".");
}

export function decryptConnectorSecrets(envelope: string): ConnectorSecrets {
  const [version, encodedIv, encodedTag, encodedCiphertext, ...extra] = envelope.split(".");
  if (
    version !== "v1" ||
    !encodedIv ||
    !encodedTag ||
    !encodedCiphertext ||
    extra.length > 0
  ) {
    throw new Error("Unsupported connector secret envelope");
  }

  const decipher = createDecipheriv(
    "aes-256-gcm",
    encryptionKey(),
    Buffer.from(encodedIv, "base64url")
  );
  decipher.setAuthTag(Buffer.from(encodedTag, "base64url"));
  const plaintext = Buffer.concat([
    decipher.update(Buffer.from(encodedCiphertext, "base64url")),
    decipher.final()
  ]);
  const parsed = JSON.parse(plaintext.toString("utf8")) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Invalid connector secret payload");
  }

  for (const value of Object.values(parsed)) {
    if (typeof value !== "string") {
      throw new Error("Invalid connector secret value");
    }
  }
  return parsed as ConnectorSecrets;
}
