import { describe, expect, it } from "vitest";
import { createMemoryStore } from "../src/data/store.js";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

describe("public website distribution and analytics", () => {
  it("exposes published releases for the official website", async () => {
    const server = buildServer();

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/public/products/stacio/releases?channel=stable"
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual(
      expect.objectContaining({
        ok: true,
        data: expect.objectContaining({
          product: expect.objectContaining({
            id: "stacio",
            name: "Stacio"
          }),
          releases: expect.arrayContaining([
            expect.objectContaining({
              id: "rel_001",
              channel: "stable",
              version: "0.13.1-Beta",
              downloadUrl: expect.stringContaining("/downloads/rel_001")
            })
          ])
        })
      })
    );
  });

  it("records an official download redirect before sending the browser to the published artifact", async () => {
    const store = createMemoryStore();
    const release = await store.createRelease("stacio", {
      channel: "stable",
      version: "0.14.0",
      buildNumber: "140",
      minimumSystemVersion: "14.0",
      artifactName: "Stacio-0.14.0.dmg",
      artifactUrl: "https://downloads.example.com/products/stacio/releases/stable/0.14.0/Stacio-0.14.0.dmg",
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
    await store.publishRelease("stacio", release!.id);
    const server = buildServer({ store });

    const response = await server.inject({
      method: "GET",
      url: `/api/v1/public/products/stacio/downloads/${release!.id}?visitorId=visitor_002&sessionId=session_002&platform=macOS&architecture=arm64`,
      headers: {
        "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 Version/17.5 Safari/605.1.15"
      }
    });

    expect(response.statusCode).toBe(302);
    expect(response.headers.location).toBe("https://downloads.example.com/products/stacio/releases/stable/0.14.0/Stacio-0.14.0.dmg");
    const summary = await store.websiteAnalytics("stacio");
    expect(summary?.overview.downloadRequests).toBe(1);
    expect(summary?.recentEvents).toEqual(
      expect.arrayContaining([expect.objectContaining({ type: "download_redirected", releaseId: release!.id })])
    );
  });

  it("deduplicates website telemetry and exposes real-time download dimensions", async () => {
    const server = buildServer();
    const ownerHeaders = await ownerAuthorization(server);
    const commonHeaders = {
      "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 Version/17.5 Safari/605.1.15"
    };

    const pageView = {
      eventId: "evt_site_page_001",
      type: "page_view",
      path: "/",
      visitorId: "visitor_001",
      sessionId: "session_001",
      platform: "macOS",
      architecture: "arm64",
      referrer: "https://www.google.com/"
    };
    const firstPageView = await server.inject({
      method: "POST",
      url: "/api/v1/public/products/stacio/telemetry",
      headers: commonHeaders,
      payload: pageView
    });
    const repeatedPageView = await server.inject({
      method: "POST",
      url: "/api/v1/public/products/stacio/telemetry",
      headers: commonHeaders,
      payload: pageView
    });
    const download = await server.inject({
      method: "POST",
      url: "/api/v1/public/products/stacio/telemetry",
      headers: commonHeaders,
      payload: {
        eventId: "evt_site_download_001",
        type: "download_requested",
        path: "/downloads/latest-macos.dmg",
        visitorId: "visitor_001",
        sessionId: "session_001",
        releaseId: "rel_001",
        platform: "macOS",
        architecture: "arm64"
      }
    });

    expect(firstPageView.statusCode).toBe(202);
    expect(repeatedPageView.statusCode).toBe(202);
    expect(download.statusCode).toBe(202);

    const summary = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/website-analytics?range=24h",
      headers: ownerHeaders
    });

    expect(summary.statusCode).toBe(200);
    const data = summary.json().data;
    expect(data.overview).toEqual({
      pageViews: 1,
      uniqueVisitors: 1,
      downloadRequests: 1,
      uniqueDownloaders: 1
    });
    expect(data.browsers).toEqual(expect.arrayContaining([expect.objectContaining({ name: "Safari", count: 2 })]));
    expect(data.operatingSystems).toEqual(expect.arrayContaining([expect.objectContaining({ name: "macOS 14.5", count: 2 })]));
    expect(data.devices).toEqual(expect.arrayContaining([expect.objectContaining({ name: "desktop", count: 2 })]));
    expect(data.recentEvents).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          type: "download_requested",
          ipAddress: "127.0.0.0/24",
          browserName: "Safari",
          operatingSystem: "macOS 14.5"
        })
      ])
    );
  });

  it("supports an all-time analytics range for long-running website reporting", async () => {
    const server = buildServer();
    const ownerHeaders = await ownerAuthorization(server);

    const response = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/website-analytics?range=all",
      headers: ownerHeaders
    });

    expect(response.statusCode).toBe(200);
    expect(response.json().data).toEqual(
      expect.objectContaining({
        overview: expect.any(Object),
        recentEvents: expect.any(Array)
      })
    );
  });
});
