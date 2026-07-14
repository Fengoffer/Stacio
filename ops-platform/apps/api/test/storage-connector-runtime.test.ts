import { afterEach, describe, expect, it, vi } from "vitest";
import { encryptConnectorSecrets } from "../src/services/connectorSecrets.js";
import { createMemoryStore } from "../src/data/store.js";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("object storage connector runtime configuration", () => {
  it("uses the saved connector bucket and public base URL for release upload presigning", async () => {
    vi.stubEnv("CONNECTOR_ENCRYPTION_KEY_BASE64", Buffer.alloc(32, 7).toString("base64"));
    const store = createMemoryStore();
    await store.upsertConnector("stacio", "object_storage", {
      name: "Object Storage",
      config: {
        endpoint: "https://s3.example.com",
        region: "auto",
        bucket: "stacio-releases",
        forcePathStyle: true,
        publicBaseUrl: "https://downloads.example.com",
        objectPrefix: "products/stacio"
      },
      encryptedSecrets: encryptConnectorSecrets({
        accessKeyId: "access-key",
        secretAccessKey: "secret-key"
      })
    });
    const server = buildServer({ store });
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/storage/presign-upload",
      headers,
      payload: {
        category: "release_artifact",
        refId: "rel_0140",
        fileName: "Stacio-0.14.0.dmg",
        contentType: "application/x-apple-diskimage",
        sizeBytes: 4096,
        dryRun: true
      }
    });

    expect(response.statusCode).toBe(200);
    expect(response.json().data).toEqual(
      expect.objectContaining({
        bucket: "stacio-releases",
        objectKey: expect.stringContaining("products/stacio/release_artifact/rel_0140/"),
        publicUrl: expect.stringContaining("https://downloads.example.com/products/stacio/release_artifact/rel_0140/")
      })
    );
  });
});
