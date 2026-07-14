import { afterEach, describe, expect, it, vi } from "vitest";
import type { ReleaseItem } from "../src/data/types.js";
import { upsertGitHubRelease } from "../src/services/releasePublishers.js";

const release: ReleaseItem = {
  id: "rel_0140",
  productId: "stacio",
  channel: "stable",
  version: "0.14.0",
  buildNumber: "140",
  status: "published",
  artifactName: "Stacio-0.14.0.dmg",
  artifactUrl: "https://downloads.example.com/products/stacio/releases/stable/0.14.0/Stacio-0.14.0.dmg",
  artifactType: "application/x-apple-diskimage",
  artifactSize: 4096,
  sparkleEdDsaSignature: "sparkle-signature",
  releaseNotes: "Stable release notes.",
  publishedAt: "2026-07-11T00:00:00.000Z",
  createdAt: "2026-07-11T00:00:00.000Z"
};

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("GitHub Release publisher", () => {
  it("creates a GitHub Release from the canonical published artifact and notes", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ message: "Not Found" }), { status: 404 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({
        id: 140,
        html_url: "https://github.com/Fengoffer/Stacio/releases/tag/v0.14.0"
      }), { status: 201 }));
    vi.stubGlobal("fetch", fetchMock);

    const result = await upsertGitHubRelease(
      {
        owner: "Fengoffer",
        repository: "Stacio",
        token: "github-token",
        apiBaseUrl: "https://api.github.test"
      },
      release
    );

    expect(result).toEqual({ externalUrl: "https://github.com/Fengoffer/Stacio/releases/tag/v0.14.0" });
    expect(fetchMock).toHaveBeenNthCalledWith(
      1,
      "https://api.github.test/repos/Fengoffer/Stacio/releases/tags/v0.14.0",
      expect.objectContaining({ headers: expect.objectContaining({ Authorization: "Bearer github-token" }) })
    );
    expect(fetchMock).toHaveBeenNthCalledWith(
      2,
      "https://api.github.test/repos/Fengoffer/Stacio/releases",
      expect.objectContaining({
        method: "POST",
        body: expect.stringContaining("https://downloads.example.com/products/stacio/releases/stable/0.14.0/Stacio-0.14.0.dmg")
      })
    );
  });
});
