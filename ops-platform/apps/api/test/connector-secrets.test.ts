import { afterEach, describe, expect, it, vi } from "vitest";
import {
  ConnectorEncryptionConfigurationError,
  decryptConnectorSecrets,
  encryptConnectorSecrets
} from "../src/services/connectorSecrets.js";

describe("connector secret encryption", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("uses a versioned AES-256-GCM envelope that does not contain plaintext", () => {
    vi.stubEnv("CONNECTOR_ENCRYPTION_KEY_BASE64", Buffer.alloc(32, 11).toString("base64"));

    const envelope = encryptConnectorSecrets({
      token: "top-secret-token",
      secondary: "another-secret"
    });

    expect(envelope).toMatch(/^v1\./);
    expect(envelope).not.toContain("top-secret-token");
    expect(decryptConnectorSecrets(envelope)).toEqual({
      token: "top-secret-token",
      secondary: "another-secret"
    });
  });

  it("rejects missing encryption keys in production", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("CONNECTOR_ENCRYPTION_KEY_BASE64", "");

    expect(() => encryptConnectorSecrets({ token: "secret" })).toThrow(ConnectorEncryptionConfigurationError);
  });

  it("rejects invalid encryption key lengths", () => {
    vi.stubEnv("CONNECTOR_ENCRYPTION_KEY_BASE64", Buffer.alloc(16, 1).toString("base64"));

    expect(() => encryptConnectorSecrets({ token: "secret" })).toThrow(ConnectorEncryptionConfigurationError);
  });
});
