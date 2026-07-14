import { afterEach, describe, expect, it, vi } from "vitest";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

describe("GitHub distribution metrics", () => {
  it("returns aggregate Release Asset downloads and labels unavailable source-archive detail", async () => {
    vi.stubEnv("GITHUB_OWNER", "Fengoffer");
    vi.stubEnv("GITHUB_REPOSITORY", "Stacio");
    vi.stubEnv("GITHUB_TOKEN", "github-token");
    vi.stubEnv("GITHUB_API_BASE_URL", "https://api.github.test");
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify([
      {
        id: 140,
        tag_name: "v0.14.0",
        name: "0.14.0",
        html_url: "https://github.com/Fengoffer/Stacio/releases/tag/v0.14.0",
        published_at: "2026-07-11T00:00:00.000Z",
        zipball_url: "https://api.github.test/repos/Fengoffer/Stacio/zipball/v0.14.0",
        tarball_url: "https://api.github.test/repos/Fengoffer/Stacio/tarball/v0.14.0",
        assets: [
          {
            id: 1,
            name: "Stacio-0.14.0.dmg",
            size: 4096,
            download_count: 17,
            browser_download_url: "https://github.com/Fengoffer/Stacio/releases/download/v0.14.0/Stacio-0.14.0.dmg"
          }
        ]
      }
    ]), { status: 200 })));
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/github/download-metrics",
      headers
    });

    expect(response.statusCode).toBe(200);
    expect(response.json().data).toEqual(
      expect.objectContaining({
        fetchedAt: expect.any(String),
        sourceArchiveDetailAvailable: false,
        releases: [
          expect.objectContaining({
            tagName: "v0.14.0",
            assets: [expect.objectContaining({ name: "Stacio-0.14.0.dmg", downloadCount: 17 })]
          })
        ]
      })
    );
  });
});
