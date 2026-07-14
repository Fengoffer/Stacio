// @vitest-environment jsdom
import "@testing-library/jest-dom/vitest";
import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { opsClient } from "../api/client";
import { WebsiteAnalyticsPage } from "./WebsiteAnalyticsPage";

const product = {
  id: "stacio",
  name: "Stacio",
  platform: "macOS",
  bundleId: "com.stacio.Stacio",
  iconUrl: "",
  description: "",
  currentStableVersion: "",
  currentBetaVersion: "",
  supportEmail: "support@example.com",
  githubOwner: "",
  githubRepository: "",
  updateBaseUrl: "",
  appcastBaseUrl: "",
  licensePolicy: {},
  dataRetentionPolicy: {},
  emailBrand: {},
  objectStoragePrefix: "products/stacio",
  status: "active" as const,
  createdAt: "2026-07-11T00:00:00.000Z",
  updatedAt: "2026-07-11T00:00:00.000Z"
};

describe("WebsiteAnalyticsPage", () => {
  beforeEach(() => {
    vi.spyOn(opsClient, "products").mockResolvedValue([product]);
    vi.spyOn(opsClient, "websiteAnalytics").mockResolvedValue({
      overview: {
        pageViews: 128,
        uniqueVisitors: 84,
        downloadRequests: 37,
        uniqueDownloaders: 31
      },
      browsers: [{ name: "Safari", count: 65 }],
      operatingSystems: [{ name: "macOS 14.5", count: 92 }],
      devices: [{ name: "desktop", count: 128 }],
      recentEvents: [
        {
          eventId: "evt_download_001",
          productId: "stacio",
          type: "download_redirected",
          path: "/downloads/rel_001",
          ipAddress: "203.0.113.0/24",
          browserName: "Safari",
          operatingSystem: "macOS 14.5",
          deviceType: "desktop",
          occurredAt: "2026-07-11T01:00:00.000Z"
        }
      ]
    });
    vi.spyOn(opsClient, "githubDownloadMetrics").mockResolvedValue({
      fetchedAt: "2026-07-11T01:00:00.000Z",
      sourceArchiveDetailAvailable: false,
      releases: [
        {
          tagName: "v0.14.0",
          name: "0.14.0",
          releaseUrl: "https://github.com/Fengoffer/Stacio/releases/tag/v0.14.0",
          assets: [
            {
              id: 1,
              name: "Stacio-0.14.0.dmg",
              sizeBytes: 4096,
              downloadCount: 17,
              downloadUrl: "https://github.com/Fengoffer/Stacio/releases/download/v0.14.0/Stacio-0.14.0.dmg"
            }
          ]
        }
      ]
    });
  });

  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it("renders real-time website and download dimensions without exposing raw visitor IDs", async () => {
    render(<WebsiteAnalyticsPage />);

    expect(await screen.findByRole("heading", { name: "官网数据" })).toBeInTheDocument();
    expect(screen.getByText("页面访问")).toBeInTheDocument();
    expect(screen.getAllByText("128").length).toBeGreaterThan(0);
    expect(screen.getByText("官网下载安装")).toBeInTheDocument();
    expect(screen.getByText("37")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "浏览器" })).toBeInTheDocument();
    expect(screen.getByText("Safari")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "最近官网事件" })).toBeInTheDocument();
    expect(screen.getByText("203.0.113.0/24")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "GitHub 分发" })).toBeInTheDocument();
    expect(screen.getByText("Stacio-0.14.0.dmg")).toBeInTheDocument();
    expect(screen.getByText("GitHub 不提供源码包的单次下载明细或访客设备信息。")).toBeInTheDocument();
    expect(screen.getByRole("option", { name: "全部时间" })).toBeInTheDocument();
    expect(screen.queryByText("hash")).not.toBeInTheDocument();
  });
});
